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
 * User input always wins: if the panel was on (ours, forced dark) and then turns
 * off, that was a power-button press, and the phone must behave normally from
 * there — no waking, no re-darkening — until the screen has been on and goes off
 * again.
 */
internal class DarkPanelPolicy(private val forced: Boolean) {

    private enum class Phase { INIT, DARK, USER }

    private var phase = Phase.INIT
    private var sawPanelOn = false

    /** The strategy of the last [step]: what the shared group is doing. */
    private var watchStrategy = PanelStrategy.GROUP_ONLY

    /** Until when an off edge belongs to our own wake, not the person. */
    private var ownUntilMs = 0L

    /** When the streams paused, while the panel state is kept for [PAUSE_GRACE_MS]. */
    private var pausedAtMs: Long? = null

    val isForced: Boolean get() = forced

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
        sawPanelOn = false
        ownUntilMs = 0L
    }

    /**
     * One step. [panelOn] is whether the panel (display 0) is currently in
     * `Display.STATE_ON`; [strategy] comes from [strategy] and the caller's own
     * display-group reading.
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
            sawPanelOn = false
            return PanelPlan(wake = true, panelOff = false, transitional = false)
        }
        var transitional = false
        when (phase) {
            Phase.INIT -> {
                // A panel that is on when the first window opens belongs to the
                // user: never darken it, just let the (already awake) group render.
                if (panelOn) {
                    phase = Phase.USER
                    sawPanelOn = true
                } else {
                    phase = Phase.DARK
                    sawPanelOn = false
                    transitional = true
                }
            }
            Phase.DARK ->
                if (panelOn) {
                    sawPanelOn = true
                } else if (sawPanelOn) {
                    // Our dark panel went off without us asking: a power-button
                    // press. Hand the phone back until the screen has been on and
                    // is off again.
                    phase = Phase.USER
                    sawPanelOn = false
                }
            Phase.USER ->
                if (panelOn) {
                    sawPanelOn = true
                } else if (sawPanelOn) {
                    // The user's screen went off again: resume keeping the VD lit.
                    phase = Phase.DARK
                    sawPanelOn = false
                    transitional = true
                }
        }
        val dark = phase == Phase.DARK
        return PanelPlan(wake = dark, panelOff = dark, transitional = transitional)
    }

    /**
     * The person pressed power while the panel was ours: they get the phone
     * back, and a "Turn Off Phone Screen" request ends with it.
     *
     * @return true when this ends a dark episode, i.e. the caller must give the
     * panel back now.
     */
    fun userPressedPower(): Boolean {
        if (phase != Phase.DARK) return false
        phase = Phase.USER
        // The caller wakes the phone for the user, so the screen is now on.
        sawPanelOn = true
        return true
    }

    /**
     * The platform's interactive state just went true -> false: the person's
     * power press, or the screen timing out.
     *
     * With app streams up on the panel's shared group, that press also sleeps
     * the group our VDs render on, and the next keep-alive step is up to 2 s
     * away (the Mac calls the picture stalled after 1.5 s). So the take-over
     * happens at the edge instead: [PowerWatchAction.RELIGHT] means wake the
     * streaming group now and power the panel off under it — the existing
     * PANEL_DARK path, not a new one. The keyguard is never touched: the press
     * still locks the phone, and only our displays keep rendering.
     *
     * [streamsUp] is the caller's window count; [nowMs] is the platform clock.
     */
    fun interactiveOff(nowMs: Long, streamsUp: Boolean): PowerWatchAction {
        if (nowMs < ownUntilMs) return PowerWatchAction.NONE
        if (phase == Phase.DARK) {
            // Our dark panel's screen went off: the person's press. Hand it
            // back, exactly the rule the keep-alive step used to apply.
            return if (userPressedPower()) PowerWatchAction.HAND_BACK else PowerWatchAction.NONE
        }
        if (!streamsUp || watchStrategy != PanelStrategy.PANEL_DARK) return PowerWatchAction.NONE
        // The person's own screen went off while our VDs share its group: take
        // the panel over now (wake the group, then panel off) instead of at the
        // next 2 s step. The phone stays locked; only our displays render.
        phase = Phase.DARK
        sawPanelOn = false
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
        if (phase == Phase.DARK) return false
        phase = Phase.INIT
        sawPanelOn = false
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
        val owned = phase == Phase.DARK
        phase = Phase.INIT
        sawPanelOn = false
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
