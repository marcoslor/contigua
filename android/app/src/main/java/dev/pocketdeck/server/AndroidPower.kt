package dev.pocketdeck.server

import android.content.Context
import android.os.PowerManager
import android.os.SystemClock
import android.view.Display
import java.lang.reflect.Method

/**
 * Battery/keep-awake policy. It pokes the *streaming* displays' display groups:
 * `userActivity(displayId)` + `wakeUpWithDisplayId(displayId)` when a window
 * opens and on a keep-alive timer while streams are unpaused, alongside a PARTIAL
 * wake lock. Where the build has the hidden
 * `PowerManager.newWakeLock(levelAndFlags, tag, displayId)` (API 33+), each
 * unpaused stream also holds a display-scoped SCREEN_BRIGHT wake lock bound to
 * its virtual display, which keeps that display's power group awake on its own —
 * the keep-alive timer then slows to 60 s and is only a safety net. Without the
 * hidden call the timer stays at 10 s.
 *
 * `wakeUpWithDisplayId` wakes the power group of that display's display group
 * (`PowerManagerService.wakeUpWithDisplayId`). AOSP gives an `OWN_DISPLAY_GROUP`
 * virtual display a group of its own, so only that group wakes and the physical
 * panel stays off. Builds that ignore the flag (Samsung One UI puts the VD in
 * group 0, verified on SM-S936B) make the same call wake the panel and show its
 * lock screen, which is what [DarkPanelPolicy] handles: the group is woken as
 * before and the physical panel is then powered off through SurfaceFlinger, so
 * the VD renders while the phone shows nothing. The override is lifted when the
 * last stream goes away (`POWER_MODE_NORMAL` + `goToSleep`), when the user
 * presses the power button, and by the platform itself on its next state change.
 * While the override is live, [Watchdog] holds a marker file so a server crash
 * cannot leave the panel dark.
 *
 * The person's own "Turn Off Phone Screen" (`phone.panel`, docs/design/phone-mirror.md)
 * is separate: [PanelHold] decides it, this class only performs its actions.
 *
 * The code never unlocks and never dismisses the keyguard; it only ever names the
 * streaming display's own group, plus the panel's power mode on builds that
 * cannot separate the two.
 *
 * `debug.pocketdeck.force_panel_off=1` forces the panel-dark path (used by the
 * emulator checks, where AOSP would give the VD its own group);
 * `debug.pocketdeck.force_timer_keepalive=1` skips the display wake locks, for
 * measuring the timer path.
 */
internal class AndroidPower(private val ctx: Context, private val log: (String) -> Unit) : Power {

    private val lock = Object()
    private val policyLock = Object()
    private val activeDisplays = ArrayList<Int>()
    private var lastActivityMs = 0L
    private var timerRunning = false
    private var timerThread: Thread? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var loggedNoWakeUp = false

    /** Display-scoped wake locks: one per streaming display while it is unpaused. */
    private val displayWakeLocks = HashMap<Int, PowerManager.WakeLock>()
    private var displayWakeLocksUnsupported = false

    /** Set from the keep-alive step: only safe to wake on input when the panel is not shared. */
    @Volatile private var groupOnly = false

    /** `debug.pocketdeck.keepalive_ms`: fixed cadence for on-device A/B tests. */
    private val intervalOverrideMs: Long? = Hidden.systemProperty(KEEPALIVE_MS)?.toLongOrNull()?.takeIf { it > 0 }

    private var powerWatch: Thread? = null

    private var lastPlan: PanelPlan? = null
    private var lastPanelOn: Boolean? = null

    /** Strategy seen by the last keep-alive step; sets the cadence of the next one. */
    @Volatile private var lastStrategy = PanelStrategy.PANEL_DARK

    /** Set from the keep-alive step: true while we keep the streaming group lit ourselves. */
    @Volatile private var keepLit = false

    /** True while the panel override is ours; cleared by restore, checked before each apply. */
    @Volatile private var darkEpisode = false

    /** The session's `power.locked`: the person's press with our streams up. */
    @Volatile override var onPowerLocked: (() -> Unit)? = null

    /** A screen-off edge waiting for its first frame: the gap the rig measures. */
    @Volatile override var relightPending = false
    @Volatile private var relightAtMs = 0L
    @Volatile private var relightDisplays: List<Int> = emptyList()

    /** The hold's one machine: the phone window's panel-off request (PanelHold.kt). */
    private val hold = PanelHoldMachine(log)

    /** The session's listener for a `state.panel` the hold decided on its own. */
    @Volatile override var onPanelChanged: ((Boolean) -> Unit)? = null

    override val panelHeldOff: Boolean get() = hold.holdsPanel

    /** True when this episode woke the phone's own group: handing back then sleeps it. */
    @Volatile private var episodeWokeGroup = false

    /** True while a panel override we applied is live: the watchdog has work to do if we die. */
    @Volatile private var overrideLive = false

    private val panel = PanelPower(log)
    private val policy = DarkPanelPolicy(forced = Hidden.systemProperty(FORCE_PANEL_OFF) == "1")
    private val watchdog = Watchdog(ctx, log)

    private val powerManager: Any? = Hidden.proxy("android.os.IPowerManager", "power")
    private val powerManagerClass = Hidden.iface("android.os.IPowerManager")

    private val userActivityMethod: Method? =
        Hidden.method(powerManagerClass, "userActivity", Hidden.T_INT, Hidden.T_LONG, Hidden.T_INT, Hidden.T_INT)
            ?: Hidden.method(powerManagerClass, "userActivity", Hidden.T_LONG, Hidden.T_INT, Hidden.T_INT)

    /**
     * `wakeUpWithDisplayId(long, int, String, String, int)` — present on
     * Android 15+. Resolved once; if it is missing we simply never wake anything.
     */
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

    /**
     * Hidden `newWakeLock(int levelAndFlags, String tag, int displayId)`; bound to
     * one display so its wake lock only keeps that display's group awake.
     * `SCREEN_BRIGHT_WAKE_LOCK` is deprecated but remains the level that holds a
     * display's power group on.
     */
    private val displayWakeLockMethod: Method? =
        if (Hidden.systemProperty(FORCE_TIMER) == "1") null
        else Hidden.method(PowerManager::class.java, "newWakeLock", Hidden.T_INT, String::class.java, Hidden.T_INT)

    init {
        log(
            "power: panel power control ${if (panel.available) "ready" else "unavailable"}" +
                if (policy.isForced) " ($FORCE_PANEL_OFF=1: forcing the panel-dark path)" else "",
        )
        if (displayWakeLockMethod == null) {
            log("power: no display-scoped wake locks; keep-alive timer stays at ${KEEPALIVE_INTERVAL_MS / 1000}s")
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

    override fun onInput(displayId: Int) {
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
            // Only poke while the keep-alive owns the group: in the stand-down
            // phase the phone is the user's, and a poke would keep its screen
            // from ever timing out.
            if (keepLit) {
                userActivity(displayId)
                // Waking on input is only safe when the VD is not sharing the
                // panel's group; otherwise the keep-alive owns the panel.
                if (groupOnly) wakeDisplay(displayId)
            }
        }
    }

    override fun setActiveStreams(
        displayIds: List<Int>,
        allPaused: Boolean,
        mirroring: Boolean,
        phoneWindowOpen: Boolean,
    ) {
        var started = false
        var stopped = false
        var paused = false
        var graceHandBack = false
        // The hold follows the phone window before anything else: a close ends
        // the request and restores the panel even when app streams are still
        // running, and a pause only suspends it.
        onMirrorWindow(phoneWindowOpen, mirroring)
        synchronized(lock) {
            val wasActive = activeDisplays.isNotEmpty()
            if (displayIds.isEmpty() && wasActive && allPaused) {
                // Every window is only paused (covered, minimised): keep the
                // keep-alive, the locks and the panel state exactly as they
                // are. The keep-alive loop hands the panel back once the grace
                // period runs out (DarkPanelPolicy.PAUSE_GRACE_MS); an unpause
                // in between is then no new episode at all.
                paused = true
                started = false
            } else {
                activeDisplays.clear()
                activeDisplays.addAll(displayIds)
                val isActive = activeDisplays.isNotEmpty()
                if (isActive && !wasActive) {
                    acquireWakeLockLocked()
                    startTimerLocked()
                    started = true
                } else if (!isActive && wasActive) {
                    releaseWakeLockLocked()
                    stopTimerLocked()
                    stopped = true
                }
                syncDisplayLocksLocked(activeDisplays)
            }
        }
        if (paused) {
            val now = SystemClock.uptimeMillis()
            val nothingOfOurs = synchronized(policyLock) { policy.streamsPaused(now) }
            if (nothingOfOurs) {
                // The person has the phone: there is nothing to keep.
                synchronized(lock) {
                    activeDisplays.clear()
                    releaseWakeLockLocked()
                    stopTimerLocked()
                }
                graceHandBack = true
            }
        }
        if (started) {
            synchronized(policyLock) { policy.streamsStarted() }
            episodeWokeGroup = false
            // Watch the person's power press from the episode's first second:
            // one UI puts our VDs in the panel's group, so the press sleeps
            // them until we take the panel over.
            startPowerWatch()
        }
        if (!paused && displayIds.isNotEmpty()) synchronized(policyLock) { policy.streamsResumed() }
        if (stopped) restoreAfterStop()
        if (graceHandBack) restoreAfterStop()
        // A window just opened or paused: the keep-alive thread runs a step right
        // away, so the wake (and the panel-off after it) never blocks the session
        // thread.
        synchronized(lock) { lock.notifyAll() }
    }

    /**
     * `phone.panel` (docs/PROTOCOL.md "Phone screen"): hold the mirrored panel
     * off while the phone window keeps rendering, or give it back. The person's
     * power button ends it on the phone unless the Mac's keep-it-off setting is
     * on (then the hold stands and the next keep-alive step re-applies it).
     */
    override fun setMirrorPanelOff(off: Boolean, ignorePower: Boolean): Boolean {
        if (!panel.available && !policy.isForced) return false
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

    /** Runs the machine's actions. Never called from [panelHoldTransition] itself. */
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
                    if (activeDisplays.isEmpty()) {
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
     * unlocks anything or dismisses the keyguard, and nothing here holds the
     * panel on afterwards.
     */
    override fun wakeScreen(): WakeResult {
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return WakeResult.FAILED
        if (pm.isInteractive) return WakeResult.OK
        if (wakeUpDisplayMethod != null) {
            wakeDisplay(PANEL_DISPLAY_ID)
            if (awaitInteractive(pm)) return WakeResult.OK
        }
        if (!inputWake()) return WakeResult.FAILED
        return if (awaitInteractive(pm)) WakeResult.FALLBACK else WakeResult.FAILED
    }

    private fun awaitInteractive(pm: PowerManager): Boolean {
        val deadline = SystemClock.uptimeMillis() + WAKE_WAIT_MS
        while (SystemClock.uptimeMillis() < deadline) {
            if (pm.isInteractive) return true
            runCatching { Thread.sleep(WAKE_POLL_MS) }
        }
        return pm.isInteractive
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

    /**
     * One keep-alive step: read the platform state, let the hold decide, apply.
     * Reading the panel state *before* the wake is what tells the policy whether
     * the wake is what turns the panel on.
     */
    private fun keepAliveStep() {
        var ids = synchronized(lock) { activeDisplays.toIntArray() }
        // Nothing of ours is open except possibly the person's phone window: with
        // "Turn Off Phone Screen" only the mirror's own panel group has to stay
        // up, so the step names display 0 and there is no virtual display.
        val requestOnly = ids.isEmpty()
        if (requestOnly) ids = intArrayOf(PANEL_DISPLAY_ID)
        val panelOn = DisplayProbe.state(PANEL_DISPLAY_ID) == Display.STATE_ON
        // The hold owns the mirror's panel: its step settles the take-over and
        // re-asserts the panel off. A paused mirror runs no step at all.
        if (hold.holdsPanel) performHold(hold.dispatch(PanelHoldEvent.KeepAliveStep(panelOn)))
        val holding = hold.holdsPanel
        if (requestOnly && !holding) return
        val decision = synchronized(policyLock) {
            decidePanelPlan(policy, ids.toList(), requestOnly, hold.mirrorOpen, holding, panelOn)
        } ?: return
        val strategy = decision.strategy
        val plan = decision.plan
        groupOnly = strategy == PanelStrategy.GROUP_ONLY
        lastStrategy = strategy
        if (plan != lastPlan || panelOn != lastPanelOn) {
            log("power: panel ${DisplayProbe.stateName(DisplayProbe.state(PANEL_DISPLAY_ID))} -> $plan")
            lastPlan = plan
            lastPanelOn = panelOn
        }
        keepLit = plan.wake
        val wasDark = darkEpisode
        darkEpisode = plan.panelOff
        if (plan.panelOff) startPowerWatch()
        if (wasDark && !plan.panelOff) {
            // Leaving a dark episode (the person opened the mirror, or the
            // strategy changed): the platform does not always rewrite the
            // panel's power mode on its own, so give it back explicitly. The
            // panel is only restored when the platform believes it is on (our
            // override is masking it); otherwise its own mode is already right
            // and re-writing NORMAL would flash the panel.
            if (DisplayProbe.state(PANEL_DISPLAY_ID) == Display.STATE_ON) panel.panelNormal()
            // The panel is the platform's again, so the crash guard is done.
            if (overrideLive) standDownOverride()
        }
        if (!plan.wake) return
        // On the panel's group a wake is a full phone wake: it overrides a power
        // press the user just made and starts the keyguard's face unlock, which
        // unlocks the phone if the user is in front of it. So the shared group
        // is only woken when an episode starts (or resumes after the user's own
        // screen-off); between steps the 2 s user-activity poke keeps it awake,
        // and a poke cannot wake a group the user put to sleep.
        val wake = DarkPanelPolicy.wakesGroup(strategy, plan)
        if (wake) {
            episodeWokeGroup = true
            // Our own wake lands with an off edge of its own (the panel-off
            // right after it): the watch must not read that as a press.
            synchronized(policyLock) { policy.ownWake(SystemClock.uptimeMillis()) }
        }
        // While the panel is held, the platform must keep believing the screen
        // is on. A step beside an app window names that window's display only,
        // and on a build that gives it its own group the panel's group would
        // time out and read as a power press.
        if (holding) userActivity(PANEL_DISPLAY_ID)
        for (id in ids) {
            userActivity(id)
            if (wake) wakeDisplay(id)
        }
        // The hold's own action already wrote the panel off this step.
        if (plan.panelOff && !holding) applyPanelOff(plan.transitional)
    }

    /**
     * Follows the platform's interactive state while any app stream is up (and
     * during a hold). It flips the moment the power key is handled (display 0's
     * state lags it by hundreds of ms). An interactive -> not-interactive edge
     * can only be the person (our own 2 s pokes hold off the timeout; our own
     * sleep at stream stop clears the state first):
     * - the panel is ours and dark: give it back and light the phone;
     * - the person's own screen with app streams up (One UI shares its group):
     *   re-light the VD group at once and power the panel off under it, the
     *   existing PANEL_DARK path, instead of waiting up to 2 s for the next
     *   keep-alive step while the Mac calls the picture stalled.
     */
    private fun startPowerWatch() {
        synchronized(lock) {
            if (powerWatch != null) return
            powerWatch = Thread({ powerWatchLoop() }, "pocketdeck-powerwatch").also { it.isDaemon = true; it.start() }
        }
    }

    private fun powerWatchLoop() {
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
        try {
            var wasInteractive = pm.isInteractive
            while (darkEpisode || hold.holdsPanel || synchronized(lock) { activeDisplays.isNotEmpty() }) {
                val interactive = pm.isInteractive
                if (wasInteractive && !interactive) onPowerEdge()
                wasInteractive = interactive
                Thread.sleep(POWER_WATCH_MS)
            }
        } catch (_: InterruptedException) {
        } finally {
            synchronized(lock) {
                if (powerWatch === Thread.currentThread()) powerWatch = null
            }
        }
    }

    /** One interactive -> not-interactive edge, on the power thread. */
    private fun onPowerEdge() {
        val now = SystemClock.uptimeMillis()
        if (hold.holdsPanel) {
            // The hold decides: it ends (the default) or stands and the next
            // keep-alive step re-applies the panel off.
            performHold(hold.dispatch(PanelHoldEvent.PowerPress))
            return
        }
        val streamsUp = synchronized(lock) { activeDisplays.isNotEmpty() }
        when (synchronized(policyLock) { policy.interactiveOff(now, streamsUp) }) {
            PowerWatchAction.NONE -> {}
            // The panel is ours and dark: the person gets the phone back.
            PowerWatchAction.HAND_BACK -> handBackPanel(wake = true)
            PowerWatchAction.RELIGHT -> relightStreams(now)
        }
    }

    /**
     * The person's screen went off with app streams up: wake the streaming
     * group now, then power the panel off under it (transitional), and tell the
     * Mac so its windows hold the last frame for the grace instead of calling
     * it a stall. The keyguard stays: the press still locks the phone.
     */
    private fun relightStreams(edgeMs: Long) {
        val ids = synchronized(lock) { activeDisplays.toIntArray() }
        if (ids.isEmpty()) return
        relightDisplays = ids.toList()
        relightAtMs = edgeMs
        relightPending = true
        episodeWokeGroup = true
        darkEpisode = true
        keepLit = true
        // Our wake's own off edge (the panel-off below) is not a press.
        synchronized(policyLock) { policy.ownWake(SystemClock.uptimeMillis()) }
        for (id in ids) {
            userActivity(id)
            wakeDisplay(id)
        }
        onPowerLocked?.invoke()
        applyPanelOff(transitional = true)
        log("power: screen off with ${ids.size} stream(s) up; VD group woken " +
            "${SystemClock.uptimeMillis() - edgeMs}ms after the edge, panel taken over")
    }

    /** A frame reached the wire: the press gap's one measurement per edge. */
    override fun noteFrame(displayId: Int) {
        if (!relightPending || displayId !in relightDisplays) return
        relightPending = false
        log("power: display $displayId frame ${SystemClock.uptimeMillis() - relightAtMs}ms after the screen-off edge")
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

    /**
     * The hold's first write: the panel is ours now. The take-over's re-apply
     * is the next keep-alive step (the timer was nudged), so the session thread
     * never blocks here.
     */
    private fun holdPanelOff() {
        darkEpisode = true
        startPowerWatch()
        // Arm the crash guard *before* the override goes live. The start is
        // asynchronous, so the panel-off is never delayed, and a crash between
        // these steps still leaves the marker the watchdog acts on.
        watchdog.ensure()
        watchdog.markPanelForced()
        overrideLive = true
        val applied = panel.panelOff()
        // The hold may have ended while this write was in flight (the person's
        // power press): their screen must win.
        if (!hold.holdsPanel) {
            panel.panelNormal()
            return
        }
        if (!applied && !loggedNoPanelControl) {
            loggedNoPanelControl = true
            log("panel off unavailable: the locked phone will show its lock screen while streaming")
        }
    }

    /**
     * The hold ended: the panel is the platform's again. [wake] is the person's
     * power press — the platform thinks the screen was on and is putting it to
     * sleep, so let that finish, hand the panel back and light the screen. The
     * lock screen stays; nothing is unlocked.
     */
    private fun handBackPanel(wake: Boolean) {
        darkEpisode = false
        keepLit = false
        relightPending = false
        if (wake) {
            val off = waitForPanelOff()
            panel.panelNormal()
            wakeDisplay(PANEL_DISPLAY_ID)
            log("power: user pressed power while the panel was dark; panel given back" +
                if (off) "" else " (display 0 never reported off)")
        } else if (DisplayProbe.state(PANEL_DISPLAY_ID) == Display.STATE_ON) {
            // Only when the platform believes the panel is on (our override is
            // masking it); otherwise its own mode is already right and NORMAL
            // would flash the panel.
            panel.panelNormal()
        }
        // The panel is the platform's again, so the crash guard is done.
        if (overrideLive) standDownOverride()
    }

    /** Forces the panel dark; [PanelPower] logs the mode transitions. */
    private fun applyPanelOff(transitional: Boolean) {
        if (!darkEpisode) return
        // Arm the crash guard *before* the override goes live. The start is
        // asynchronous, so the panel-off is never delayed, and a crash between
        // these steps still leaves the marker the watchdog acts on.
        watchdog.ensure()
        watchdog.markPanelForced()
        overrideLive = true
        val applied = panel.panelOff()
        // The power watch may have handed the panel back while this write was
        // in flight: the user's screen must win.
        if (!darkEpisode) {
            panel.panelNormal()
            return
        }
        if (!applied) {
            if (!loggedNoPanelControl) {
                loggedNoPanelControl = true
                log("panel off unavailable: the locked phone will show its lock screen while streaming")
            }
            return
        }
        if (!transitional) return
        // The platform's display power controller writes its own power mode while
        // it processes the wake and does not know about ours, so two bounded
        // re-applies make sure a transitional wake cannot leave the panel lit.
        for (delay in REAPPLY_DELAYS_MS) {
            runCatching { Thread.sleep(delay) }
            if (!darkEpisode || synchronized(lock) { activeDisplays.isEmpty() }) return
            panel.panelOff()
            if (!darkEpisode) {
                panel.panelNormal()
                return
            }
        }
    }

    /**
     * The last stream paused/closed or the session ended: hand the phone back to
     * its normal locked-off state. The panel power mode is only restored when the
     * platform believes the panel is on (our override is masking it); otherwise
     * the platform's own mode is already the right one and re-writing NORMAL
     * would flash the panel.
     */
    private fun restoreAfterStop() {
        val owned = synchronized(policyLock) { policy.streamsStopped() }
        if (!owned) {
            episodeWokeGroup = false
            if (overrideLive) standDownOverride()
            return
        }
        // Stop any in-flight apply before handing the panel back.
        darkEpisode = false
        relightPending = false
        if (DisplayProbe.state(PANEL_DISPLAY_ID) == Display.STATE_ON) {
            panel.panelNormal()
        }
        // goToSleep lets the platform re-apply its own power mode for the
        // transition and leaves the phone asleep and locked. Only ever called
        // when we were the ones who woke the group: a mirror-only episode never
        // woke it (its panel was on already), so the phone keeps its own state.
        if (episodeWokeGroup && SystemSleep.goToSleep()) log("phone back to sleep after the last stream")
        episodeWokeGroup = false
        // The panel is the platform's again, so the crash guard's job is done.
        standDownOverride()
    }

    /** The platform owns the panel again: no override for the watchdog to restore. */
    private fun standDownOverride() {
        overrideLive = false
        watchdog.clearPanelForced()
        watchdog.stopCleanly()
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
            m.invoke(powerManager, now, wakeReasonApplication, "pocketdeck", "pocketdeck", displayId)
        }.isSuccess
    }

    private fun startTimerLocked() {
        if (timerRunning) return
        timerRunning = true
        timerThread = Thread({ keepAliveLoop() }, "pocketdeck-keepalive").also { it.start() }
    }

    private fun stopTimerLocked() {
        timerRunning = false
        lock.notifyAll()
    }

    private fun keepAliveLoop() {
        // The timer parks until the next boundary *or* a nudge from
        // setActiveStreams, which is how a new window gets its first step. With
        // display wake locks held the group stays awake by itself, so the step
        // is a safety net and the interval slows to 60 s.
        var nextStepAt = 0L
        var step = 0
        while (true) {
            val interval: Long
            val locks: Int
            synchronized(lock) {
                if (!timerRunning) return
                locks = displayWakeLocks.size
                interval = intervalOverrideMs ?: DarkPanelPolicy.keepAliveIntervalMs(lastStrategy, locks > 0)
                val waitMs = (nextStepAt - SystemClock.uptimeMillis()).coerceAtLeast(1)
                runCatching { lock.wait(waitMs) }
                if (!timerRunning) return
                nextStepAt = SystemClock.uptimeMillis() + interval
            }
            step++
            if (synchronized(policyLock) { policy.pauseGraceExpired(SystemClock.uptimeMillis()) }) {
                handBackAfterPause()
                return
            }
            // Shared-group steps run every 2 s: log the first few, then one a minute.
            if (step <= 3 || step % 30 == 0) log("keepalive step $step interval=${interval}ms displayLocks=$locks")
            runCatching { keepAliveStep() }
            // A "Turn Off Phone Screen" request on a lone phone window is the
            // only reason the timer can run with no stream of ours left.
            val idle = synchronized(lock) { activeDisplays.isEmpty() } && !hold.holdsPanel
            if (idle) {
                synchronized(lock) {
                    releaseWakeLockLocked()
                    stopTimerLocked()
                }
                log("power: no hold and no stream left; keep-alive stopped")
                return
            }
        }
    }

    /**
     * Every window has been paused for the whole grace period: hand the phone
     * back exactly as the last close does (restore the panel, sleep, stand
     * down the crash guard), just later.
     */
    private fun handBackAfterPause() {
        synchronized(lock) {
            activeDisplays.clear()
            releaseWakeLockLocked()
            stopTimerLocked()
        }
        log("power: all windows paused for ${DarkPanelPolicy.PAUSE_GRACE_MS / 1000}s; handing the phone back")
        restoreAfterStop()
    }

    private fun acquireWakeLockLocked() {
        if (wakeLock != null) return
        runCatching {
            val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
            val wl = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "pocketdeck:streams")
            wl.setReferenceCounted(false)
            wl.acquire()
            wakeLock = wl
            log("partial wake lock acquired")
        }
    }

    private fun releaseWakeLockLocked() {
        releaseDisplayLocksLocked()
        val wl = wakeLock ?: return
        wakeLock = null
        runCatching { wl.release() }
        log("partial wake lock released")
    }

    /**
     * Keeps one display-scoped wake lock per unpaused stream, so the display
     * group stays awake without the 10 s timer pokes. The first wake of an
     * episode still comes from `wakeUpWithDisplayId` (a wake lock does not wake
     * a sleeping group); after that the lock holds it.
     */
    private fun syncDisplayLocksLocked(ids: List<Int>) {
        val method = displayWakeLockMethod ?: return
        if (displayWakeLocksUnsupported) return
        for (id in displayWakeLocks.keys.toList()) {
            if (id in ids) continue
            val wl = displayWakeLocks.remove(id) ?: continue
            runCatching { wl.release() }
            log("display wake lock released (display $id)")
        }
        for (id in ids) {
            if (displayWakeLocks.containsKey(id)) continue
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
                log("display wake locks refused; keep-alive timer stays at ${KEEPALIVE_INTERVAL_MS / 1000}s")
                return
            }
            displayWakeLocks[id] = wl
            log("display wake lock held (display $id, SCREEN_BRIGHT, display-scoped)")
        }
    }

    private fun releaseDisplayLocksLocked() {
        for ((id, wl) in displayWakeLocks) {
            runCatching { wl.release() }
            log("display wake lock released (display $id)")
        }
        displayWakeLocks.clear()
    }

    private var loggedNoPanelControl = false

    private companion object {
        /** Timer path: shorter than any screen-off timeout, so a streaming group stays on. */
        const val KEEPALIVE_INTERVAL_MS = DarkPanelPolicy.TIMER_INTERVAL_MS

        /** Re-applies after a transitional wake, so a fresh lock screen cannot stay. */
        val REAPPLY_DELAYS_MS = longArrayOf(500, 1_500)

        const val FORCE_PANEL_OFF = "debug.pocketdeck.force_panel_off"
        const val FORCE_TIMER = "debug.pocketdeck.force_timer_keepalive"
        const val KEEPALIVE_MS = "debug.pocketdeck.keepalive_ms"

        /** Power-press watch cadence while the panel is held dark. */
        const val POWER_WATCH_MS = 20L

        /** Bound on the wait for the platform's own screen-off after a power press. */
        const val PANEL_OFF_WAIT_MS = 1_500L

        /** How long `phone.wake` waits for the panel to come back before trying the fallback. */
        const val WAKE_WAIT_MS = 1_500L
        const val WAKE_POLL_MS = 50L

        /** Display 0 is the panel on every phone. */
        const val PANEL_DISPLAY_ID = 0

        const val DISPLAY_WAKE_TAG = "pocketdeck:vd"
    }
}

/** The strategy and the plan for one keep-alive step (the testable half of [AndroidPower.keepAliveStep]). */
internal data class PanelDecision(val strategy: PanelStrategy, val plan: PanelPlan)

/**
 * Decide one keep-alive step without touching the platform: which strategy the
 * active displays get, then the plan. [requestOnly] is the mirror-only case
 * (no virtual display; "Turn Off Phone Screen" holds display 0). [groupOf] is
 * the platform's display-group reading, so the JVM tests pass a fake group.
 *
 * This is the exact decision [AndroidPower.keepAliveStep] makes: the emulator's
 * 13:25:44 plan (`wake=true, panelOff=false, transitional=false`) is what
 * GROUP_ONLY or PANEL_ALONE returns, never what PANEL_DARK returns.
 */
internal fun decidePanelPlan(
    policy: DarkPanelPolicy,
    activeDisplayIds: List<Int>,
    requestOnly: Boolean,
    mirrorOpen: Boolean,
    holdActive: Boolean,
    panelOn: Boolean,
    groupOf: (Int) -> Int = { DisplayProbe.displayGroupId(it) },
): PanelDecision? {
    if (requestOnly && !(mirrorOpen && holdActive)) return null
    val ids = if (requestOnly) listOf(0) else activeDisplayIds
    val strategy = if (requestOnly) {
        PanelStrategy.PANEL_ALONE
    } else {
        policy.strategy(ids.map(groupOf), mirroring = mirrorOpen)
    }
    val plan = policy.step(panelOn, strategy)
    // "Turn Off Phone Screen" is the hold's machine; while it holds the panel
    // and the mirror is open, the step keeps the panel off.
    val held = if (holdActive && mirrorOpen) plan.copy(panelOff = true) else plan
    return PanelDecision(strategy, held)
}
