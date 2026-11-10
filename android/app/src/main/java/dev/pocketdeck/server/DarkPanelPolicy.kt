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

/** The panel policy's closed state set (SM-P-2). */
internal enum class PanelPhase {
    /** No take-over yet: the first step decides between the person's panel and ours. */
    INIT,

    /**
     * The take-over of an episode that starts while the group sleeps: the group
     * wake is on the wire and the panel-off is still owed.
     */
    WAKE,

    /** The panel is forced dark; only the power watch changes this phase. */
    DARK,

    /** The person has the phone for this episode; nothing is darkened under them. */
    USER,
}

/**
 * Everything the panel policy remembers between events. Pure data: the live
 * holder only swaps one value for the next.
 */
internal data class PanelPolicyState(
    val phase: PanelPhase = PanelPhase.INIT,
    /** When the streams paused, while the panel state is kept for [DarkPanelPolicy.PAUSE_GRACE_MS]. */
    val pausedAtMs: Long? = null,
    /** Until when an off edge belongs to our own wake, not the person. */
    val ownUntilMs: Long = 0L,
    /** The strategy of the last [PanelEvent.EpisodeStarted] or [PanelEvent.Step]. */
    val watchStrategy: PanelStrategy = PanelStrategy.GROUP_ONLY,
    /** The debug property that forces the panel-dark path even on an own group. */
    val forced: Boolean = false,
    /**
     * The platform's panel reading the last time a step asked: a field-log
     * dedupe only, never a decision input.
     */
    val lastPanelOn: Boolean? = null,
) {
    /** True while the panel is forced dark and has not been given back. */
    val holdsPanelDark: Boolean get() = phase == PanelPhase.DARK || phase == PanelPhase.WAKE
}

/** Every event the panel policy accepts. */
internal sealed interface PanelEvent {
    /** The event's name in the transition log: a closed token. */
    val wire: String

    /** A new streaming episode started (the first stream opened). */
    data object StreamsStarted : PanelEvent {
        override val wire: String get() = "streamsStarted"
    }

    /** The episode's first display exists and its activity is about to launch. */
    data class EpisodeStarted(val panelOn: Boolean, val strategy: PanelStrategy) : PanelEvent {
        override val wire: String get() = "episodeStarted"
    }

    /** One keep-alive step with the platform's panel reading and current strategy. */
    data class Step(val panelOn: Boolean, val strategy: PanelStrategy) : PanelEvent {
        override val wire: String get() = "step"
    }

    /** The person unlocked, touched or pressed a key on display 0. */
    data class PersonUsed(val reason: PanelYieldReason) : PanelEvent {
        override val wire: String get() = "personUsed:${reason.wire}"
    }

    /** The platform's interactive state went true -> false. */
    data class InteractiveOff(val nowMs: Long, val streamsUp: Boolean) : PanelEvent {
        override val wire: String get() = "interactiveOff"
    }

    /** We just woke the streaming group ourselves. */
    data class OwnWake(val nowMs: Long) : PanelEvent {
        override val wire: String get() = "ownWake"
    }

    /** Every stream paused (covered or minimised on the Mac). */
    data class StreamsPaused(val nowMs: Long) : PanelEvent {
        override val wire: String get() = "streamsPaused"
    }

    /** The streams came back inside the pause's grace period. */
    data object StreamsResumed : PanelEvent {
        override val wire: String get() = "streamsResumed"
    }

    /** A keep-alive tick asks whether the pause's grace has run out. */
    data class GraceExpired(val nowMs: Long) : PanelEvent {
        override val wire: String get() = "graceExpired"
    }

    /** The last stream closed or the session ended. */
    data object StreamsStopped : PanelEvent {
        override val wire: String get() = "streamsStopped"
    }
}

/**
 * What the caller must do after an event. Every effect is returned, never
 * performed here: [DarkPanelPolicy] hands them to [AndroidPower].
 */
internal sealed interface PanelAction {
    /** Wake the streaming group's displays. */
    data object WakeGroup : PanelAction

    /** Power the panel off; [transitional] re-applies while a take-over settles. */
    data class PanelOff(val transitional: Boolean) : PanelAction

    /**
     * Give the panel back to the platform. [wake] is a power press: wait for the
     * platform's own screen-off, then light display 0.
     */
    data class PanelNormal(val wake: Boolean) : PanelAction

    /** Re-light the streaming displays at once after the person's own screen-off. */
    data object Relight : PanelAction

    /** Nothing of ours is held: the caller can end the episode at once. */
    data object NothingHeld : PanelAction

    /** The pause's grace ran out: hand the phone back now. */
    data object GraceOver : PanelAction

    /** The episode owned the panel: restore it and sleep the phone. */
    data object RestoreAndSleep : PanelAction
}

internal data class PanelPolicyResult(
    val state: PanelPolicyState,
    val actions: List<PanelAction> = emptyList(),
)

/**
 * The one pure rule: `(state, event) -> (state, actions)`. Every state accepts
 * every event, including the ones it ignores, and nothing here touches the
 * platform. The rules are those the field reports taught:
 *
 * - the person's own screen going off is the watch's edge, never a tick's;
 * - an off edge inside [DarkPanelPolicy.OWN_WAKE_SETTLE_MS] of our own wake is
 *   our own panel-off landing, not a press;
 * - a pause keeps the panel state for [DarkPanelPolicy.PAUSE_GRACE_MS], and a
 *   take-over in flight (WAKE) keeps its owed panel-off through a pause.
 */
internal fun panelPolicyStep(state: PanelPolicyState, event: PanelEvent): PanelPolicyResult = when (event) {
    PanelEvent.StreamsStarted -> PanelPolicyResult(
        state.copy(phase = PanelPhase.INIT, ownUntilMs = 0L),
    )

    is PanelEvent.EpisodeStarted -> onEpisodeStarted(state, event)
    is PanelEvent.Step -> onStep(state, event)
    is PanelEvent.PersonUsed -> onPersonUsed(state)
    is PanelEvent.InteractiveOff -> onInteractiveOff(state, event)
    is PanelEvent.OwnWake -> PanelPolicyResult(state.copy(ownUntilMs = event.nowMs + DarkPanelPolicy.OWN_WAKE_SETTLE_MS))
    is PanelEvent.StreamsPaused -> onStreamsPaused(state, event)
    PanelEvent.StreamsResumed -> PanelPolicyResult(state.copy(pausedAtMs = null))
    is PanelEvent.GraceExpired -> onGraceExpired(state, event)
    PanelEvent.StreamsStopped -> onStreamsStopped(state)
}

private fun onEpisodeStarted(state: PanelPolicyState, event: PanelEvent.EpisodeStarted): PanelPolicyResult {
    val watching = state.copy(watchStrategy = event.strategy)
    if (state.phase != PanelPhase.INIT) return PanelPolicyResult(watching)
    // A phone window mirroring the panel is never woken: the panel is the picture.
    if (event.strategy == PanelStrategy.PANEL_ALONE) return PanelPolicyResult(watching)
    if (event.strategy == PanelStrategy.GROUP_ONLY) {
        // The display's own group: waking it never touches the panel, and the
        // first step's wake is a harmless repeat.
        return PanelPolicyResult(watching, listOf(PanelAction.WakeGroup))
    }
    if (event.panelOn) {
        // A panel that is already on belongs to the person and is never taken.
        return PanelPolicyResult(watching.copy(phase = PanelPhase.USER))
    }
    // The panel-off is armed before the wake and owed again to the first step:
    // the platform's display controller answers the wake with its own ON, so the
    // re-applies (not the order alone) keep the lit window short.
    return PanelPolicyResult(
        watching.copy(phase = PanelPhase.WAKE),
        listOf(PanelAction.WakeGroup, PanelAction.PanelOff(transitional = true)),
    )
}

private fun onStep(state: PanelPolicyState, event: PanelEvent.Step): PanelPolicyResult {
    val asked = state.copy(watchStrategy = event.strategy, lastPanelOn = event.panelOn)
    return when (event.strategy) {
        PanelStrategy.GROUP_ONLY -> PanelPolicyResult(asked, listOf(PanelAction.WakeGroup))

        PanelStrategy.PANEL_ALONE -> PanelPolicyResult(
            // The mirror is the panel: keep the group awake for its app windows
            // and otherwise leave the panel exactly as the person has it.
            asked.copy(phase = PanelPhase.INIT, pausedAtMs = null),
            listOf(PanelAction.WakeGroup),
        )

        PanelStrategy.PANEL_DARK -> when (state.phase) {
            PanelPhase.INIT -> if (event.panelOn) {
                // A panel that is on when the first window opens is the person's.
                PanelPolicyResult(asked.copy(phase = PanelPhase.USER))
            } else {
                PanelPolicyResult(
                    asked.copy(phase = PanelPhase.DARK),
                    listOf(PanelAction.WakeGroup, PanelAction.PanelOff(transitional = true)),
                )
            }

            PanelPhase.WAKE -> PanelPolicyResult(
                // The episode start woke the group before the launch; the panel
                // is owed its off and the wake must not be repeated.
                asked.copy(phase = PanelPhase.DARK),
                listOf(PanelAction.PanelOff(transitional = true)),
            )

            PanelPhase.DARK -> PanelPolicyResult(
                asked,
                listOf(PanelAction.WakeGroup, PanelAction.PanelOff(transitional = false)),
            )

            // A steady phase is the watch's to change, never a tick's.
            PanelPhase.USER -> PanelPolicyResult(asked)
        }
    }
}

private fun onPersonUsed(state: PanelPolicyState): PanelPolicyResult = when (state.phase) {
    // WAKE is ours too: the episode start's wake lit the panel, so the person's
    // first touch or press takes it back from there.
    PanelPhase.DARK, PanelPhase.WAKE -> PanelPolicyResult(
        state.copy(phase = PanelPhase.USER),
        listOf(PanelAction.PanelNormal(wake = false)),
    )

    PanelPhase.INIT, PanelPhase.USER -> PanelPolicyResult(state)
}

private fun onInteractiveOff(state: PanelPolicyState, event: PanelEvent.InteractiveOff): PanelPolicyResult {
    // An off edge this soon after our own wake is our own panel-off landing.
    if (event.nowMs < state.ownUntilMs) return PanelPolicyResult(state)
    return when (state.phase) {
        // The panel is ours: the press is the person's, and the phone is theirs
        // from here. No relight.
        PanelPhase.DARK, PanelPhase.WAKE -> PanelPolicyResult(
            state.copy(phase = PanelPhase.USER),
            listOf(PanelAction.PanelNormal(wake = true)),
        )

        PanelPhase.INIT, PanelPhase.USER -> if (!event.streamsUp || state.watchStrategy != PanelStrategy.PANEL_DARK) {
            PanelPolicyResult(state)
        } else {
            // The person's own screen went off with our VDs sharing its group:
            // wake the streaming group now and power the panel off under it.
            PanelPolicyResult(state.copy(phase = PanelPhase.DARK), listOf(PanelAction.Relight))
        }
    }
}

private fun onStreamsPaused(state: PanelPolicyState, event: PanelEvent.StreamsPaused): PanelPolicyResult {
    val paused = state.copy(pausedAtMs = event.nowMs)
    return when (state.phase) {
        // A take-over in flight (WAKE) has already lit the panel: keep it.
        PanelPhase.DARK, PanelPhase.WAKE -> PanelPolicyResult(paused)

        PanelPhase.INIT, PanelPhase.USER ->
            PanelPolicyResult(paused.copy(phase = PanelPhase.INIT), listOf(PanelAction.NothingHeld))
    }
}

private fun onGraceExpired(state: PanelPolicyState, event: PanelEvent.GraceExpired): PanelPolicyResult {
    val since = state.pausedAtMs ?: return PanelPolicyResult(state)
    return if (event.nowMs - since >= DarkPanelPolicy.PAUSE_GRACE_MS) {
        PanelPolicyResult(state, listOf(PanelAction.GraceOver))
    } else {
        PanelPolicyResult(state)
    }
}

private fun onStreamsStopped(state: PanelPolicyState): PanelPolicyResult {
    // WAKE lit the panel itself: a close before the panel-off landed must still
    // hand it back, or a failed launch leaves the screen lit.
    val owned = state.phase == PanelPhase.DARK || state.phase == PanelPhase.WAKE
    val idle = state.copy(phase = PanelPhase.INIT, pausedAtMs = null)
    return if (owned) {
        PanelPolicyResult(idle, listOf(PanelAction.RestoreAndSleep))
    } else {
        PanelPolicyResult(idle)
    }
}

/**
 * The live policy: keeps the state, logs every phase change as
 * `panelpolicy: <from> --<event>--> <to>`, and returns the actions to perform.
 * Every query below is a thin adapter over [panelPolicyStep], so there is one
 * place where a phase can change.
 */
internal class DarkPanelPolicy(private val forced: Boolean) {

    private val lock = Object()
    private var state = PanelPolicyState(forced = forced)

    /** The state now, for tests and for the caller's derived views. */
    val current: PanelPolicyState get() = synchronized(lock) { state }

    /** True while the panel is forced dark (or owed dark) and not given back. */
    val holdsPanelDark: Boolean get() = synchronized(lock) { state.holdsPanelDark }

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
        dispatch(PanelEvent.StreamsStarted)
    }

    /**
     * The episode's first display exists and its activity is about to be
     * launched. A take-over wakes the group now and leaves the panel-off owed
     * to the first [step] (that one sleeps through the re-applies and must not
     * delay the launch).
     *
     * @return the take-over to perform at once, or null when the first [step]
     * owns the decision (a lit panel, a mirror, or a policy that is not at INIT).
     */
    fun episodeStarted(panelOn: Boolean, strategy: PanelStrategy): PanelPlan? {
        val result = dispatch(PanelEvent.EpisodeStarted(panelOn, strategy))
        return result.actions.toPlan()
    }

    /**
     * One step. [panelOn] is whether the panel (display 0) is currently in
     * `Display.STATE_ON`; [strategy] comes from [strategy] and the caller's own
     * display-group reading.
     */
    fun step(panelOn: Boolean, strategy: PanelStrategy): PanelPlan {
        val result = dispatch(PanelEvent.Step(panelOn, strategy))
        // A step always answers a plan, even when it decided nothing.
        return result.actions.toPlan() ?: PanelPlan(wake = false, panelOff = false, transitional = false)
    }

    /**
     * The person used display 0 while the panel was ours.
     *
     * @return true when this ends the dark episode, i.e. the caller must give
     * the panel back now.
     */
    fun personUsed(reason: PanelYieldReason): Boolean {
        val result = dispatch(PanelEvent.PersonUsed(reason))
        return result.actions.any { it is PanelAction.PanelNormal }
    }

    /** The platform's interactive state just went true -> false. */
    fun interactiveOff(nowMs: Long, streamsUp: Boolean): PowerWatchAction {
        val result = dispatch(PanelEvent.InteractiveOff(nowMs, streamsUp))
        return when {
            result.actions.any { it is PanelAction.PanelNormal } -> PowerWatchAction.HAND_BACK
            result.actions.contains(PanelAction.Relight) -> PowerWatchAction.RELIGHT
            else -> PowerWatchAction.NONE
        }
    }

    /** We just woke the streaming group ourselves. */
    fun ownWake(nowMs: Long) {
        dispatch(PanelEvent.OwnWake(nowMs))
    }

    /**
     * Every stream paused.
     *
     * @return true when nothing of ours is held (the person has the phone), so
     * the caller can stop at once.
     */
    fun streamsPaused(nowMs: Long): Boolean {
        val result = dispatch(PanelEvent.StreamsPaused(nowMs))
        return result.actions.contains(PanelAction.NothingHeld)
    }

    /** The streams came back inside the grace period. */
    fun streamsResumed() {
        dispatch(PanelEvent.StreamsResumed)
    }

    /** True once a pause has lasted [PAUSE_GRACE_MS]: hand the panel back now. */
    fun pauseGraceExpired(nowMs: Long): Boolean {
        val result = dispatch(PanelEvent.GraceExpired(nowMs))
        return result.actions.contains(PanelAction.GraceOver)
    }

    /**
     * The last stream closed or the session ended.
     *
     * @return true when we forced the panel dark and must restore it and put the
     * phone back to sleep.
     */
    fun streamsStopped(): Boolean {
        val result = dispatch(PanelEvent.StreamsStopped)
        return result.actions.contains(PanelAction.RestoreAndSleep)
    }

    private fun dispatch(event: PanelEvent): PanelPolicyResult {
        synchronized(lock) {
            val before = state
            val result = panelPolicyStep(before, event)
            state = result.state
            if (before.phase != result.state.phase) {
                log("panelpolicy: ${before.phase} --${event.wire}--> ${result.state.phase}")
            }
            return result
        }
    }

    private fun log(line: String) {
        // The policy has no logger of its own: AndroidPower's log is the field
        // log, and without it (tests) the transition still happened.
        logger?.invoke(line)
    }

    /** Set by [AndroidPower] so the transitions reach the field log. */
    @Volatile var logger: ((String) -> Unit)? = null

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

/** The plan implied by a transition's actions, or null when it decided none. */
private fun List<PanelAction>.toPlan(): PanelPlan? {
    val off = filterIsInstance<PanelAction.PanelOff>().firstOrNull()
    val wake = contains(PanelAction.WakeGroup)
    if (!wake && off == null) return null
    return PanelPlan(wake = wake, panelOff = off != null, transitional = off?.transitional == true)
}
