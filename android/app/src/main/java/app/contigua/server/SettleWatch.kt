package app.contigua.server

/**
 * The phone's settle watch (docs/PROTOCOL.md "UI tree" item 7, docs/specs/mcp.md
 * "Settling a display", MCP-81/MCP-107): a pure `(state, event) -> (state, actions)`
 * machine that watches one display until no content change came for `quietMs`
 * and nothing on it is loading, or until `timeoutMs` passes.
 *
 * The shell side ([UiAutomationTree]) feeds it classified facts: an event's
 * type and whether its window is on the watched display, ticks at the times it
 * asks for (one pending tick; a new [Action.ScheduleTick] replaces it), and the
 * loading check's answer. Each check is numbered: a check that a content change
 * dropped, or that outlived its watch, comes back with an old number and is
 * ignored, so it can never answer for a later check.
 */
object SettleWatch {

    /** `AccessibilityEvent`'s content-change types (MCP-107), as compile-time constants. */
    const val TYPE_VIEW_TEXT_CHANGED = 0x00000010
    const val TYPE_WINDOW_STATE_CHANGED = 0x00000020
    const val TYPE_WINDOW_CONTENT_CHANGED = 0x00000800
    const val TYPE_VIEW_SCROLLED = 0x00001000
    const val TYPE_WINDOWS_CHANGED = 0x00400000

    fun isContentChange(type: Int): Boolean = when (type) {
        TYPE_VIEW_TEXT_CHANGED, TYPE_WINDOW_STATE_CHANGED, TYPE_WINDOW_CONTENT_CHANGED,
        TYPE_VIEW_SCROLLED, TYPE_WINDOWS_CHANGED -> true
        else -> false
    }

    sealed interface State {
        data object Idle : State

        /**
         * Waiting for a quiet period. [lastChange] is the last counted change
         * (or the start); [loading] is what the last check found, cleared by a
         * change; [check] the number of the last check asked for.
         */
        data class Watching(
            val quietMs: Long, val timeoutMs: Long, val start: Long, val lastChange: Long,
            val events: Int, val loading: Boolean, val check: Int,
        ) : State

        /** Check [check] is in flight. */
        data class Checking(
            val quietMs: Long, val timeoutMs: Long, val start: Long, val lastChange: Long,
            val events: Int, val loading: Boolean, val check: Int,
        ) : State
    }

    sealed interface Event {
        data class Start(val quietMs: Long, val timeoutMs: Long, val now: Long) : Event
        data class A11y(val type: Int, val onDisplay: Boolean, val now: Long) : Event
        data class Tick(val now: Long) : Event
        data class Loading(val found: Boolean, val check: Int, val now: Long) : Event
        data object DisplayGone : Event
        data object SessionEnd : Event
    }

    sealed interface Action {
        data object Listen : Action
        data object StopListening : Action
        data class CheckLoading(val check: Int) : Action
        data class ScheduleTick(val atMs: Long) : Action

        sealed interface Reply : Action {
            data class Settled(val waitedMs: Long, val events: Int) : Reply
            data class StillChanging(val waitedMs: Long, val events: Int, val reason: String) : Reply
            data object Busy : Reply
            data object NoDisplay : Reply
        }
    }

    data class Step(val state: State, val actions: List<Action>)

    private val nothing = emptyList<Action>()

    fun reduce(state: State, event: Event): Step = when (state) {
        State.Idle -> when (event) {
            is Event.Start -> Step(
                State.Watching(event.quietMs, event.timeoutMs, event.now, event.now, 0, false, 0),
                listOf(Action.Listen, Action.ScheduleTick(event.now + minOf(event.quietMs, event.timeoutMs))),
            )
            is Event.A11y, is Event.Tick, is Event.Loading, Event.DisplayGone, Event.SessionEnd ->
                Step(State.Idle, nothing)
        }

        is State.Watching -> when (event) {
            is Event.A11y -> if (counts(event)) {
                Step(state.copy(lastChange = event.now, events = state.events + 1, loading = false), nothing)
            } else {
                Step(state, nothing)
            }
            is Event.Tick -> when {
                event.now - state.start >= state.timeoutMs -> timeout(event.now, state.start, state.events, state.loading)
                event.now - state.lastChange >= state.quietMs -> {
                    val check = state.check + 1
                    Step(
                        State.Checking(
                            state.quietMs, state.timeoutMs, state.start, state.lastChange,
                            state.events, state.loading, check,
                        ),
                        listOf(Action.CheckLoading(check), Action.ScheduleTick(state.start + state.timeoutMs)),
                    )
                }
                else -> Step(
                    state,
                    listOf(Action.ScheduleTick(minOf(state.lastChange + state.quietMs, state.start + state.timeoutMs))),
                )
            }
            // A check a change dropped: ignored.
            is Event.Loading -> Step(state, nothing)
            Event.DisplayGone -> Step(State.Idle, listOf(Action.StopListening, Action.Reply.NoDisplay))
            Event.SessionEnd -> Step(State.Idle, listOf(Action.StopListening))
            is Event.Start -> Step(state, listOf(Action.Reply.Busy))
        }

        is State.Checking -> when (event) {
            is Event.A11y -> if (counts(event)) {
                Step(
                    State.Watching(
                        state.quietMs, state.timeoutMs, state.start, event.now,
                        state.events + 1, false, state.check,
                    ),
                    listOf(Action.ScheduleTick(minOf(event.now + state.quietMs, state.start + state.timeoutMs))),
                )
            } else {
                Step(state, nothing)
            }
            is Event.Tick -> if (event.now - state.start >= state.timeoutMs) {
                timeout(event.now, state.start, state.events, state.loading)
            } else {
                Step(state, nothing)
            }
            is Event.Loading -> when {
                event.check != state.check -> Step(state, nothing)
                event.found -> Step(
                    State.Watching(
                        state.quietMs, state.timeoutMs, state.start, state.lastChange,
                        state.events, true, state.check,
                    ),
                    listOf(Action.ScheduleTick(minOf(event.now + state.quietMs, state.start + state.timeoutMs))),
                )
                else -> Step(
                    State.Idle,
                    listOf(Action.StopListening, Action.Reply.Settled(event.now - state.start, state.events)),
                )
            }
            Event.DisplayGone -> Step(State.Idle, listOf(Action.StopListening, Action.Reply.NoDisplay))
            Event.SessionEnd -> Step(State.Idle, listOf(Action.StopListening))
            is Event.Start -> Step(state, listOf(Action.Reply.Busy))
        }
    }

    private fun counts(event: Event.A11y) = event.onDisplay && isContentChange(event.type)

    private fun timeout(now: Long, start: Long, events: Int, loading: Boolean) = Step(
        State.Idle,
        listOf(
            Action.StopListening,
            Action.Reply.StillChanging(now - start, events, if (loading) "loading" else "changes"),
        ),
    )
}

/**
 * What a `ui.settle` watch answered (docs/PROTOCOL.md "UI tree" item 7): a
 * settled display, one still changing at the timeout, or why it could not watch.
 */
sealed interface SettleAnswer {
    data class Settled(val waitedMs: Long, val events: Int) : SettleAnswer
    data class StillChanging(val waitedMs: Long, val events: Int, val reason: String) : SettleAnswer
    data class Failure(val code: String, val sentence: String) : SettleAnswer
}
