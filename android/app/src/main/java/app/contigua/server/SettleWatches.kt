package app.contigua.server

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import java.util.concurrent.CountDownLatch

/**
 * What the settle watches need from the accessibility connection (MCP-107):
 * the window list, the loading check and the event mask. [UiAutomationTree]
 * implements it over `UiAutomation`; tests hand in a fake.
 */
internal interface SettlePort {
    /** Display id -> its window ids, from `windowsOnAllDisplays`; null when the read fails. */
    fun windows(): Map<Int, List<Int>>?

    /**
     * Whether [displayId] shows a loading signal (MCP-103); null when it is
     * not listed. Runs off the looper; stops early once [stale] says the
     * answer can no longer matter.
     */
    fun loading(displayId: Int, stale: () -> Boolean): Boolean?

    /** Sets the connection's `eventTypes`: [SettleWatch.EVENT_MASK] or 0. */
    fun setEventTypes(mask: Int)
}

/**
 * Which display each window is on (MCP-107), from the latest window-list read.
 * Pure. An event from a window the read did not know reads the list again,
 * once per window id; `TYPE_WINDOWS_CHANGED` always reads it again, so a
 * window a read missed is picked up when the platform says the list changed.
 */
internal class WindowDisplays {
    private val displayOf = HashMap<Int, Int>()
    private val readFor = HashSet<Int>()

    /** Replaces the whole map with [all] (display id -> its window ids). */
    fun replace(all: Map<Int, List<Int>>) {
        displayOf.clear()
        for ((display, windows) in all) for (window in windows) displayOf[window] = display
    }

    /** Whether an event of [type] from [windowId] should read the window list again. */
    fun needsRead(type: Int, windowId: Int): Boolean =
        type == SettleWatch.TYPE_WINDOWS_CHANGED || (windowId !in displayOf && readFor.add(windowId))

    fun displayOf(windowId: Int): Int? = displayOf[windowId]
}

/**
 * The running `ui.settle` watches (docs/PROTOCOL.md "UI tree" item 7,
 * MCP-81/MCP-107), confined to one looper: the `contigua-ui-tree` thread in
 * the server. Every watch's state, its window map and the listening set are
 * touched there only. [deliver] may be called from any thread (the listener's
 * thread is the platform's choice): it copies the two fields it needs and
 * posts them, running inline only when already on the looper.
 *
 * The connection hears events only while a watch listens, and then only the
 * five content-change types ([SettleWatch.EVENT_MASK]); with no watch the mask
 * is 0, so no typed text or notification text flows in at all.
 */
internal class SettleWatches(
    private val handler: Handler,
    private val port: SettlePort,
    private val log: (String) -> Unit,
    /** The service's session clock (`uptimeMillis`), the one `arrivedAt` is on. */
    private val now: () -> Long = SystemClock::uptimeMillis,
    /** Runs a loading check off the looper. */
    private val runCheck: (Runnable) -> Unit = { Thread(it, "contigua-ui-loading").start() },
    /** Debug builds log the delivery and watch threads once (names only). */
    private val debug: Boolean = false,
) {
    /** The running watches; looper only. */
    private val watches = ArrayList<Watch>()

    /** The watches whose machine asked to listen; looper only. */
    private val listening = HashSet<Watch>()

    @Volatile private var threadLogged = false

    /** Whether any watch listens now; looper only (a fresh connection reapplies the mask). */
    val listeningNow: Boolean get() = listening.isNotEmpty()

    /** An accessibility event's type and window id, from any thread. */
    fun deliver(type: Int, windowId: Int) {
        val from = if (debug && !threadLogged) Thread.currentThread().name else null
        if (Looper.myLooper() == handler.looper) {
            logThreads(from)
            onEvent(type, windowId)
            return
        }
        handler.post {
            logThreads(from)
            onEvent(type, windowId)
        }
    }

    /** Debug builds: once, the listener's thread and the watch's (names only). */
    private fun logThreads(from: String?) {
        if (from == null || threadLogged) return
        threadLogged = true
        log("ui.settle: event thread=$from watch thread=${Thread.currentThread().name}") // log-ok: thread names only
    }

    /**
     * Starts a watch on [displayId] for [owner] (a session), counting from
     * [arrivedAt] (the request's arrival, on [now]'s clock). Null when the
     * looper is gone.
     */
    fun start(owner: Any, displayId: Int, quietMs: Long, timeoutMs: Long, arrivedAt: Long): Watch? {
        val watch = Watch(owner, displayId)
        return if (handler.post { watch.begin(quietMs, timeoutMs, arrivedAt) }) watch else null
    }

    /** [owner]'s session ended: its watch stops listening and answers nothing. */
    fun cancel(owner: Any) {
        handler.post {
            for (watch in watches.filter { it.owner === owner }) watch.drive(SettleWatch.Event.SessionEnd)
        }
    }

    /** The connection is going away: every running watch ends with [answer]; any thread. */
    fun stopAll(answer: SettleAnswer) {
        handler.post { for (watch in watches.toList()) watch.finish(answer) }
    }

    /** Ends [watch] with [answer] if it is still running; any thread. */
    fun fail(watch: Watch, answer: SettleAnswer) {
        handler.post { watch.finish(answer) }
    }

    private fun onEvent(type: Int, windowId: Int) {
        if (watches.isEmpty() || !SettleWatch.isContentChange(type)) return
        for (watch in watches.toList()) watch.onEvent(type, windowId)
    }

    private fun setListening(watch: Watch, on: Boolean) {
        val was = listening.isNotEmpty()
        if (on) listening.add(watch) else listening.remove(watch)
        val after = listening.isNotEmpty()
        if (was != after) port.setEventTypes(if (after) SettleWatch.EVENT_MASK else 0)
    }

    /** One `ui.settle`. Only [gate], [answer] and [checkInFlight] are read off the looper. */
    inner class Watch(val owner: Any, val displayId: Int) {
        val gate = CountDownLatch(1)
        @Volatile var answer: SettleAnswer? = null
            private set

        /** The machine's state; looper only (tests read it there). */
        var state: SettleWatch.State = SettleWatch.State.Idle
            private set

        /** The check a loading walk may still answer; -1 when none. A walk for another stops. */
        @Volatile private var checkInFlight = -1
        private val tick = Runnable { drive(SettleWatch.Event.Tick(now())) }
        private val windows = WindowDisplays()

        fun begin(quietMs: Long, timeoutMs: Long, arrivedAt: Long) {
            if (answer != null) return
            // A display with no window yet, or not listed yet, is still opening
            // (MCP-107): the watch starts loading, and the first window counts.
            val windowed = readWindows()
            watches.add(this)
            drive(SettleWatch.Event.Start(quietMs, timeoutMs, arrivedAt, windowed))
        }

        fun onEvent(type: Int, windowId: Int) {
            if (windows.needsRead(type, windowId)) readWindows()
            drive(SettleWatch.Event.A11y(type, windows.displayOf(windowId) == displayId, now()))
        }

        fun finish(value: SettleAnswer) {
            if (answer != null) return
            answer = value
            checkInFlight = -1
            watches.remove(this)
            setListening(this, false)
            handler.removeCallbacks(tick)
            gate.countDown()
        }

        fun drive(event: SettleWatch.Event) {
            if (answer != null) return
            val step = SettleWatch.reduce(state, event)
            state = step.state
            checkInFlight = (state as? SettleWatch.State.Checking)?.check ?: -1
            for (action in step.actions) when (action) {
                SettleWatch.Action.Listen -> setListening(this, true)
                SettleWatch.Action.StopListening -> setListening(this, false)
                is SettleWatch.Action.CheckLoading -> checkLoading(action.check)
                is SettleWatch.Action.ScheduleTick -> {
                    handler.removeCallbacks(tick)
                    handler.postDelayed(tick, maxOf(0L, action.atMs - now()))
                }
                is SettleWatch.Action.Reply -> finish(answerFor(action))
            }
            // Idle with no reply is the session's end: no answer goes out.
            if (state == SettleWatch.State.Idle) finish(SettleAnswer.Cancelled)
        }

        private fun checkLoading(check: Int) {
            runCheck(Runnable {
                val found = try {
                    port.loading(displayId) { checkInFlight != check }
                } catch (t: Throwable) {
                    log("ui.settle: check ${t.javaClass.simpleName}") // log-ok: class only
                    return@Runnable // no answer: the timeout tick still ends the watch
                }
                handler.post {
                    drive(SettleWatch.Event.Loading(found ?: false, check, now(), listed = found != null))
                }
            })
        }

        /** Re-reads which display each window is on; false when [displayId] has no window. */
        private fun readWindows(): Boolean {
            val all = runCatching { port.windows() }.getOrNull() ?: return false
            windows.replace(all)
            return !all[displayId].isNullOrEmpty()
        }
    }

    private fun answerFor(reply: SettleWatch.Action.Reply): SettleAnswer = when (reply) {
        is SettleWatch.Action.Reply.Settled -> SettleAnswer.Settled(reply.waitedMs, reply.events)
        is SettleWatch.Action.Reply.StillChanging ->
            SettleAnswer.StillChanging(reply.waitedMs, reply.events, reply.reason)
        SettleWatch.Action.Reply.Busy ->
            SettleAnswer.Failure(UiCodes.BUSY, "The last accessibility request is still running.")
        SettleWatch.Action.Reply.NoDisplay ->
            SettleAnswer.Failure(UiCodes.NO_DISPLAY, "That window's display went away.")
    }
}
