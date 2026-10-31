package dev.pocketdeck.server

/**
 * Strategy for a set of streaming displays.
 */
internal enum class PanelStrategy {
    /** The streaming displays have their own group: wake it, the panel is not involved. */
    GROUP_ONLY,

    /** The streaming displays share the panel's group: wake it, then power the panel off. */
    PANEL_DARK,

    /**
     * A phone window is mirroring display 0, so the panel shows the same thing
     * the person is looking at: keep the group awake and never power the panel
     * off. Off means off through the platform's own timeout, and only when the
     * person asks for it ("Turn Off Phone Screen").
     */
    PANEL_ALONE,
}

/** What [AndroidPower] should do for one keep-alive step. */
internal data class PanelPlan(
    val wake: Boolean,
    val panelOff: Boolean,
    /** We just took the panel over; re-apply the panel-off once the platform settles. */
    val transitional: Boolean,
)

/** What the power watch must do when the platform's interactive state goes off. */
internal enum class PowerWatchAction {
    /** Nothing: our own write, no app stream up, or the streams keep their own group. */
    NONE,

    /** The panel is ours and dark: give it back and light the phone for the person. */
    HAND_BACK,

    /** The person's screen went off with our streams up: re-light the VD group at once. */
    RELIGHT,
}

/**
 * Why the person took the phone back from a dark panel: one closed set, for the
 * `panel_yield reason=…` log line (docs/specs/controls.md CTRL-11).
 */
internal enum class PanelYieldReason(val wire: String) {
    /** The keyguard went unlocked (`state.locked` false). */
    UNLOCK("unlock"),

    /** A finger went down on display 0's touchscreen. */
    TOUCH("touch"),

    /** Any panel key but the power key. */
    KEY("key"),

    /** The power key while the panel was dark. */
    POWER("power"),
}

/**
 * Decides how a virtual display is kept lit and when the physical panel has to
 * be forced dark, plus when the phone must be handed back to normal Android
 * behaviour. Pure logic: every platform fact arrives as a value, so the JVM
 * tests drive it with a fake display/power layer.
 *
 * AOSP gives an `OWN_DISPLAY_GROUP` virtual display a group of its own, so waking
 * it leaves the panel (group 0) off and there is nothing else to do. Builds that
 * ignore the flag put the display in the panel's group, and the group wake that
 * produces its frames also lights the panel; there the panel is powered off
 * through SurfaceFlinger right after our own wakes.
 *
 * The person's direct use always wins. Once the panel is ours, an unlock, a
 * touch or a key on display 0, or the power key gives it back at once
 * ([personUsed]); after that the panel is not darkened again while the person
 * uses the phone, not even for a Mac window that opens beside it.
 *
 * Every off edge is decided in ONE place, the power watch ([interactiveOff]),
 * never by a keep-alive tick: the tick and the watch used to decide the same
 * power press, so the tick re-lit and re-darkened the panel after the watch had
 * just handed it back, and the person needed several presses to get the screen.
 */
internal class DarkPanelPolicy(private val forced: Boolean) {

    /**
     * [WAKE] is the take-over of an episode that starts while the group sleeps:
     * the group wake is on the wire and the panel-off is still owed. The launch
     * must not wait for the panel-off (it sleeps through the transitional
     * re-applies), so the wake is the session thread's [episodeStarted] action
     * and the first [step] is the panel-off.
     */
    private enum class Phase { INIT, WAKE, DARK, USER }

    private var phase = Phase.INIT

    /** The strategy of the last [step]: what the shared group is doing. */
    private var watchStrategy = PanelStrategy.GROUP_ONLY

    /** Until when an off edge belongs to our own wake, not the person. */
    private var ownUntilMs = 0L

    /** When the streams paused, while the panel state is kept for [PAUSE_GRACE_MS]. */
    private var pausedAtMs: Long? = null

    val isForced: Boolean get() = forced

    /** True while the panel is forced dark and has not been given back. */
    val holdsPanelDark: Boolean get() = phase == Phase.DARK

    /**
     * Strategy for the given display groups of the currently streaming
     * displays. [mirroring] says a phone window is showing display 0: the panel
     * then has a person watching it, so it is never forced off.
     */
    fun strategy(activeGroups: List<Int>, mirroring: Boolean = false): PanelStrategy =
        if (forced || activeGroups.any { it == DisplayProbe.DEFAULT_GROUP_ID }) {
            if (mirroring) PanelStrategy.PANEL_ALONE else PanelStrategy.PANEL_DARK
        } else {
            PanelStrategy.GROUP_ONLY
        }

    /** A streaming episode started (the first stream opened). */
    fun streamsStarted() {
        phase = Phase.INIT
        ownUntilMs = 0L
    }

    /**
     * The episode's first display exists and its activity is about to be
     * launched. A virtual display created while the panel's group sleeps starts
     * OFF, and the platform does not start an activity on it until the group is
     * awake: in the 10-30 report the launch sat 11 s before its transition and
     * the first frame came 23 s after the Mac's open. So the take-over starts
     * here, on the session thread, and not in the keep-alive step after the
     * launch: wake the group now, and leave the panel-off owed to the first
     * [step] (it is the part that sleeps through the re-applies).
     *
     * A panel that is already on belongs to the person and is never taken; a
     * mirror must not wake the phone (its panel is the picture).
     *
     * @return the wake to perform at once, or null when the first [step] owns
     * the decision (a lit panel, a mirror, or a policy that is not at INIT).
     */
    fun episodeStarted(panelOn: Boolean, strategy: PanelStrategy): PanelPlan? {
        watchStrategy = strategy
        if (phase != Phase.INIT) return null
        if (strategy == PanelStrategy.PANEL_ALONE) return null
        if (strategy == PanelStrategy.GROUP_ONLY) {
            // The display's own group: waking it never touches the panel, and
            // the first step's wake is a harmless repeat.
            return PanelPlan(wake = true, panelOff = false, transitional = false)
        }
        if (panelOn) {
            phase = Phase.USER
            return null
        }
        phase = Phase.WAKE
        return PanelPlan(wake = true, panelOff = false, transitional = true)
    }

    /**
     * One step. [panelOn] is whether the panel (display 0) is currently in
     * `Display.STATE_ON`; [strategy] comes from [strategy] and the caller's own
     * display-group reading.
     *
     * A step only applies the phase the power watch has decided. It never reads
     * the panel's own on/off edge as the person's: [interactiveOff] owns that.
     */
    fun step(panelOn: Boolean, strategy: PanelStrategy): PanelPlan {
        watchStrategy = strategy
        if (strategy == PanelStrategy.GROUP_ONLY) {
            return PanelPlan(wake = true, panelOff = false, transitional = false)
        }
        if (strategy == PanelStrategy.PANEL_ALONE) {
            // The mirror is the panel: keep the group awake for its app windows
            // and otherwise leave the panel exactly as the person has it. "Turn
            // Off Phone Screen" is the hold's own machine (PanelHold.kt); the
            // caller ORs its panel-off into this plan.
            pausedAtMs = null
            phase = Phase.INIT
            return PanelPlan(wake = true, panelOff = false, transitional = false)
        }
        var transitional = false
        when (phase) {
            Phase.INIT -> {
                // A panel that is on when the first window opens belongs to the
                // user: never darken it, just let the (already awake) group render.
                if (panelOn) {
                    phase = Phase.USER
                } else {
                    phase = Phase.DARK
                    transitional = true
                }
            }
            Phase.WAKE -> {
                // The episode start woke the group before the launch; the panel
                // is owed its off, and the wake must not be repeated (a shared
                // group wake is a full phone wake).
                phase = Phase.DARK
                return PanelPlan(wake = false, panelOff = true, transitional = true)
            }
            // A steady phase is the watch's to change, never a tick's.
            Phase.DARK, Phase.USER -> {}
        }
        val dark = phase == Phase.DARK
        return PanelPlan(wake = dark, panelOff = dark, transitional = transitional)
    }

    /**
     * The person used display 0 while the panel was ours: they get the phone
     * back now, and the panel stays the platform's while they use it.
     *
     * @return true when this ends the dark episode, i.e. the caller must give
     * the panel back now.
     */
    fun personUsed(reason: PanelYieldReason): Boolean {
        // WAKE is ours too: the episode start's wake lit the panel, so the
        // person's first touch or press takes it back from there.
        if (phase != Phase.DARK && phase != Phase.WAKE) return false
        phase = Phase.USER
        return true
    }

    /**
     * The platform's interactive state just went true -> false: a power press,
     * a screen timeout, or a lock.
     *
     * This is the only place an off edge is read, so one press is decided once:
     * - the panel is ours and dark: the press is the person's, and the phone is
     *   theirs from here ([PowerWatchAction.HAND_BACK], no relight);
     * - the person's own screen went off while our VDs share its group: wake the
     *   streaming group now and power the panel off under it, the existing
     *   PANEL_DARK path, so the Mac's picture never stalls. The keyguard is
     *   never touched: the phone stays locked and only our displays render.
     *
     * [streamsUp] is the caller's window count; [nowMs] is the platform clock.
     */
    fun interactiveOff(nowMs: Long, streamsUp: Boolean): PowerWatchAction {
        if (nowMs < ownUntilMs) return PowerWatchAction.NONE
        // WAKE is ours too: the episode start's wake lit the panel, so a press
        // from here on is the person taking the phone (the settle above already
        // masks our own wake's edge).
        if (phase == Phase.DARK || phase == Phase.WAKE) {
            return if (personUsed(PanelYieldReason.POWER)) PowerWatchAction.HAND_BACK else PowerWatchAction.NONE
        }
        if (!streamsUp || watchStrategy != PanelStrategy.PANEL_DARK) return PowerWatchAction.NONE
        phase = Phase.DARK
        return PowerWatchAction.RELIGHT
    }

    /**
     * We just woke the streaming group ourselves: an off edge before the
     * settle expires is our own panel-off arriving, not the person's press.
     */
    fun ownWake(nowMs: Long) {
        ownUntilMs = nowMs + OWN_WAKE_SETTLE_MS
    }

    /**
     * Every stream paused: the Mac covered or minimised the windows, or the
     * person switched to another app. That is not the end of streaming — the
     * phone has no reason to hand the panel back and take it again a moment
     * later (the wake and the transitional panel-off are what the person sees
     * as the panel flashing). The panel state is kept for [PAUSE_GRACE_MS]; only
     * [pauseGraceExpired] hands it back.
     *
     * @return true when nothing of ours is held (the person has the phone), so
     * the caller can stop at once.
     */
    fun streamsPaused(nowMs: Long): Boolean {
        pausedAtMs = nowMs
        // A take-over in flight (WAKE) has already lit the panel: keep it.
        if (phase == Phase.DARK || phase == Phase.WAKE) return false
        phase = Phase.INIT
        return true
    }

    /** The streams came back inside the grace period: the episode goes on as it was. */
    fun streamsResumed() {
        pausedAtMs = null
    }

    /** True once a pause has lasted [PAUSE_GRACE_MS]: hand the panel back now. */
    fun pauseGraceExpired(nowMs: Long): Boolean {
        val since = pausedAtMs ?: return false
        return nowMs - since >= PAUSE_GRACE_MS
    }

    /**
     * The last stream closed or the session ended: the person is done with the
     * phone, so a pause's grace period does not apply.
     *
     * @return true when we forced the panel dark and must restore it and put the
     * phone back to sleep.
     */
    fun streamsStopped(): Boolean {
        // WAKE lit the panel itself: a close before the panel-off landed must
        // still hand it back, or a failed launch leaves the screen lit.
        val owned = phase == Phase.DARK || phase == Phase.WAKE
        phase = Phase.INIT
        pausedAtMs = null
        return owned
    }

    companion object {
        /** No display wake lock: shorter than any user screen-off timeout. */
        const val TIMER_INTERVAL_MS = 10_000L

        /**
         * How long the panel state outlives the last paused stream. A Mac focus
         * switch covers every window for a few seconds; handing the panel back
         * and taking it again is a wake plus a transitional panel-off, which is
         * the flash the person reported (their switches were 5-10 s apart). 30 s
         * covers a glance at another app and still puts the phone back to sleep
         * soon after its windows are gone.
         */
        const val PAUSE_GRACE_MS = 30_000L

        /** Own display group holding a display wake lock: the step is only a safety net. */
        const val GROUP_LOCK_INTERVAL_MS = 60_000L

        /**
         * The VD shares the panel's group. The display-scoped wake lock does not
         * hold that group on the SM-S936B (its wake history shows `OFF timeout`
         * 7-13 s into a stream while the lock was held), and with the keyguard up
         * the platform shortens the group's timeout to 6 s. Once the group sleeps
         * the VD stops compositing until the next step, so the step has to beat
         * that 6 s: a user-activity poke every 2 s keeps the group awake without a
         * new wake, so the panel is never re-lit.
         */
        const val SHARED_GROUP_INTERVAL_MS = 2_000L

        /**
         * An off edge this soon after our own wake is our own panel-off write
         * landing, not a person's press: the transitional take-over wakes the
         * group, then powers the panel off, and the platform reports both.
         */
        const val OWN_WAKE_SETTLE_MS = 1_000L

        /**
         * Whether a step may call the platform wake. An own group can always be
         * woken: the panel is not involved. A shared group is a full phone wake,
         * which would undo the user's power press and start face unlock, so it
         * is only woken when [step] takes the panel over (`transitional`) — and
         * never while the person is mirroring the panel.
         */
        fun wakesGroup(strategy: PanelStrategy, plan: PanelPlan): Boolean =
            plan.wake && (strategy == PanelStrategy.GROUP_ONLY || plan.transitional)

        fun keepAliveIntervalMs(strategy: PanelStrategy, displayLockHeld: Boolean): Long = when {
            strategy == PanelStrategy.PANEL_DARK || strategy == PanelStrategy.PANEL_ALONE ->
                SHARED_GROUP_INTERVAL_MS
            displayLockHeld -> GROUP_LOCK_INTERVAL_MS
            else -> TIMER_INTERVAL_MS
        }
    }
}
