package app.contigua.server

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.UiAutomation
import android.content.Context
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
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
                UiCodes.NO_A11Y, "This phone cannot read an accessibility tree right now.",
            )
        }
        val automation = ensureAutomation() ?: return@synchronized UiTree.Answer.Failure(
            UiCodes.NO_A11Y, failure ?: "This phone cannot read an accessibility tree right now.",
        )
        try {
            read(automation, displayId)
        } catch (t: Throwable) {
            log("ui.tree: read ${t.javaClass.simpleName}") // log-ok: class only
            restart()
            val again = ensureAutomation() ?: return@synchronized UiTree.Answer.Failure(
                UiCodes.NO_A11Y, "This phone cannot read an accessibility tree right now.",
            )
            try {
                read(again, displayId)
            } catch (t: Throwable) {
                log("ui.tree: read again ${t.javaClass.simpleName}") // log-ok: class only
                restart()
                UiTree.Answer.Failure(UiCodes.NO_A11Y, "This phone cannot read an accessibility tree right now.")
            }
        }
    }

    // MARK: the settle watch (docs/PROTOCOL.md "UI tree" item 7, MCP-81/MCP-107)

    /** The watches, confined to the looper thread; made with it. */
    @Volatile private var watches: SettleWatches? = null

    /** What the watches read through the current connection. */
    private val port = object : SettlePort {
        override fun windows(): Map<Int, List<Int>>? {
            val automation = synchronized(lock) { automation } ?: return null
            val all = automation.windowsOnAllDisplays
            val out = HashMap<Int, List<Int>>()
            for (i in 0 until all.size()) out[all.keyAt(i)] = all.valueAt(i).map { it.id }
            return out
        }

        override fun loading(displayId: Int, stale: () -> Boolean): Boolean? {
            val automation = synchronized(lock) { automation } ?: throw IllegalStateException("no connection")
            return loadingOn(automation, displayId, stale)
        }

        override fun setEventTypes(mask: Int) {
            val automation = synchronized(lock) { automation } ?: return
            runCatching {
                val info = automation.serviceInfo
                info.eventTypes = mask
                automation.serviceInfo = info
            }
        }
    }

    /**
     * Watches [displayId] until no content change came for [quietMs] and nothing
     * on it is loading, or [timeoutMs] passes, counting from [arrivedAt].
     * Blocking: the session calls it off its reader thread. The whole call is
     * bounded by `arrivedAt + timeoutMs + WATCH_MARGIN_MS + FINISH_MS`, under
     * the Mac's `timeoutMs + 5 s`, however long the connect took. A watch that
     * cannot start answers `not_available` (item 7), never `ui.tree`'s `no_a11y`.
     */
    override fun settle(displayId: Int, quietMs: Long, timeoutMs: Long, arrivedAt: Long, owner: Any): SettleAnswer {
        val deadline = arrivedAt + timeoutMs + WATCH_MARGIN_MS
        if (disconnected) return SettleAnswer.Failure(UiCodes.NOT_AVAILABLE, NO_WATCH)
        if (ensureAutomation() == null) {
            return SettleAnswer.Failure(UiCodes.NOT_AVAILABLE, synchronized(lock) { failure } ?: NO_WATCH)
        }
        val all = watches ?: return SettleAnswer.Failure(UiCodes.NOT_AVAILABLE, NO_WATCH)
        val watch = all.start(owner, displayId, quietMs, timeoutMs, arrivedAt)
            ?: return SettleAnswer.Failure(UiCodes.NOT_AVAILABLE, NO_WATCH)
        if (!watch.gate.await(maxOf(0L, deadline - now()), TimeUnit.MILLISECONDS)) {
            all.fail(watch, SettleAnswer.Failure(UiCodes.FAILED, "The display could not be watched."))
            watch.gate.await(FINISH_MS, TimeUnit.MILLISECONDS)
        }
        return watch.answer ?: SettleAnswer.Failure(UiCodes.FAILED, "The display could not be watched.")
    }

    override fun cancel(owner: Any) {
        watches?.cancel(owner)
    }

    /**
     * Whether any node on [displayId] is a loading signal (MCP-103), or the
     * display is listed with no window yet (MCP-107: still opening); null when
     * it is not listed. Walks at most [LOADING_WALK_NODES] nodes, stops at the
     * first signal or once [stale] (a change dropped the check, or the watch
     * ended); never reads a node's text.
     */
    private fun loadingOn(automation: UiAutomation, displayId: Int, stale: () -> Boolean): Boolean? {
        freshNodes(automation)
        val windows = automation.windowsOnAllDisplays.get(displayId) ?: return null
        if (windows.isEmpty()) return true
        var budget = LOADING_WALK_NODES
        fun walk(node: AccessibilityNodeInfo, depth: Int): Boolean {
            if (--budget < 0 || depth >= UiTree.MAX_DEPTH || stale()) return false
            val children = node.childCount
            if (LoadingSignal.loading(node.className?.toString() ?: "", node.isVisibleToUser, node.rangeInfo != null, children)) {
                return true
            }
            for (index in 0 until children) {
                val child = runCatching { node.getChild(index) }.getOrNull() ?: continue
                if (walk(child, depth + 1)) return true
            }
            return false
        }
        return windows.any { window -> window.root?.let { walk(it, 0) } ?: false }
    }

    /** The service's session clock (DeckService passes `uptimeMillis`), so [settle]'s `arrivedAt` is on it. */
    private fun now() = SystemClock.uptimeMillis()

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
            val running = watches
            handler = null
            watches = null
            // A running watch answers now instead of waiting out its deadline.
            running?.stopAll(SettleAnswer.Failure(UiCodes.NOT_AVAILABLE, NO_WATCH))
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
                val h = Handler(Looper.myLooper()!!)
                watches = SettleWatches(h, port, log, debug = app.contigua.BuildConfig.DEBUG)
                handler = h
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
        configure(info)
        // A connection made while a watch runs (after a restart) hears it again.
        if (watches?.listeningNow == true) info.eventTypes = SettleWatch.EVENT_MASK
        made.serviceInfo = info
        // The listener's thread is the platform's choice: copy the two fields
        // (the event is recycled after this returns) and hand them to the looper.
        made.setOnAccessibilityEventListener { event ->
            watches?.deliver(event.eventType, event.windowId)
        }
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
        freshNodes(automation)
        val all = automation.windowsOnAllDisplays
        val windows = all.get(displayId)
            ?: return UiTree.Answer.Failure(
                UiCodes.NO_DISPLAY, "That window is not on a display this phone can read.",
            )
        if (windows.isEmpty()) {
            return UiTree.Answer.Failure(UiCodes.NO_DISPLAY, "That display has no windows.")
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

    /**
     * Drops the connection's node cache before a walk (MCP-107): a guard
     * against a suspected cause of reads that came back one row (nodes=1) with
     * the settle watch's listener on — a cached root with no children — not a
     * proven fix: the lead's A/B on #166 did not reproduce it. Kept because a
     * walk from a cleared cache asks the app and costs little.
     * `debug.contigua.ui_cache=keep` (debug builds only) skips the clear, so
     * the rig can A/B it.
     */
    private fun freshNodes(automation: UiAutomation) {
        if (UiCacheDebug.keep()) return
        runCatching { automation.clearCache() }
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
            hasRange = node.rangeInfo != null,
            children = children(node, depth + 1),
            childCount = node.childCount,
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

    companion object {
        /**
         * The connection's flags (MCP-107): interactive windows, every view,
         * view ids, and no event types: a watch asks for the five content
         * changes only while it runs ([SettleWatch.EVENT_MASK]).
         */
        fun configure(info: AccessibilityServiceInfo) {
            info.flags = info.flags or
                AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
                AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS or
                AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
            info.eventTypes = 0
        }

        /** `UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES`. */
        private const val CONNECT_FLAGS = 1
        private const val SETTLE_MS = 300L
        // WIN-79 F5: thread start, connect and settle stay under the Mac's 5 s
        // deadline, so a first read answers before the Mac gives up on it.
        private const val CONNECT_TIMEOUT_MS = 2_500L
        private const val THREAD_START_MS = 1_000L
        // The machine answers by arrival + timeoutMs itself; this covers a slow
        // connect and a looper that never runs the watch's last tick. With
        // FINISH_MS the call ends by arrival + timeoutMs + 2.5 s, under the
        // Mac's timeoutMs + 5 s.
        private const val WATCH_MARGIN_MS = 2_000L
        private const val FINISH_MS = 500L
        private const val LOADING_WALK_NODES = 5_000
        private const val NO_WATCH = "This phone cannot watch the display right now."
    }
}

/** The rig's A/B knob for [UiAutomationTree]'s cache clear; a release build never reads it. */
internal object UiCacheDebug {
    const val CACHE = "debug.contigua.ui_cache"

    fun keep(debug: Boolean, property: String?): Boolean = debug && property == "keep"

    fun keep(): Boolean =
        app.contigua.BuildConfig.DEBUG && keep(true, Hidden.systemProperty(CACHE))
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
