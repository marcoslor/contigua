package dev.pocketdeck.server

/**
 * One relight: the person's own screen went off with our windows streaming
 * (docs/specs/phone-app.md PHONE-22), and the phone must wake the windows'
 * display group and hold the panel dark under it. The sequence used to be a
 * long function with no stage names: the wake was issued, its calls returned,
 * then the panel-off ran its re-applies for about 2.5 s on the power-watch
 * thread. A press during those re-applies had nowhere to arrive, so it was
 * lost (ISS-24).
 *
 * This is that sequence as an explicit machine: a closed set of stages, the
 * events a press or a session-end can raise while it runs, and actions the
 * caller performs. Pure: every platform fact arrives as a value.
 */
internal enum class RelightStage(val wire: String) {
    /** The group wake is on the wire; its display calls have not all returned. */
    WAKE_ISSUED("wakeIssued"),

    /** The wake calls returned; the panel-off is next. */
    WAKE_RETURNED("wakeReturned"),

    /** The panel-off is applied and its transitional re-applies are running. */
    PANEL_OFF("panelOff"),
}

internal data class RelightState(
    /** Null when no relight is in flight. */
    val stage: RelightStage? = null,
    /** When the current stage began: the field log's `edge+<n>ms` numbers. */
    val sinceMs: Long = 0L,
    /** A power press the person made while the panel-off was still running. */
    val pressAtMs: Long? = null,
    /** The last stream closed or the session ended while the relight was running. */
    val stoppedAtMs: Long? = null,
) {
    val relighting: Boolean get() = stage != null
}

internal sealed interface RelightEvent {
    /** The event's name in the transition log: a closed token. */
    val wire: String

    /** The wake is being issued now. */
    data class Start(val nowMs: Long) : RelightEvent {
        override val wire: String get() = "start"
    }

    /** The wake's display calls returned. */
    data class WakeReturned(val nowMs: Long) : RelightEvent {
        override val wire: String get() = "wakeReturned"
    }

    /** The panel-off write starts; its re-applies run until [Done]. */
    data class PanelOffStarted(val nowMs: Long) : RelightEvent {
        override val wire: String get() = "panelOffStarted"
    }

    /** A power press arrived while the panel-off was running. */
    data class Press(val nowMs: Long) : RelightEvent {
        override val wire: String get() = "press"
    }

    /** The last stream closed or the session ended. */
    data class StreamsStopped(val nowMs: Long) : RelightEvent {
        override val wire: String get() = "streamsStopped"
    }

    /** The relight's own sequence finished. */
    data class Done(val nowMs: Long) : RelightEvent {
        override val wire: String get() = "done"
    }
}

/** What the caller must do after a relight event. */
internal sealed interface RelightAction {
    /** The press is the person's: hand the panel back once, now. */
    data object HandBack : RelightAction

    /** Stop the panel-off re-applies: they must never darken a panel taken back. */
    data object StopReapplies : RelightAction
}

internal data class RelightStep(val state: RelightState, val actions: List<RelightAction> = emptyList())

/**
 * The one pure rule. Every stage accepts every event, including the ones it
 * ignores. A start always begins a new relight; a done or a stream stop ends
 * one; a press only matters during the panel-off, when it is the person's.
 */
internal fun relightStep(state: RelightState, event: RelightEvent): RelightStep = when (event) {
    is RelightEvent.Start -> RelightStep(RelightState(stage = RelightStage.WAKE_ISSUED, sinceMs = event.nowMs))

    is RelightEvent.WakeReturned -> when (state.stage) {
        RelightStage.WAKE_ISSUED ->
            RelightStep(state.copy(stage = RelightStage.WAKE_RETURNED, sinceMs = event.nowMs))

        RelightStage.WAKE_RETURNED, RelightStage.PANEL_OFF, null -> RelightStep(state)
    }

    is RelightEvent.PanelOffStarted -> when (state.stage) {
        RelightStage.WAKE_ISSUED, RelightStage.WAKE_RETURNED ->
            RelightStep(state.copy(stage = RelightStage.PANEL_OFF, sinceMs = event.nowMs))

        RelightStage.PANEL_OFF, null -> RelightStep(state)
    }

    is RelightEvent.Press -> when (state.stage) {
        // A press during the panel-off is recorded; the press's hand back is
        // the named behaviour step (ISS-24).
        RelightStage.PANEL_OFF -> RelightStep(state.copy(pressAtMs = event.nowMs))

        RelightStage.WAKE_ISSUED, RelightStage.WAKE_RETURNED, null -> RelightStep(state)
    }

    is RelightEvent.StreamsStopped -> when (state.stage) {
        RelightStage.WAKE_ISSUED, RelightStage.WAKE_RETURNED, RelightStage.PANEL_OFF ->
            RelightStep(
                state.copy(stage = null, stoppedAtMs = event.nowMs),
                listOf(RelightAction.StopReapplies),
            )

        null -> RelightStep(state)
    }

    is RelightEvent.Done -> when (state.stage) {
        null -> RelightStep(state)
        RelightStage.WAKE_ISSUED, RelightStage.WAKE_RETURNED, RelightStage.PANEL_OFF ->
            RelightStep(RelightState())
    }
}

/**
 * The live relight: keeps the state, logs every stage change as
 * `relight: <from> --<event>--> <to>`, and returns the actions for
 * [AndroidPower] to perform.
 */
internal class PanelRelight(private val log: (String) -> Unit = {}) {

    private val lock = Object()
    private var state = RelightState()

    val stage: RelightStage? get() = synchronized(lock) { state.stage }
    val sinceMs: Long get() = synchronized(lock) { state.sinceMs }
    val pressAtMs: Long? get() = synchronized(lock) { state.pressAtMs }

    fun start(nowMs: Long) {
        dispatch(RelightEvent.Start(nowMs))
    }

    fun wakeReturned(nowMs: Long) {
        dispatch(RelightEvent.WakeReturned(nowMs))
    }

    fun panelOffStarted(nowMs: Long) {
        dispatch(RelightEvent.PanelOffStarted(nowMs))
    }

    fun streamsStopped(nowMs: Long): List<RelightAction> = dispatch(RelightEvent.StreamsStopped(nowMs))

    fun done(nowMs: Long) {
        dispatch(RelightEvent.Done(nowMs))
    }

    /** One press seen by the caller; returns the actions to perform. */
    fun press(nowMs: Long): List<RelightAction> = dispatch(RelightEvent.Press(nowMs))

    private fun dispatch(event: RelightEvent): List<RelightAction> {
        synchronized(lock) {
            val before = state
            val step = relightStep(before, event)
            state = step.state
            if (before.stage != step.state.stage) {
                log("relight: ${before.stage?.wire ?: "idle"} --${event.wire}--> ${step.state.stage?.wire ?: "idle"}")
            }
            return step.actions
        }
    }
}
