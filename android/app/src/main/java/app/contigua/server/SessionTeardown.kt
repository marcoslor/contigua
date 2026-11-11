package app.contigua.server

/**
 * One session's teardown (docs/specs/pairing.md PAIR-20). A session serves while
 * [State.LIVE]; it stops reading after its last frame when it refuses or fails
 * ([State.ENDING]); a drop from outside — the app's push changed what it vouches
 * for, a gate closed — cuts the transport at once ([State.DROPPED]); and
 * [State.FINISHED] is the reader loop done with its cleanup.
 *
 * One closed set of states, one pure transition function, the caller runs the
 * returned actions: the difference between "stop after this frame" and "cut it
 * now" is exactly what the drop rule is about, so it must not hide in two flags.
 */
internal object SessionTeardown {

    enum class State {
        /** Reading and writing: a live session. */
        LIVE,

        /** A refusal or error went out; the reader stops, the writer drains it. */
        ENDING,

        /** Dropped from outside: the transport is cut, nothing is served again. */
        DROPPED,

        /** The reader loop ended and its cleanup ran: nothing is left. */
        FINISHED,
    }

    sealed interface Event {
        /** `close()`: the server's drop, a gate, a shutdown. Never waits. */
        data object Drop : Event

        /** This session decided to end after its last frame (`finishWithError`). */
        data object Stop : Event

        /** The reader loop is over (EOF, timeout, error); cleanup runs. */
        data object Ended : Event
    }

    enum class Action {
        /**
         * Cut the connection now: the plain socket under TLS, then the TLS
         * socket's own close. The only action, because [Event.Ended] runs after
         * the cleanup that already closes what it must.
         */
        ABORT,
    }

    data class Step(
        val from: State,
        val to: State,
        val event: Event,
        val actions: List<Action>,
    )

    /** The pure transition: (state, event) -> (new state, actions). */
    fun transition(state: State, event: Event): Step = when (state) {
        State.LIVE -> when (event) {
            Event.Drop -> Step(state, State.DROPPED, event, listOf(Action.ABORT))
            Event.Stop -> Step(state, State.ENDING, event, emptyList())
            Event.Ended -> Step(state, State.FINISHED, event, emptyList())
        }

        State.ENDING -> when (event) {
            Event.Drop -> Step(state, State.DROPPED, event, listOf(Action.ABORT))
            // A second refusal is not a second decision.
            Event.Stop -> Step(state, state, event, emptyList())
            Event.Ended -> Step(state, State.FINISHED, event, emptyList())
        }

        State.DROPPED -> when (event) {
            Event.Drop -> Step(state, state, event, emptyList())
            Event.Stop -> Step(state, state, event, emptyList())
            Event.Ended -> Step(state, State.FINISHED, event, emptyList())
        }

        State.FINISHED -> Step(state, state, event, emptyList())
    }

    /** A log name for a state or an event; never carries session data. */
    fun describe(state: State): String = state.name.lowercase()

    fun describe(event: Event): String = when (event) {
        Event.Drop -> "drop"
        Event.Stop -> "stop"
        Event.Ended -> "ended"
    }
}
