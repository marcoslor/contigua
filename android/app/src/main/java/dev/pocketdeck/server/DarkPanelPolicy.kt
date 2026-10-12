package dev.pocketdeck.server

/**
 * Strategy for a set of streaming displays.
 */
internal enum class PanelStrategy {
    /** The streaming displays have their own group: wake it, the panel is not involved. */
    GROUP_ONLY,

    /** The streaming displays share the panel's group: wake it, then power the panel off. */
    PANEL_DARK,
}

/** What [AndroidPower] should do for one keep-alive step. */
internal data class PanelPlan(
    val wake: Boolean,
    val panelOff: Boolean,
    /** We just took the panel over; re-apply the panel-off once the platform settles. */
    val transitional: Boolean,
)

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

    val isForced: Boolean get() = forced

    /** Strategy for the given display groups of the currently streaming displays. */
    fun strategy(activeGroups: List<Int>): PanelStrategy =
        if (forced || activeGroups.any { it == DisplayProbe.DEFAULT_GROUP_ID }) {
            PanelStrategy.PANEL_DARK
        } else {
            PanelStrategy.GROUP_ONLY
        }

    /** A streaming episode started (the first stream opened). */
    fun streamsStarted() {
        phase = Phase.INIT
        sawPanelOn = false
    }

    /**
     * One step. [panelOn] is whether the panel (display 0) is currently in
     * `Display.STATE_ON`; [strategy] comes from [strategy] and the caller's own
     * display-group reading.
     */
    fun step(panelOn: Boolean, strategy: PanelStrategy): PanelPlan {
        if (strategy == PanelStrategy.GROUP_ONLY) {
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
     * The last stream paused/closed or the session ended.
     *
     * @return true when we forced the panel dark and must restore it and put the
     * phone back to sleep.
     */
    fun streamsStopped(): Boolean {
        val owned = phase == Phase.DARK
        phase = Phase.INIT
        sawPanelOn = false
        return owned
    }
}
