package app.contigua.server

import android.content.Context
import android.os.PowerManager
import android.os.SystemClock
import android.view.Display
import java.lang.reflect.Method

/**
 * Battery and keep-awake policy (docs/specs/phone-app.md PHONE-12, PHONE-22;
 * docs/specs/controls.md CTRL-14).
 *
 * App windows run on virtual displays in a display group of their own
 * (docs/specs/app-windows.md WIN-74): a virtual device's group on One UI, an
 * `OWN_DISPLAY_GROUP` display's on AOSP. So everything here that keeps a
 * window alive names the window's own display only:
 * `userActivity(displayId)` + `wakeUpWithDisplayId(displayId)` before a launch,
 * on input and on a keep-alive timer, plus a display-scoped SCREEN_BRIGHT wake
 * lock per window display and one PARTIAL wake lock while any window is live.
 * The phone's own screen (display 0, group 0) is never woken, held or slept for
 * an app window: it sleeps on its own timeout, and one power press wakes it.
 * A virtual device's group never times out on its own (2026-11-13 probes); an
 * AOSP own group does, which is what the lock and the timer are for.
 *
 * The one panel control left is the person's "Turn Off Phone Screen" on the
 * Phone Mirror (`phone.panel`, [PanelHold]): this class performs its actions —
 * the panel's power mode through SurfaceFlinger ([PanelPower]), a 2 s
 * user-activity poke on display 0 so the mirrored group stays on, a power-press
 * watch, and the [Watchdog] marker that gives the panel back if the server dies.
 *
 * A virtual device display makes the platform's *global* wakefulness read
 * awake while group 0 dozes, so no check here reads `PowerManager.isInteractive`
 * for "the phone's screen": [panelOn] reads display 0 itself.
 *
 * Nothing here unlocks the phone or dismisses the keyguard.
 * `debug.contigua.force_timer_keepalive=1` skips the display wake locks and
 * `debug.contigua.keepalive_ms` fixes the cadence, for on-device A/B tests.
 */
internal class AndroidPower(private val ctx: Context, private val log: (String) -> Unit) : Power {

    private val lock = Object()
    /** The open app displays of the episode: a covered window is still a window. */
    private val episode = StreamEpisode(log)
    private var lastActivityMs = 0L
    private var timerRunning = false
    private var timerThread: Thread? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var loggedNoWakeUp = false
    private var loggedNoPanelControl = false

    /** Display-scoped wake locks: one per open app window display. */
    private val displayWakeLocks = HashMap<Int, PowerManager.WakeLock>()
    private var displayWakeLocksUnsupported = false

    /** `debug.contigua.keepalive_ms`, debug builds only. */
    private val intervalOverrideMs: Long? =
        if (app.contigua.BuildConfig.DEBUG) {
            Hidden.systemProperty(KEEPALIVE_MS)?.toLongOrNull()?.takeIf { it > 0 }
        } else {
            null
        }

    private var powerWatch: Thread? = null

    /** The hold's one machine: the phone window's panel-off request (PanelHold.kt). */
    private val hold = PanelHoldMachine(log)

    /** The session's listener for a `state.panel` the hold decided on its own. */
    @Volatile override var onPanelChanged: ((Boolean) -> Unit)? = null

    override val panelHeldOff: Boolean get() = hold.holdsPanel

    /** True while the hold's panel override is live: the watchdog has work to do if we die. */
    @Volatile private var overrideLive = false

    private val panel = PanelPower(log)
    private val watchdog = Watchdog(ctx, log)

    /**
     * Serialises every panel power-mode write with the hold. A step that
     * re-asserts the panel-off must not land after the hand back's NORMAL, or
     * the person's screen would go black again under their finger.
     */
    private val panelWrites = Any()

    private val powerManager: Any? = Hidden.proxy("android.os.IPowerManager", "power")
    private val powerManagerClass = Hidden.iface("android.os.IPowerManager")

    private val userActivityMethod: Method? =
        Hidden.method(powerManagerClass, "userActivity", Hidden.T_INT, Hidden.T_LONG, Hidden.T_INT, Hidden.T_INT)
            ?: Hidden.method(powerManagerClass, "userActivity", Hidden.T_LONG, Hidden.T_INT, Hidden.T_INT)

    /** `wakeUpWithDisplayId(long, int, String, String, int)`; without it nothing is woken. */
    private val wakeUpDisplayMethod: Method? = Hidden.method(
        powerManagerClass,
        "wakeUpWithDisplayId",
        Hidden.T_LONG,
        Hidden.T_INT,
        String::class.java,
        String::class.java,
        Hidden.T_INT,
    )

    /** `PowerManager.WAKE_REASON_APPLICATION`, read reflectively; 2 is its stable value. */
    private val wakeReasonApplication: Int = runCatching {
        PowerManager::class.java.getField("WAKE_REASON_APPLICATION").getInt(null)
    }.getOrDefault(2)

    /** Hidden `newWakeLock(int levelAndFlags, String tag, int displayId)`: one display's group only. */
    private val displayWakeLockMethod: Method? =
        if (app.contigua.BuildConfig.DEBUG && Hidden.systemProperty(FORCE_TIMER) == "1") null
        else Hidden.method(PowerManager::class.java, "newWakeLock", Hidden.T_INT, String::class.java, Hidden.T_INT)

    init {
        log("power: panel power control ${if (panel.available) "ready" else "unavailable"}")
        if (displayWakeLockMethod == null) {
            log("power: no display-scoped wake locks; keep-alive timer stays at ${KeepAlive.TIMER_MS / 1000}s")
        }
        // A previous server died while holding the panel off: hand it back
        // before anything else is decided. The watchdog child does this too,
        // but it may never have started.
        if (runCatching { java.io.File(Watchdog.MARKER).isFile }.getOrDefault(false)) {
            log("power: a panel override survived a crash; giving the panel back")
            performHold(hold.dispatch(PanelHoldEvent.CrashRecovery))
            performHold(hold.dispatch(PanelHoldEvent.RestoreDone))
        }
    }

    /** The phone's own screen, read from display 0 (never the global wakefulness). */
    private fun panelOn(): Boolean = ScreenState.read(ctx) == ScreenState.ON

    override fun onInput(displayId: Int) {
        val windowDisplay = synchronized(lock) { episode.state.active && displayId in episode.state.displays }
        // Display 0's own input (the mirror) is the platform's user activity
        // already; only a window display is ours to poke.
        if (!windowDisplay) return
        val t = SystemClock.uptimeMillis()
        val poke = synchronized(lock) {
            if (t - lastActivityMs >= 1000) {
                lastActivityMs = t
                true
            } else {
                false
            }
        }
        if (poke) {
            userActivity(displayId)
            wakeDisplay(displayId)
        }
    }

    override fun setActiveStreams(
        displayIds: List<Int>,
        allPaused: Boolean,
        mirroring: Boolean,
        phoneWindowOpen: Boolean,
    ) {
        // The hold follows the phone window before anything else: a close ends
        // the request and restores the panel even when app streams are still
        // running, and a pause only suspends it.
        onMirrorWindow(phoneWindowOpen, mirroring)
        val actions = synchronized(lock) {
            episode.dispatch(EpisodeEvent.Streams(displayIds.toSet(), allPaused))
        }
        performEpisode(actions)
        // A window just opened: the keep-alive thread runs a step right away.
        synchronized(lock) { lock.notifyAll() }
    }

    /** Runs one episode event's actions (CTRL-14). */
    private fun performEpisode(actions: List<EpisodeAction>) {
        for (action in actions) {
            when (action) {
                EpisodeAction.Start -> {
                    synchronized(lock) { acquireWakeLockLocked() }
                    wakeBeforeLaunch()
                    synchronized(lock) { startTimerLocked() }
                }
                is EpisodeAction.Hold -> synchronized(lock) { holdDisplayLockLocked(action.display) }
                is EpisodeAction.Drop -> synchronized(lock) { releaseDisplayLockLocked(action.display) }
                EpisodeAction.End -> synchronized(lock) {
                    releaseDisplayLocksLocked()
                    // The hold keeps its own keep-alive; only it may outlive the windows.
                    if (!hold.holdsPanel) {
                        releaseWakeLockLocked()
                        stopTimerLocked()
                    }
                }
            }
        }
    }

    /**
     * WIN-23: a window display created while its group sleeps starts OFF, and
     * the platform does not launch onto it until the group is awake. So the
     * window displays' own group is woken before the launch, on the session
     * thread. Display 0 is never named.
     */
    private fun wakeBeforeLaunch() {
        val ids = synchronized(lock) { episode.state.displays.toList() }
        if (ids.isEmpty()) return
        for (id in ids) {
            userActivity(id)
            wakeDisplay(id)
        }
        log("power: window display ${ids.joinToString(",")} woken before the launch")
    }

    /**
     * `phone.panel` (docs/PROTOCOL.md "Phone screen"): hold the mirrored panel
     * off while the phone window keeps rendering, or give it back. The person's
     * power button ends it unless the Mac's keep-it-off setting is on (then
     * the hold stands and the next keep-alive step re-applies it).
     */
    override fun setMirrorPanelOff(off: Boolean, ignorePower: Boolean): Boolean {
        if (!panel.available) return false
        log(if (off) "phone.panel off: holding the mirrored panel off" else "phone.panel on: the mirrored panel comes back")
        val event = if (off) PanelHoldEvent.RequestOff(ignorePower) else PanelHoldEvent.RequestOn
        performHold(hold.dispatch(event))
        return true
    }

    override fun onSessionEnded() {
        performHold(hold.dispatch(PanelHoldEvent.SessionEnded))
        setActiveStreams(emptyList())
    }

    /** The phone window's visibility changed: open, paused (covered or minimised) or closed. */
    private fun onMirrorWindow(phoneWindowOpen: Boolean, mirroring: Boolean) {
        val event = when {
            !phoneWindowOpen -> if (hold.mirror == PanelMirror.Closed) null else PanelHoldEvent.WindowClosed
            mirroring -> when (hold.mirror) {
                PanelMirror.Closed -> PanelHoldEvent.WindowOpened
                PanelMirror.Paused -> PanelHoldEvent.WindowResumed
                PanelMirror.Open -> null
            }
            else -> if (hold.mirror == PanelMirror.Paused) null else PanelHoldEvent.WindowPaused
        }
        if (event != null) performHold(hold.dispatch(event))
    }

    /** Runs the hold's actions. Never called from [panelHoldTransition] itself. */
    private fun performHold(actions: List<PanelHoldAction>) {
        for (action in actions) {
            when (action) {
                is PanelHoldAction.PanelOff -> holdPanelOff()
                is PanelHoldAction.PanelNormal -> handBackPanel(action.wake)
                PanelHoldAction.StartKeepAlive -> synchronized(lock) {
                    acquireWakeLockLocked()
                    startTimerLocked()
                    lock.notifyAll()
                }
                PanelHoldAction.StopKeepAlive -> synchronized(lock) {
                    // App windows keep their own keep-alive: only a mirror-only
                    // session loses it with the hold.
                    if (!episode.state.active) {
                        releaseWakeLockLocked()
                        stopTimerLocked()
                    }
                }
                is PanelHoldAction.ReportPanel -> onPanelChanged?.invoke(action.off)
            }
        }
    }

    /**
     * `phone.wake` (docs/PROTOCOL.md "Phone screen"): display 0 only, once.
     * The display-scoped wake comes first; a build without the hidden call
     * falls back to the shell's `input keyevent KEYCODE_WAKEUP`. Neither path
     * unlocks anything, and nothing here holds the panel on afterwards.
     */
    override fun wakeScreen(): WakeResult {
        if (panelOn()) return WakeResult.OK
        if (wakeUpDisplayMethod != null) {
            wakeDisplay(PANEL_DISPLAY_ID)
            if (awaitPanelOn()) return WakeResult.OK
        }
        if (!inputWake()) return WakeResult.FAILED
        return if (awaitPanelOn()) WakeResult.FALLBACK else WakeResult.FAILED
    }

    private fun awaitPanelOn(): Boolean {
        val deadline = SystemClock.uptimeMillis() + WAKE_WAIT_MS
        while (SystemClock.uptimeMillis() < deadline) {
            if (panelOn()) return true
            runCatching { Thread.sleep(WAKE_POLL_MS) }
        }
        return panelOn()
    }

    /** The platform-independent fallback: one WAKEUP key at shell UID. */
    private fun inputWake(): Boolean = runCatching {
        val process = ProcessBuilder("input", "keyevent", "KEYCODE_WAKEUP")
            .redirectErrorStream(true)
            .start()
        process.waitFor(2, java.util.concurrent.TimeUnit.SECONDS) && process.exitValue() == 0
    }.getOrDefault(false)

    /** The service is going away: hand the panel back and stop the crash guard. */
    fun shutdown() {
        performHold(hold.dispatch(PanelHoldEvent.SessionEnded))
        setActiveStreams(emptyList())
        watchdog.stopCleanly()
    }

    // ------------------------------------------------------------------

    /** One keep-alive step: the hold's re-apply, then a poke for every display [KeepAlive.targets] names. */
    private fun keepAliveStep() {
        val ids = synchronized(lock) { if (episode.state.active) episode.state.displays.toList() else emptyList() }
        if (hold.holdsPanel) {
            startPowerWatch()
            performHold(hold.dispatch(PanelHoldEvent.KeepAliveStep(panelOn())))
        }
        for (id in KeepAlive.targets(ids, hold.holdsPanel)) {
            userActivity(id)
            // The mirrored panel is never woken by a step: a press that put it
            // to sleep is the person's, and the hold decides what follows.
            if (id != PANEL_DISPLAY_ID) wakeDisplay(id)
        }
    }

    /**
     * Follows display 0 while the hold holds the panel: an on -> off edge is
     * the person's power press (our own 2 s pokes hold off the timeout). Display
     * 0, not the global wakefulness: a window display keeps that awake.
     */
    private fun startPowerWatch() {
        synchronized(lock) {
            if (powerWatch != null) return
            powerWatch = Thread({ powerWatchLoop() }, "contigua-powerwatch").also { it.isDaemon = true; it.start() }
        }
    }

    private fun powerWatchLoop() {
        try {
            var wasOn = panelOn()
            while (hold.holdsPanel) {
                val on = panelOn()
                if (wasOn && !on) performHold(hold.dispatch(PanelHoldEvent.PowerPress))
                wasOn = on
                Thread.sleep(POWER_WATCH_MS)
            }
        } catch (_: InterruptedException) {
        } finally {
            synchronized(lock) {
                if (powerWatch === Thread.currentThread()) powerWatch = null
            }
        }
    }

    /** Waits (bounded) until display 0 has left STATE_ON; true when it did. */
    private fun waitForPanelOff(): Boolean {
        val deadline = SystemClock.uptimeMillis() + PANEL_OFF_WAIT_MS
        while (SystemClock.uptimeMillis() < deadline) {
            if (DisplayProbe.state(PANEL_DISPLAY_ID) != Display.STATE_ON) return true
            Thread.sleep(POWER_WATCH_MS)
        }
        return false
    }

    /** The hold's write: the panel is held dark while the mirror renders. */
    private fun holdPanelOff() {
        startPowerWatch()
        // Arm the crash guard *before* the override goes live. The start is
        // asynchronous, so the panel-off is never delayed, and a crash between
        // these steps still leaves the marker the watchdog acts on.
        watchdog.ensure()
        watchdog.markPanelForced()
        overrideLive = true
        val applied = synchronized(panelWrites) { hold.holdsPanel && panel.panelOff() }
        // The hold may have ended while this write was in flight (the person's
        // power press): their screen must win.
        if (!hold.holdsPanel) {
            synchronized(panelWrites) { panel.panelNormal() }
            return
        }
        if (!applied && !loggedNoPanelControl) {
            loggedNoPanelControl = true
            log("panel off unavailable: the phone's screen stays on while it is mirrored")
        }
    }

    /**
     * The hold ended: the panel is the platform's again. [wake] is a power
     * press — the platform thinks the screen was on and is putting it to
     * sleep, so let that finish, hand the panel back and light the screen. The
     * lock screen stays; nothing is unlocked.
     */
    private fun handBackPanel(wake: Boolean) {
        // The write lock is the barrier that makes a step already inside
        // [holdPanelOff] finish before this hand back writes NORMAL.
        synchronized(panelWrites) {}
        if (wake) {
            val off = waitForPanelOff()
            synchronized(panelWrites) { panel.panelNormal() }
            wakeDisplay(PANEL_DISPLAY_ID)
            log("power: panel given back" + if (off) "" else " (display 0 never reported off)")
        } else {
            // Only when the platform believes the panel is on (our override is
            // masking it); otherwise its own mode is already right and NORMAL
            // would flash the panel.
            synchronized(panelWrites) {
                if (DisplayProbe.state(PANEL_DISPLAY_ID) == Display.STATE_ON) panel.panelNormal()
            }
        }
        // The panel is the platform's again, so the crash guard is done.
        if (overrideLive) {
            overrideLive = false
            watchdog.clearPanelForced()
            watchdog.stopCleanly()
        }
    }

    private fun userActivity(displayId: Int) {
        val m = userActivityMethod ?: return
        val now = SystemClock.uptimeMillis()
        runCatching {
            if (m.parameterTypes.size == 4) {
                m.invoke(powerManager, displayId, now, 0, 0)
            } else {
                m.invoke(powerManager, now, 0, 0)
            }
        }
    }

    private fun wakeDisplay(displayId: Int): Boolean {
        val m = wakeUpDisplayMethod ?: run {
            if (!loggedNoWakeUp) {
                loggedNoWakeUp = true
                log("wakeUpWithDisplayId unavailable: not waking any display")
            }
            return false
        }
        val now = SystemClock.uptimeMillis()
        return runCatching {
            m.invoke(powerManager, now, wakeReasonApplication, "contigua", "contigua", displayId)
        }.isSuccess
    }

    private fun startTimerLocked() {
        if (timerRunning) return
        timerRunning = true
        timerThread = Thread({ keepAliveLoop() }, "contigua-keepalive").also { it.start() }
    }

    private fun stopTimerLocked() {
        timerRunning = false
        lock.notifyAll()
    }

    private fun keepAliveLoop() {
        // The timer parks until the next boundary *or* a nudge from
        // setActiveStreams, which is how a new window gets its first step.
        var nextStepAt = 0L
        var step = 0
        while (true) {
            val interval: Long
            val locks: Int
            synchronized(lock) {
                if (!timerRunning) return
                locks = displayWakeLocks.size
                interval = intervalOverrideMs ?: KeepAlive.intervalMs(hold.holdsPanel, locks > 0)
                val waitMs = (nextStepAt - SystemClock.uptimeMillis()).coerceAtLeast(1)
                runCatching { lock.wait(waitMs) }
                if (!timerRunning) return
                nextStepAt = SystemClock.uptimeMillis() + interval
            }
            step++
            if (step <= 3 || step % 30 == 0) log("keepalive step $step interval=${interval}ms displayLocks=$locks")
            runCatching { keepAliveStep() }
            val idle = synchronized(lock) { !episode.state.active } && !hold.holdsPanel
            if (idle) {
                synchronized(lock) {
                    releaseWakeLockLocked()
                    stopTimerLocked()
                }
                log("power: no hold and no window left; keep-alive stopped")
                return
            }
        }
    }

    private fun acquireWakeLockLocked() {
        if (wakeLock != null) return
        runCatching {
            val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
            val wl = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "contigua:streams")
            wl.setReferenceCounted(false)
            wl.acquire()
            wakeLock = wl
            log("partial wake lock acquired")
        }
    }

    private fun releaseWakeLockLocked() {
        val wl = wakeLock ?: return
        wakeLock = null
        runCatching { wl.release() }
        log("partial wake lock released")
    }

    /**
     * Gives one window display its scoped wake lock: it holds that display's
     * own group only, never display 0's. A covered window keeps its lock while
     * a sibling is live; only its close, or the episode's end, drops it.
     */
    private fun holdDisplayLockLocked(id: Int) {
        val method = displayWakeLockMethod ?: return
        if (displayWakeLocksUnsupported) return
        if (displayWakeLocks.containsKey(id)) return
        val wl = runCatching {
            val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
            (method.invoke(pm, PowerManager.SCREEN_BRIGHT_WAKE_LOCK, DISPLAY_WAKE_TAG, id) as? PowerManager.WakeLock)
                ?.apply {
                    setReferenceCounted(false)
                    acquire()
                }
        }.getOrNull()
        if (wl == null) {
            displayWakeLocksUnsupported = true
            log("display wake locks refused; keep-alive timer stays at ${KeepAlive.TIMER_MS / 1000}s")
            return
        }
        displayWakeLocks[id] = wl
        log("display wake lock held (display $id, SCREEN_BRIGHT, display-scoped)")
    }

    /** One stream's display closed: only that display's wake goes away. */
    private fun releaseDisplayLockLocked(id: Int) {
        val wl = displayWakeLocks.remove(id) ?: return
        runCatching { wl.release() }
        log("display wake lock released (display $id)")
    }

    private fun releaseDisplayLocksLocked() {
        for (id in displayWakeLocks.keys.toList()) releaseDisplayLockLocked(id)
    }

    private companion object {
        const val FORCE_TIMER = "debug.contigua.force_timer_keepalive"
        const val KEEPALIVE_MS = "debug.contigua.keepalive_ms"

        /** The hold's power-press watch cadence. */
        const val POWER_WATCH_MS = 20L

        /** Bound on the wait for the platform's own screen-off after a power press. */
        const val PANEL_OFF_WAIT_MS = 1_500L

        /** How long `phone.wake` waits for the panel to come back before trying the fallback. */
        const val WAKE_WAIT_MS = 1_500L
        const val WAKE_POLL_MS = 50L

        /** Display 0 is the panel on every phone. */
        const val PANEL_DISPLAY_ID = KeepAlive.PANEL_DISPLAY_ID

        const val DISPLAY_WAKE_TAG = "contigua:vd"
    }
}

/**
 * The keep-alive's two pure rules (PHONE-12, PHONE-22): which displays a step
 * pokes, and how often it runs.
 */
internal object KeepAlive {

    const val PANEL_DISPLAY_ID = 0

    /** No display wake lock: shorter than any user screen-off timeout. */
    const val TIMER_MS = 10_000L

    /** A display wake lock holds each window's group by itself: the step is only a safety net. */
    const val LOCKED_MS = 60_000L

    /**
     * Turn Off Phone Screen: the mirrored panel's group must not time out while
     * its panel is held dark, and with the keyguard up One UI shortens that
     * group's timeout to about 6 s (a display wake lock does not hold group 0
     * there). A 2 s poke keeps it without a new wake. It is also how long a
     * "keep it off" press lights the screen.
     */
    const val HOLD_MS = 2_000L

    /**
     * The displays one step pokes: every open window display, and display 0
     * only while the hold holds the mirrored panel. An app window never names
     * display 0.
     */
    fun targets(windowDisplays: List<Int>, holding: Boolean): List<Int> {
        val windows = windowDisplays.filter { it != PANEL_DISPLAY_ID }
        return if (holding) windows + PANEL_DISPLAY_ID else windows
    }

    fun intervalMs(holding: Boolean, displayLocksHeld: Boolean): Long = when {
        holding -> HOLD_MS
        displayLocksHeld -> LOCKED_MS
        else -> TIMER_MS
    }
}
