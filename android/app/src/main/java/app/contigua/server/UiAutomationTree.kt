package app.contigua.server

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.UiAutomation
import android.content.Context
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import java.util.concurrent.CopyOnWriteArrayList
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

    // MARK: the settle watch (docs/PROTOCOL.md "UI tree" item 7, MCP-81/MCP-107)

    /** The watches running now, one per session at most; fed on the looper thread. */
    private val watches = CopyOnWriteArrayList<Watch>()

    /**
     * Watches [displayId] until no content change came for [quietMs] and nothing
     * on it is loading, or [timeoutMs] passes. Blocking: the session calls it
     * off its reader thread. The [SettleWatch] machine runs on the looper thread,
     * where events and ticks arrive; the loading check walks the display on a
     * thread of its own and posts its answer back, so it never holds up events.
     */
    override fun settle(displayId: Int, quietMs: Long, timeoutMs: Long): SettleAnswer {
        if (disconnected) return SettleAnswer.Failure("no_a11y", NO_WATCH)
        val automation = ensureAutomation()
            ?: return SettleAnswer.Failure("no_a11y", failure ?: NO_WATCH)
        val h = handler ?: return SettleAnswer.Failure("no_a11y", NO_WATCH)
        val watch = Watch(displayId, automation, h)
        if (!h.post { watch.begin(quietMs, timeoutMs) }) return SettleAnswer.Failure("no_a11y", NO_WATCH)
        if (!watch.gate.await(timeoutMs + WATCH_MARGIN_MS, TimeUnit.MILLISECONDS)) {
            h.post { watch.finish(SettleAnswer.Failure("failed", "The display could not be watched.")) }
            watch.gate.await(WATCH_MARGIN_MS, TimeUnit.MILLISECONDS)
        }
        return watch.answer ?: SettleAnswer.Failure("failed", "The display could not be watched.")
    }

    /** Every accessibility event, on the looper thread: each running watch sees it. */
    private fun onEvent(event: AccessibilityEvent) {
        if (watches.isEmpty()) return
        val type = event.eventType
        val windowId = event.windowId
        for (watch in watches) watch.onEvent(type, windowId)
    }

    /** One `ui.settle`; every method but [gate]/[answer] runs on the looper thread. */
    private inner class Watch(val displayId: Int, val automation: UiAutomation, val h: Handler) {
        val gate = CountDownLatch(1)
        @Volatile var answer: SettleAnswer? = null
        private var state: SettleWatch.State = SettleWatch.State.Idle
        private val tick = Runnable { drive(SettleWatch.Event.Tick(now())) }
        /** Window id -> display id, from the latest `windowsOnAllDisplays` read. */
        private val windowDisplay = HashMap<Int, Int>()
        private val refreshedFor = HashSet<Int>()

        fun begin(quietMs: Long, timeoutMs: Long) {
            if (answer != null) return
            if (!readWindows()) {
                finish(SettleAnswer.Failure("no_display", "That window is not on a display this phone can read."))
                return
            }
            watches.add(this)
            drive(SettleWatch.Event.Start(quietMs, timeoutMs, now()))
        }

        fun onEvent(type: Int, windowId: Int) {
            if (!SettleWatch.isContentChange(type)) return // the machine ignores it too
            // A window the last read did not know (a new activity's, a dialog's):
            // read the window list again, once per id.
            if (windowId !in windowDisplay && refreshedFor.add(windowId)) readWindows()
            drive(SettleWatch.Event.A11y(type, windowDisplay[windowId] == displayId, now()))
        }

        fun finish(value: SettleAnswer) {
            if (answer != null) return
            answer = value
            watches.remove(this)
            h.removeCallbacks(tick)
            gate.countDown()
        }

        private fun drive(event: SettleWatch.Event) {
            if (answer != null) return
            val step = SettleWatch.reduce(state, event)
            state = step.state
            for (action in step.actions) when (action) {
                SettleWatch.Action.Listen -> Unit // the listener is always on; [watches] is the filter
                SettleWatch.Action.StopListening -> watches.remove(this)
                is SettleWatch.Action.CheckLoading -> checkLoading(action.check)
                is SettleWatch.Action.ScheduleTick -> {
                    h.removeCallbacks(tick)
                    h.postDelayed(tick, maxOf(0L, action.atMs - now()))
                }
                is SettleWatch.Action.Reply -> finish(answerFor(action))
            }
        }

        private fun checkLoading(check: Int) {
            Thread({
                val found = try {
                    loadingOn(automation, displayId)
                } catch (t: Throwable) {
                    log("ui.settle: check ${t.javaClass.simpleName}") // log-ok: class only
                    return@Thread // no answer: the timeout tick still ends the watch
                }
                h.post {
                    drive(
                        if (found == null) SettleWatch.Event.DisplayGone
                        else SettleWatch.Event.Loading(found, check, now()),
                    )
                }
            }, "contigua-ui-loading").start()
        }

        /** Re-reads which display each window is on; false when [displayId] has none. */
        private fun readWindows(): Boolean = runCatching {
            val all = automation.windowsOnAllDisplays
            windowDisplay.clear()
            for (i in 0 until all.size()) {
                val display = all.keyAt(i)
                for (window in all.valueAt(i)) windowDisplay[window.id] = display
            }
            all.get(displayId) != null
        }.getOrDefault(false)
    }

    /**
     * Whether any node on [displayId] is a loading signal (MCP-103); null when
     * the display is gone. Walks at most [LOADING_WALK_NODES] nodes and stops at
     * the first signal; never reads a node's text.
     */
    private fun loadingOn(automation: UiAutomation, displayId: Int): Boolean? {
        val windows = automation.windowsOnAllDisplays.get(displayId) ?: return null
        var budget = LOADING_WALK_NODES
        fun walk(node: AccessibilityNodeInfo, depth: Int): Boolean {
            if (--budget < 0 || depth >= UiTree.MAX_DEPTH) return false
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

    private fun answerFor(reply: SettleWatch.Action.Reply): SettleAnswer = when (reply) {
        is SettleWatch.Action.Reply.Settled -> SettleAnswer.Settled(reply.waitedMs, reply.events)
        is SettleWatch.Action.Reply.StillChanging ->
            SettleAnswer.StillChanging(reply.waitedMs, reply.events, reply.reason)
        SettleWatch.Action.Reply.Busy -> SettleAnswer.Failure("busy", "The last accessibility request is still running.")
        SettleWatch.Action.Reply.NoDisplay ->
            SettleAnswer.Failure("no_display", "That window's display went away.")
    }

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
        // The settle watch (MCP-107) hears every event type and filters them itself.
        info.eventTypes = AccessibilityEvent.TYPES_ALL_MASK
        made.serviceInfo = info
        made.setOnAccessibilityEventListener { event -> onEvent(event) }
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
            hasRange = node.rangeInfo != null,
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
        // The machine answers by start + timeoutMs itself; this covers a looper
        // that never runs the watch's last tick.
        const val WATCH_MARGIN_MS = 2_000L
        const val LOADING_WALK_NODES = 5_000
        const val NO_WATCH = "This phone cannot watch the display right now."
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
