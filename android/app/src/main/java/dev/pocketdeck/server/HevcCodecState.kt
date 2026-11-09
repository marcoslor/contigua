package dev.pocketdeck.server

/**
 * The process's HEVC encoder state (WIN-59): probed at most once, and a
 * configure or start failure retires HEVC for every later stream. The closed
 * states and one pure transition keep the field log readable:
 * `hevc: unknown --probe--> available`.
 */
internal class HevcCodecState(
    private val probe: () -> Probe,
) {

    /** What the one probe found. */
    sealed interface Probe {
        /** A hardware encoder exists; [supports] is its per-size check. */
        data class Hardware(val supports: (Int, Int) -> Boolean) : Probe
        data object Software : Probe
        data object Missing : Probe
    }

    sealed interface State {
        data object Unknown : State
        data class Available(val supports: (Int, Int) -> Boolean) : State
        data class Unavailable(val reason: String) : State
    }

    sealed interface Event {
        data class Probed(val result: Probe) : Event
        data object ConfigureFailed : Event
    }

    data class Transition(val state: State, val line: String?)

    private val lock = Any()

    @Volatile
    private var current: State = State.Unknown

    val state: State get() = current

    /** Probes once per process; a probe that finds no hardware latches `encoder`. */
    fun resolve(log: (String) -> Unit): State = synchronized(lock) {
        if (current == State.Unknown) {
            val moved = transition(current, Event.Probed(probe()))
            current = moved.state
            moved.line?.let(log)
        }
        current
    }

    /** The chosen HEVC encoder refused to configure or start: retire it for the process. */
    fun configureFailed(log: (String) -> Unit) {
        synchronized(lock) {
            val moved = transition(current, Event.ConfigureFailed)
            current = moved.state
            moved.line?.let(log)
        }
    }

    companion object {
        /** Pure: the next state and the one line a real transition writes. */
        fun transition(state: State, event: Event): Transition {
            val next = when (state) {
                State.Unknown -> when (event) {
                    is Event.Probed -> when (event.result) {
                        is Probe.Hardware -> State.Available(event.result.supports)
                        Probe.Software, Probe.Missing -> State.Unavailable("encoder")
                    }
                    Event.ConfigureFailed -> state
                }
                is State.Available -> when (event) {
                    is Event.Probed -> state
                    Event.ConfigureFailed -> State.Unavailable("configure")
                }
                is State.Unavailable -> state
            }
            val line = if (next === state) null else {
                "hevc: ${state.token()} --${event.token()}--> ${next.token()}"
            }
            return Transition(next, line)
        }

        private fun State.token(): String = when (this) {
            State.Unknown -> "unknown"
            is State.Available -> "available"
            is State.Unavailable -> "unavailable($reason)"
        }

        private fun Event.token(): String = when (this) {
            is Event.Probed -> "probe"
            Event.ConfigureFailed -> "configure"
        }
    }
}
