package dev.pocketdeck.server

/**
 * WIN-28: `window.title` on an app stream at most once a second, and the last
 * label always goes out.
 *
 * A timer debounce would drop the final value (a label that arrives just after
 * a send and then stays would never reach the Mac), so this is an explicit
 * machine instead: it holds the newest label and asks to be woken at the exact
 * time the next one may go out.
 *
 * States:
 * - [Phase.IDLE] nothing has gone out yet: the first label goes at once.
 * - [Phase.SENT] the last label went out at [State.sentAtMs].
 * - [Phase.HOLDING] a newer label waits for `sentAtMs + INTERVAL_MS`.
 *
 * Events are [Event.Label] (the phone's current label), [Event.Immediate] (the
 * display's top app changed, so the message carrying `label`/`pkg` must go now
 * and its `title` counts as this second's send) and [Event.Wake] (the wait an
 * [Action.Wake] asked for has passed). Actions are returned, never performed:
 * [Action.Send] and [Action.Wake].
 */
internal object TaskLabelThrottle {

    const val INTERVAL_MS = 1_000L

    enum class Phase { IDLE, SENT, HOLDING }

    data class State(
        val phase: Phase = Phase.IDLE,
        /** The label the Mac was last told. */
        val sent: String? = null,
        /** The newest label the phone reported. */
        val latest: String? = null,
        val sentAtMs: Long = 0,
    )

    sealed interface Event {
        /** The phone reports this label at [nowMs]. */
        data class Label(val label: String, val nowMs: Long) : Event

        /**
         * The display's top app changed at [nowMs]: `window.title` goes at once
         * with `label`/`pkg` and the current [label], and counts as a send.
         */
        data class Immediate(val label: String, val nowMs: Long) : Event

        /** The wait an earlier [Action.Wake] asked for has passed. */
        data class Wake(val nowMs: Long) : Event
    }

    sealed interface Action {
        data class Send(val label: String) : Action

        /** Come back at [atMs]: the held label must not wait for the next poll. */
        data class Wake(val atMs: Long) : Action
    }

    data class Transition(val state: State, val actions: List<Action>)

    fun transition(state: State, event: Event): Transition = when (event) {
        is Event.Label -> onLabel(state, event)
        is Event.Immediate -> onImmediate(state, event)
        is Event.Wake -> onWake(state, event)
    }

    /**
     * Every phase answers an identity change the same way: it goes now, and its
     * title is what the Mac was last told. A label that waited behind it is
     * superseded (it belonged to the previous app).
     */
    private fun onImmediate(state: State, event: Event.Immediate): Transition =
        send(state.copy(latest = event.label), event.label, event.nowMs)

    private fun onLabel(state: State, event: Event.Label): Transition {
        val next = state.copy(latest = event.label)
        return when (state.phase) {
            Phase.IDLE -> send(next, event.label, event.nowMs)
            // The label the Mac already shows came back: nothing is waiting.
            Phase.SENT, Phase.HOLDING -> when (event.label) {
                state.sent -> Transition(next.copy(phase = Phase.SENT), emptyList())
                else -> {
                    val due = state.sentAtMs + INTERVAL_MS
                    if (event.nowMs >= due) {
                        send(next, event.label, event.nowMs)
                    } else {
                        Transition(next.copy(phase = Phase.HOLDING), listOf(Action.Wake(due)))
                    }
                }
            }
        }
    }

    private fun onWake(state: State, event: Event.Wake): Transition {
        if (state.phase != Phase.HOLDING) return Transition(state, emptyList())
        val latest = state.latest ?: return Transition(state.copy(phase = Phase.SENT), emptyList())
        val due = state.sentAtMs + INTERVAL_MS
        if (event.nowMs < due) return Transition(state, listOf(Action.Wake(due)))
        if (latest == state.sent) return Transition(state.copy(phase = Phase.SENT), emptyList())
        return send(state, latest, event.nowMs)
    }

    private fun send(state: State, label: String, nowMs: Long): Transition = Transition(
        state.copy(phase = Phase.SENT, sent = label, sentAtMs = nowMs),
        listOf(Action.Send(label)),
    )
}
