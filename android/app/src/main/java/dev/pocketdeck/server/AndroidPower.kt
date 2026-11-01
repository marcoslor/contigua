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
 * last stream goes away (`POWER_MODE_NORMAL`, plus `goToSleep` only while the
 * wake is still ours — [WakeOwnershipMachine]), when the user presses the power
 * button, and by the platform itself on its next state change.
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
    /** The open app displays of the episode: a covered window is still a window. */
    private val episode = StreamEpisode(log)
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

    /**
     * `debug.pocketdeck.keepalive_ms`: fixed cadence for on-device A/B tests.
     * Debug builds only: a release APK must not take any of these test knobs.
     */
    private val intervalOverrideMs: Long? =
        if (dev.pocketdeck.BuildConfig.DEBUG) {
            Hidden.systemProperty(KEEPALIVE_MS)?.toLongOrNull()?.takeIf { it > 0 }
        } else {
            null
        }

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

    /** The picture's frame clock around a screen-off edge: the rig's gap number. */
    private val gaps = FrameGapTracker()

    /** The display the edge's gap line names (the first stream it re-lit). */
    @Volatile private var gapDisplay = -1

    /** The hold's one machine: the phone window's panel-off request (PanelHold.kt). */
    private val hold = PanelHoldMachine(log)

    /** The session's listener for a `state.panel` the hold decided on its own. */
    @Volatile override var onPanelChanged: ((Boolean) -> Unit)? = null

    override val panelHeldOff: Boolean get() = hold.holdsPanel

    /** Who woke the panel's group for this episode, and whether it is still ours (docs/specs/controls.md CTRL-7). */
    private val wakeOwner = WakeOwnershipMachine(log)

    /** True while a panel override we applied is live: the watchdog has work to do if we die. */
    @Volatile private var overrideLive = false

    private val panel = PanelPower(log)
    private val policy = DarkPanelPolicy(
        forced = dev.pocketdeck.BuildConfig.DEBUG && Hidden.systemProperty(FORCE_PANEL_OFF) == "1",
    )
    private val watchdog = Watchdog(ctx, log)

    /**
     * Serialises every panel power-mode write with [darkEpisode]. A keep-alive
     * step that decided to re-assert the panel-off before the person took the
     * phone must not land that write after the hand back's NORMAL: the person's
     * screen would go black again under their finger (the 16:33:14 race).
     */
    private val panelWrites = Any()

    /** The panel's own input devices, read only while the panel is dark (CTRL-11). */
    private val panelInputLock = Any()
    @Volatile private var panelInputRunning = false
    private var panelInputThread: Thread? = null
    @Volatile private var panelInputStreams: List<java.io.FileInputStream> = emptyList()
    private var loggedNoInputDevices = false

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
        if (dev.pocketdeck.BuildConfig.DEBUG && Hidden.systemProperty(FORCE_TIMER) == "1") null
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
        // The hold follows the phone window before anything else: a close ends
        // the request and restores the panel even when app streams are still
        // running, and a pause only suspends it.
        onMirrorWindow(phoneWindowOpen, mirroring)
        val actions = synchronized(lock) {
            episode.dispatch(EpisodeEvent.Streams(displayIds.toSet(), allPaused))
        }
        performEpisode(actions, mirroring)
        // A window just opened or paused: the keep-alive thread runs a step right
        // away, so the wake (and the panel-off after it) never blocks the session
        // thread.
        synchronized(lock) { lock.notifyAll() }
    }

    /**
     * Runs one event's actions. [EpisodeAction.Start] is the episode's first
     * action and must stay before the caller's activity launch: on a phone whose
     * VD shares the panel's sleeping group the launch waits for the display to
     * wake (the 10-30 report: 11 s inside the launch, 23 s to the first frame,
     * and the activity's input sink had no channel meanwhile).
     */
    private fun performEpisode(actions: List<EpisodeAction>, mirroring: Boolean) {
        for (action in actions) {
            when (action) {
                EpisodeAction.Start -> {
                    synchronized(lock) { acquireWakeLockLocked() }
                    takeOverBeforeLaunch(mirroring)
                    synchronized(lock) { startTimerLocked() }
                    startPowerWatch()
                }
                is EpisodeAction.Hold -> synchronized(lock) { holdDisplayLockLocked(action.display) }
                is EpisodeAction.Drop -> synchronized(lock) { releaseDisplayLockLocked(action.display) }
                EpisodeAction.Pause -> {
                    val now = SystemClock.uptimeMillis()
                    val nothingOfOurs = synchronized(policyLock) { policy.streamsPaused(now) }
                    if (nothingOfOurs) {
                        // The person has the phone: there is nothing to keep.
                        val expired = synchronized(lock) { episode.dispatch(EpisodeEvent.GraceExpired) }
                        performEpisode(expired, mirroring)
                    }
                }
                EpisodeAction.Resume -> synchronized(policyLock) { policy.streamsResumed() }
                EpisodeAction.End -> {
                    synchronized(lock) {
                        releaseWakeLockLocked()
                        stopTimerLocked()
                    }
                    restoreAfterStop()
                }
            }
        }
    }

    /**
     * The episode start's take-over, before its first activity is launched.
     *
     * A virtual display created while the panel's power group sleeps starts OFF
     * (the 10-30 log: `Changing state of virtual display pocketdeck-1 from
     * UNKNOWN to OFF`), and the platform does not launch onto it until the
     * group is awake: the launch sat 11 s before its transition. Waking from
     * the keep-alive step, which only runs after `window.open` has launched and
     * awaited its task, therefore costs the whole first-frame budget. So the
     * group is woken here, on the session thread, and [DarkPanelPolicy] leaves
     * the panel-off owed to the first step (that one sleeps through the
     * transitional re-applies and must not delay the launch).
     *
     * The wake and the decision are one critical section against the keep-alive
     * step: a step that slipped in between could power the panel off before the
     * wake and the wake would light it again.
     */
    private fun takeOverBeforeLaunch(mirroring: Boolean) {
        val ids = synchronized(lock) { episode.state.displays.toList() }
        if (ids.isEmpty()) return
        val panelOn = DisplayProbe.state(PANEL_DISPLAY_ID) == Display.STATE_ON
        synchronized(policyLock) {
            policy.streamsStarted()
            val strategy = policy.strategy(ids.map { DisplayProbe.displayGroupId(it) }, mirroring = mirroring)
            val plan = policy.episodeStarted(panelOn, strategy) ?: return
            if (!DarkPanelPolicy.wakesGroup(strategy, plan)) return
            val now = SystemClock.uptimeMillis()
            policy.ownWake(now)
            if (strategy == PanelStrategy.PANEL_DARK) wakeOwner.dispatch(WakeEvent.OurWake(now))
            // Arm the override before the wake: the first panel-off write is
            // already on its way when the platform's display controller answers
            // the wake, which is what keeps the lit window short (notes.md).
            if (plan.panelOff) armPanelOff()
            for (id in ids) {
                userActivity(id)
                wakeDisplay(id)
            }
            keepLit = true
            log("power: episode take-over: display ${ids.joinToString(",")} woken before the launch; panel off owed")
        }
    }

    /**
     * The take-over's panel-off, before the wake. One write, no re-applies: the
     * first keep-alive step owns those and must not delay the launch.
     */
    private fun armPanelOff() {
        darkEpisode = true
        keepLit = true
        startPowerWatch()
        watchdog.ensure()
        watchdog.markPanelForced()
        overrideLive = true
        val applied = synchronized(panelWrites) { darkEpisode && panel.panelOff() }
        if (!applied && !loggedNoPanelControl) {
            loggedNoPanelControl = true
            log("panel off unavailable: the locked phone will show its lock screen while streaming")
        }
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
                    if (episode.state.displays.isEmpty()) {
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

    /**
     * The person unlocked the phone (`state.locked` false): the phone is theirs
     * for this episode (CTRL-7), and a panel we forced dark comes back at once
     * (CTRL-11). Nothing is dismissed, unlocked or woken here: the platform is
     * already showing the screen the person unlocked.
     */
    override fun onPersonUnlocked() {
        wakeOwner.dispatch(WakeEvent.PersonUnlocked)
        if (synchronized(policyLock) { policy.personUsed(PanelYieldReason.UNLOCK) }) {
            panelYielded(PanelYieldReason.UNLOCK, wake = false)
        }
    }

    /** `state.screen`: a screen-on edge outside our own wake is the person's. */
    override fun onPersonScreen(on: Boolean) {
        wakeOwner.dispatch(WakeEvent.ScreenReported(on, SystemClock.uptimeMillis()))
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
        stopPanelInput()
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
        var ids = synchronized(lock) { episode.state.displays.toIntArray() }
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
            // While our override is live the platform's own state is not the
            // panel's: the display controller still believes the group is on
            // (that is what the wake did), while SurfaceFlinger shows OFF. Say
            // which one this line is, so a field log does not read as a flash.
            val shown = if (darkEpisode) "held off" else DisplayProbe.stateName(DisplayProbe.state(PANEL_DISPLAY_ID))
            log("power: panel $shown -> $plan")
            lastPlan = plan
            lastPanelOn = panelOn
        }
        // A take-over in flight (the episode start woke the group before its
        // launch) keeps the group lit even though this step issues no wake.
        keepLit = plan.wake || plan.panelOff
        val wasDark = darkEpisode
        darkEpisode = plan.panelOff
        if (plan.panelOff) startPowerWatch()
        // The person's own devices are only worth reading while our override is
        // live: an event there is a finger or a key on the panel (CTRL-11).
        if (plan.panelOff) startPanelInput() else if (wasDark) stopPanelInput()
        if (wasDark && !plan.panelOff) {
            // Leaving a dark episode (the person opened the mirror, or the
            // strategy changed): the platform does not always rewrite the
            // panel's power mode on its own, so give it back explicitly. The
            // panel is only restored when the platform believes it is on (our
            // override is masking it); otherwise its own mode is already right
            // and re-writing NORMAL would flash the panel.
            synchronized(panelWrites) {
                if (DisplayProbe.state(PANEL_DISPLAY_ID) == Display.STATE_ON) panel.panelNormal()
            }
            // The panel is the platform's again, so the crash guard is done.
            if (overrideLive) standDownOverride()
        }
        if (!plan.wake) {
            // The episode start already woke the group before its launch; the
            // panel-off it owes is all this step has left to do.
            if (plan.panelOff && !holding) applyPanelOff(plan.transitional)
            return
        }
        // On the panel's group a wake is a full phone wake: it overrides a power
        // press the user just made and starts the keyguard's face unlock, which
        // unlocks the phone if the user is in front of it. So the shared group
        // is only woken when an episode starts (or resumes after the user's own
        // screen-off); between steps the 2 s user-activity poke keeps it awake,
        // and a poke cannot wake a group the user put to sleep.
        val wake = DarkPanelPolicy.wakesGroup(strategy, plan)
        if (wake) {
            // Our own wake lands with an off edge of its own (the panel-off
            // right after it): the watch must not read that as a press.
            synchronized(policyLock) { policy.ownWake(SystemClock.uptimeMillis()) }
            // Only a wake of the panel's own group can make a later sleep ours.
            // A virtual display with its own group never wakes the phone.
            if (strategy == PanelStrategy.PANEL_DARK) {
                wakeOwner.dispatch(WakeEvent.OurWake(SystemClock.uptimeMillis()))
            }
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
            while (darkEpisode || hold.holdsPanel || synchronized(lock) { episode.state.active }) {
                val interactive = pm.isInteractive
                if (wasInteractive && !interactive) onPowerEdge()
                wasInteractive = interactive
                gaps.closeIfDue(SystemClock.uptimeMillis())?.let { gap ->
                    log("power: display ${gapDisplay.coerceAtLeast(0)} max frame gap ${gap}ms " +
                        "around the screen-off edge (frames=${gaps.framesSeen})")
                }
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
        val streamsUp = synchronized(lock) { episode.state.active }
        when (synchronized(policyLock) { policy.interactiveOff(now, streamsUp) }) {
            PowerWatchAction.NONE -> {}
            // The panel is ours and dark: the press is the person's. One hand
            // back, and nothing re-darkens the panel after it (the decision was
            // made once, here).
            PowerWatchAction.HAND_BACK -> {
                wakeOwner.dispatch(WakeEvent.PersonUsed)
                panelYielded(PanelYieldReason.POWER, wake = true)
            }
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
        val ids = synchronized(lock) { episode.state.displays.toIntArray() }
        if (ids.isEmpty()) return
        gapDisplay = ids.first()
        gaps.markEdge(edgeMs)
        // The phone went idle by itself: the person is done, so the ownership
        // ends here and our relight starts a new baseline (CTRL-7). Without
        // this, `person` would survive into a close that must not sleep the
        // phone, or an own wake would wrongly move `person` back to ours.
        wakeOwner.dispatch(WakeEvent.PersonIdle)
        wakeOwner.dispatch(WakeEvent.OurWake(SystemClock.uptimeMillis()))
        darkEpisode = true
        keepLit = true
        // Our wake's own off edge (the panel-off below) is not a press.
        synchronized(policyLock) { policy.ownWake(SystemClock.uptimeMillis()) }
        val issued = SystemClock.uptimeMillis()
        for (id in ids) {
            userActivity(id)
            wakeDisplay(id)
        }
        val returned = SystemClock.uptimeMillis()
        onPowerLocked?.invoke()
        applyPanelOff(transitional = true)
        val offReturned = SystemClock.uptimeMillis()
        // One line per step: the gap that matters is what the VD drew, not when
        // this thread got back from a call.
        log("power: relight edge+${issued - edgeMs}ms wake issued, " +
            "+${returned - edgeMs}ms wake returned, +${offReturned - edgeMs}ms panel off returned")
    }

    /** A frame reached the wire: the gap ring's one store per frame. */
    override fun noteFrame(nowMs: Long) {
        gaps.onFrame(nowMs)
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
        val applied = synchronized(panelWrites) { hold.holdsPanel && panel.panelOff() }
        // The hold may have ended while this write was in flight (the person's
        // power press): their screen must win.
        if (!hold.holdsPanel) {
            synchronized(panelWrites) { panel.panelNormal() }
            return
        }
        if (!applied && !loggedNoPanelControl) {
            loggedNoPanelControl = true
            log("panel off unavailable: the locked phone will show its lock screen while streaming")
        }
    }

    /** The person took the phone back from a dark panel: log why and hand it over (CTRL-11). */
    private fun panelYielded(reason: PanelYieldReason, wake: Boolean) {
        log("panel_yield reason=${reason.wire}")
        stopPanelInput()
        handBackPanel(wake)
    }

    /**
     * The hold ended or the person took the panel back: the panel is the
     * platform's again. [wake] is a power press — the platform thinks the screen
     * was on and is putting it to sleep, so let that finish, hand the panel back
     * and light the screen. The lock screen stays; nothing is unlocked.
     */
    private fun handBackPanel(wake: Boolean) {
        // The decision lands before anything is written, and inside the write
        // lock: a keep-alive step already inside [applyPanelOff] can no longer
        // put its panel-off on top of this hand back.
        synchronized(panelWrites) {
            darkEpisode = false
            keepLit = false
        }
        stopPanelInput()
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
        val applied = synchronized(panelWrites) { darkEpisode && panel.panelOff() }
        // The person may have taken the panel back while this write was in
        // flight: the hand back's NORMAL is the last word.
        if (!darkEpisode) return
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
            if (synchronized(lock) { episode.state.displays.isEmpty() }) return
            val stillDark = synchronized(panelWrites) { if (darkEpisode) { panel.panelOff(); true } else false }
            if (!stillDark) return
        }
    }

    /**
     * The last stream paused/closed or the session ended: hand the phone back to
     * its normal locked-off state. The panel power mode is only restored when the
     * platform believes the panel is on (our override is masking it); otherwise
     * the platform's own mode is already the right one and re-writing NORMAL
     * would flash the panel.
     *
     * The phone is only put back to sleep while PocketDeck's own wake still owns
     * it (CTRL-7): a person who unlocked, used or woke the phone since keeps
     * their screen, and the close logs the closed reason instead.
     */
    private fun restoreAfterStop() {
        stopPanelInput()
        val owned = synchronized(policyLock) { policy.streamsStopped() }
        // The wake machine hears every close, whatever the panel policy owned:
        // a stale "ours" must never survive into the next episode.
        val wake = wakeOwner.dispatch(WakeEvent.StreamsStopped)
        if (!owned) {
            logWakeClose(wake)
            if (overrideLive) standDownOverride()
            return
        }
        // Stop any in-flight apply before handing the panel back.
        synchronized(panelWrites) { darkEpisode = false }
        synchronized(panelWrites) {
            if (DisplayProbe.state(PANEL_DISPLAY_ID) == Display.STATE_ON) panel.panelNormal()
        }
        // goToSleep lets the platform re-apply its own power mode for the
        // transition. Only ever called while the wake is ours: a mirror-only
        // episode never woke the panel's group, and a person who used the phone
        // since our wake owns it.
        if (wake.actions.contains(WakeAction.SLEEP_PHONE) && SystemSleep.goToSleep()) {
            log("phone back to sleep after the last stream")
        }
        logWakeClose(wake)
        // The panel is the platform's again, so the crash guard's job is done.
        standDownOverride()
    }

    /** A close that left the phone awake says why, with a closed reason. */
    private fun logWakeClose(wake: WakeStep) {
        wake.closeReason?.let { log("power: left the phone awake after the last stream (${it.wire})") }
    }

    /** The platform owns the panel again: no override for the watchdog to restore. */
    private fun standDownOverride() {
        overrideLive = false
        watchdog.clearPanelForced()
        watchdog.stopCleanly()
    }

    // --- the panel's own input devices (CTRL-11) ------------------------

    /**
     * Starts reading the phone's own input devices, which is how a touch or a
     * key on display 0 reaches a shell-UID process. Only the kernel nodes are
     * read: our keep-alive pokes are `IPowerManager.userActivity` calls and the
     * session's input is `InputManager.injectInputEvent`, so neither ever shows
     * up here and the person can never be faked by PocketDeck itself.
     *
     * Idempotent, and only called while the panel is dark. A device node that
     * cannot be read is skipped; when none can be read the hand back still
     * works from an unlock or a power press, and the gap is logged once.
     */
    private fun startPanelInput() {
        synchronized(panelInputLock) {
            if (panelInputRunning) return
            val text = runCatching { java.io.File(INPUT_DEVICES).readText() }.getOrNull()
            val nodes = text?.let { inputEventNodes(it) }.orEmpty()
            val opened = ArrayList<Pair<InputEventNode, java.io.FileInputStream>>(nodes.size)
            for (node in nodes) {
                val stream = runCatching { java.io.FileInputStream(node.path) }.getOrNull() ?: continue
                opened.add(node to stream)
            }
            if (opened.isEmpty()) {
                if (!loggedNoInputDevices) {
                    loggedNoInputDevices = true
                    log("power: no readable panel input device (${nodes.size} found); a touch cannot hand the panel back")
                }
                return
            }
            panelInputRunning = true
            panelInputStreams = opened.map { it.second }
            panelInputThread = Thread({ panelInputLoop(opened) }, "pocketdeck-panelinput").also {
                it.isDaemon = true
                it.start()
            }
        }
    }

    /** Stops the input read: the panel is not ours any more. */
    private fun stopPanelInput() {
        synchronized(panelInputLock) {
            panelInputRunning = false
            val streams = panelInputStreams
            panelInputStreams = emptyList()
            panelInputThread = null
            for (stream in streams) runCatching { stream.close() }
        }
    }

    /**
     * Reads whole `struct input_event`s, one device node at a time, until the
     * first finger or key of the person's. `available()` keeps the stop clean:
     * a blocked `read` on an evdev node is not woken by `close()`.
     */
    private fun panelInputLoop(nodes: List<Pair<InputEventNode, java.io.FileInputStream>>) {
        val event = ByteArray(INPUT_EVENT_BYTES)
        try {
            while (panelInputRunning) {
                var use: PanelInput? = null
                for ((_, stream) in nodes) {
                    while (runCatching { stream.available() }.getOrDefault(0) >= INPUT_EVENT_BYTES) {
                        val read = runCatching { stream.read(event, 0, INPUT_EVENT_BYTES) }.getOrDefault(-1)
                        if (read != INPUT_EVENT_BYTES) break
                        val raw = decodeInputEvent(event)
                        val input = panelInput(raw.type, raw.code, raw.value) ?: continue
                        // The power key is the power watch's edge: it has to wake
                        // the screen as well as hand the panel back.
                        if (input == PanelInput.POWER) continue
                        use = input
                        break
                    }
                    if (use != null) break
                }
                if (use != null) {
                    onPanelInput(use)
                    return
                }
                Thread.sleep(INPUT_POLL_MS)
            }
        } catch (_: InterruptedException) {
        } finally {
            stopPanelInput()
        }
    }

    /** A touch or key on the panel while it was ours: the person gets it back. */
    private fun onPanelInput(input: PanelInput) {
        val reason = if (input == PanelInput.TOUCH) PanelYieldReason.TOUCH else PanelYieldReason.KEY
        if (!synchronized(policyLock) { policy.personUsed(reason) }) return
        wakeOwner.dispatch(WakeEvent.PersonUsed)
        panelYielded(reason, wake = false)
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
            val idle = synchronized(lock) { episode.state.displays.isEmpty() } && !hold.holdsPanel
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
        log("power: all windows paused for ${DarkPanelPolicy.PAUSE_GRACE_MS / 1000}s; handing the phone back")
        val expired = synchronized(lock) { episode.dispatch(EpisodeEvent.GraceExpired) }
        performEpisode(expired, mirroring = false)
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
     * Gives one open stream's display its scoped wake lock, so that display's
     * group stays awake without the 2 s timer pokes. A covered window keeps
     * its lock: it is still open, and only its own close drops it.
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
            log("display wake locks refused; keep-alive timer stays at ${KEEPALIVE_INTERVAL_MS / 1000}s")
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

        /**
         * Re-applies after a transitional wake, so a fresh lock screen cannot
         * stay. The first two are early on purpose: the platform's display
         * controller answers our wake with its own ON write a few tens of ms
         * after our first off, and the next one here must beat it (the 11-01
         * field log: 639 ms lit with a 500 ms first re-apply).
         */
        val REAPPLY_DELAYS_MS = longArrayOf(100, 250, 500, 1_500)

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

        /** Every input device, named by the kernel. */
        const val INPUT_DEVICES = "/proc/bus/input/devices"

        /**
         * How often the panel's input nodes are read while the panel is dark.
         * A poll, not a blocking read: closing an evdev fd does not wake a
         * blocked read. 25 ms keeps the hand back well inside the 300 ms bound.
         */
        const val INPUT_POLL_MS = 25L
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
