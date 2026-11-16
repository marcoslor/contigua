package app.contigua.server

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.UiAutomation
import android.content.Context
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The shell side of `ui.tree` (docs/PROTOCOL.md "UI tree", WIN-79): one
 * `UiAutomation` connection, held on a looper thread of its own, that reads the
 * accessibility tree of a stream's display.
 *
 * This is the slot no ordinary accessibility service fills: a service only sees
 * the display it is running on, and `uiautomator dump` only reads display 0, so
 * neither can see an app window on its own virtual display (ISS-143). At the
 * shell UID the platform hands out every display, with no service the person
 * has to enable.
 *
 * The connection is made by reflection, exactly as the debug dump proved on a
 * real phone (ISS-141): `UiAutomation` and its constructor are hidden, and
 * `UiAutomationConnection` is the platform's own. Nothing here reads a node's
 * text into a log; only counts and codes leave.
 */
internal class UiAutomationTree(private val log: (String) -> Unit) : UiTreeSource {

    private val lock = Any()
    private val startLock = Any()
    private val readLock = Any()

    @Volatile private var looperThread: Thread? = null
    @Volatile private var handler: Handler? = null
    private var automation: UiAutomation? = null
    private var failure: String? = null

    /** Whether [disconnect] was called; a disconnected source answers `no_a11y`. */
    @Volatile var disconnected = false
        private set

    override fun dump(displayId: Int, size: IntSize): UiTree.Answer = synchronized(readLock) {
        if (disconnected) {
            return@synchronized UiTree.Answer.Failure(
                "no_a11y", "This phone cannot read an accessibility tree right now.",
            )
        }
        val automation = ensureAutomation() ?: return@synchronized UiTree.Answer.Failure(
            "no_a11y", failure ?: "This phone cannot read an accessibility tree right now.",
        )
        try {
            read(automation, displayId)
        } catch (t: Throwable) {
            log("ui.tree: read ${t.javaClass.simpleName}") // log-ok: class only
            restart()
            val again = ensureAutomation() ?: return@synchronized UiTree.Answer.Failure(
                "no_a11y", "This phone cannot read an accessibility tree right now.",
            )
            try {
                read(again, displayId)
            } catch (t: Throwable) {
                log("ui.tree: read again ${t.javaClass.simpleName}") // log-ok: class only
                restart()
                UiTree.Answer.Failure("no_a11y", "This phone cannot read an accessibility tree right now.")
            }
        }
    }

    /**
     * The one connection this process owns is dropped here, never by a session
     * ending (WIN-79 F3). Idempotent: the service stops once, a second stop is
     * a no-op.
     */
    fun disconnect() {
        synchronized(readLock) {
            if (disconnected) return
            disconnected = true
            restart()
            val threadHandler = handler
            handler = null
            looperThread = null
            threadHandler?.post { Looper.myLooper()?.quitSafely() }
        }
    }

    // MARK: the connection

    /**
     * The one connection, made once. Another client taking the automation
     * makes the next read fail, and [restart] gives this one a fresh connection.
     */
    private fun ensureAutomation(): UiAutomation? {
        synchronized(lock) { automation?.let { return it } }
        startThread()
        val gate = CountDownLatch(1)
        val posted = handler?.post {
            val made = try {
                connect()
            } catch (t: Throwable) {
                synchronized(lock) { failure = sentence(t) } // WIN-79 F10: under the lock
                log("ui.tree: connect ${t.javaClass.simpleName}") // log-ok: class only
                null
            }
            synchronized(lock) {
                automation = made
                if (made != null) failure = null
            }
            gate.countDown()
        } ?: return null
        if (!posted) return null
        if (!gate.await(CONNECT_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
            synchronized(lock) { failure = "The accessibility connection did not answer." }
            return null
        }
        return synchronized(lock) { automation }
    }

    /** Drops the connection so the next read makes a new one. */
    private fun restart() {
        val current = synchronized(lock) { automation.also { automation = null } } ?: return
        runCatching { UiAutomation::class.java.getDeclaredMethod("disconnect").invoke(current) }
    }

    private fun startThread() {
        synchronized(startLock) {
            if (looperThread != null) return
            val ready = CountDownLatch(1)
            val thread = Thread({
                Looper.prepare()
                handler = Handler(Looper.myLooper()!!)
                looperThread = Thread.currentThread()
                ready.countDown()
                Looper.loop()
            }, "contigua-ui-tree")
            thread.isDaemon = true
            thread.start()
            ready.await(THREAD_START_MS, TimeUnit.MILLISECONDS)
        }
    }

    /**
     * Connects without disturbing the phone's own accessibility services: the
     * person's screen reader keeps running (the debug dump's flag).
     */
    private fun connect(): UiAutomation {
        val context = systemContext()
            ?: throw IllegalStateException("no system context")
        val iface = Class.forName("android.app.IUiAutomationConnection")
        val connection = Class.forName("android.app.UiAutomationConnection")
            .getDeclaredConstructor().newInstance()
        val made = runCatching {
            UiAutomation::class.java.getDeclaredConstructor(Context::class.java, iface)
                .newInstance(context, connection)
        }.getOrElse {
            UiAutomation::class.java.getDeclaredConstructor(Looper::class.java, iface)
                .newInstance(Looper.myLooper(), connection)
        }
        UiAutomation::class.java.getDeclaredMethod("connect", Int::class.javaPrimitiveType)
            .invoke(made, CONNECT_FLAGS)
        val info = made.serviceInfo
        info.flags = info.flags or
            AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
            AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS or
            AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
        made.serviceInfo = info
        return made
    }

    private fun systemContext(): Context? = runCatching {
        val threadClass = Class.forName("android.app.ActivityThread")
        val thread = runCatching { threadClass.getMethod("currentActivityThread").invoke(null) }.getOrNull()
            ?: threadClass.getMethod("systemMain").invoke(null)
        threadClass.getMethod("getSystemContext").invoke(thread) as Context
    }.getOrNull()

    private fun sentence(t: Throwable): String {
        val cause = generateSequence(t) { it.cause }.last()
        val name = cause.javaClass.simpleName
        return when {
            name.contains("Security") -> "This phone does not let its shell read the accessibility tree."
            else -> "The accessibility tree could not be read ($name)."
        }
    }

    // MARK: the read

    private fun read(automation: UiAutomation, displayId: Int): UiTree.Answer {
        // The window list fills in after the flags land; the debug dump waits
        // 300 ms for the same reason.
        Thread.sleep(SETTLE_MS)
        val all = automation.windowsOnAllDisplays
        val windows = all.get(displayId)
            ?: return UiTree.Answer.Failure(
                "no_display", "That window is not on a display this phone can read.",
            )
        if (windows.isEmpty()) {
            return UiTree.Answer.Failure("no_display", "That display has no windows.")
        }
        val trees = windows.map { window ->
            UiTree.Layer(
                title = UiTree.label(window.title?.toString()),
                type = typeName(window.type),
                focused = window.isFocused,
                active = window.isActive,
                nodes = window.root?.let { children(it, 0) } ?: emptyList(),
            )
        }
        return UiTree.Answer.Tree(trees)
    }

    private fun children(node: AccessibilityNodeInfo, depth: Int): List<UiTree.Node> {
        if (depth >= UiTree.MAX_DEPTH) return emptyList()
        val out = ArrayList<UiTree.Node>(node.childCount)
        for (index in 0 until node.childCount) {
            val child = runCatching { node.getChild(index) }.getOrNull() ?: continue
            out.add(node(child, depth))
        }
        return out
    }

    private fun node(node: AccessibilityNodeInfo, depth: Int): UiTree.Node {
        val box = Rect().also { node.getBoundsInScreen(it) }
        return UiTree.Node(
            role = node.className?.toString() ?: "?",
            text = node.text?.toString(),
            desc = node.contentDescription?.toString(),
            viewId = node.viewIdResourceName,
            box = UiTree.Box(box.left, box.top, box.right, box.bottom),
            clickable = node.isClickable,
            editable = node.isEditable,
            scrollable = node.isScrollable,
            checkable = node.isCheckable,
            checked = node.isChecked,
            selected = node.isSelected,
            focused = node.isFocused,
            enabled = node.isEnabled,
            password = node.isPassword,
            visibleToUser = node.isVisibleToUser,
            children = children(node, depth + 1),
        )
    }

    private fun typeName(type: Int): String = when (type) {
        AccessibilityWindowInfo.TYPE_APPLICATION -> "app"
        AccessibilityWindowInfo.TYPE_INPUT_METHOD -> "ime"
        AccessibilityWindowInfo.TYPE_SYSTEM -> "system"
        AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY -> "overlay"
        AccessibilityWindowInfo.TYPE_SPLIT_SCREEN_DIVIDER -> "divider"
        AccessibilityWindowInfo.TYPE_MAGNIFICATION_OVERLAY -> "magnifier"
        else -> type.toString()
    }

    private companion object {
        /** `UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES`. */
        const val CONNECT_FLAGS = 1
        const val SETTLE_MS = 300L
        // WIN-79 F5: thread start, connect and settle stay under the Mac's 5 s
        // deadline, so a first read answers before the Mac gives up on it.
        const val CONNECT_TIMEOUT_MS = 2_500L
        const val THREAD_START_MS = 1_000L
    }
}

/**
 * The one [UiAutomationTree] per process (WIN-79 F3): every session's factory
 * asks [get] and receives the same source, so a session ending never tears down
 * the connection another session still uses. Only [disconnect] — the service's
 * stop — drops it.
 */
internal class UiTreeSourceOwner(private val log: (String) -> Unit) {
    private val source = UiAutomationTree(log)

    fun get(): UiAutomationTree = source
    fun disconnect() = source.disconnect()
}
