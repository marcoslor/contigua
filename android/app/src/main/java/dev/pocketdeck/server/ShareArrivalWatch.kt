package dev.pocketdeck.server

/**
 * ISS-51: watches for the task an app starts right after a paste or a drop.
 * The first read of the task list is the caller's, at once (the Created event);
 * every re-read comes after [RETRY_MS] until the task is listed, and the watch
 * gives up after [MAX_TRIES] reads (about one second).
 *
 * Pure: the read result and the clock come in, the next state and the actions
 * come out. The caller performs the actions and owns the scheduler.
 */
internal class ShareArrivalWatch(
    private val windows: List<ShareArrivalPolicy.Window>,
) {

    /** The task list's answer for the watched task. */
    data class ListedTask(val pkg: String, val displayId: Int)

    sealed class State {
        /** The task is not listed yet; [triesLeft] counts this read. */
        data class Waiting(val triesLeft: Int, val startedAtMs: Long) : State()
        /** The task is listed and the policy has a target for it. */
        data class Found(val task: ListedTask, val move: Action.Move) : State()
        /** The task is listed; no move is wanted (or it already sits right). */
        data class Kept(val task: ListedTask) : State()
        /** The caller moved the task out of the phone's own display. */
        data class Moved(val stream: Int, val displayId: Int) : State()
        /** The task never appeared in the watched window. */
        data class GaveUp(val afterMs: Long) : State()
    }

    sealed class Action {
        data class RetryAfter(val ms: Long) : Action()
        data class Move(val stream: Int, val displayId: Int) : Action()
        object LogGaveUp : Action()
    }

    /** The state the caller's first read starts from; the read is at once. */
    fun start(nowMs: Long): State = State.Waiting(MAX_TRIES, nowMs)

    fun onRead(state: State, task: ListedTask?, nowMs: Long): Pair<State, List<Action>> {
        val waiting = state as? State.Waiting ?: return state to emptyList()
        if (task == null) {
            if (waiting.triesLeft <= 1) {
                return State.GaveUp(nowMs - waiting.startedAtMs) to listOf(Action.LogGaveUp)
            }
            return State.Waiting(waiting.triesLeft - 1, waiting.startedAtMs) to
                listOf(Action.RetryAfter(RETRY_MS))
        }
        return when (val decision = ShareArrivalPolicy.decide(windows, task.pkg, task.displayId, nowMs)) {
            is ShareArrivalPolicy.Decision.Move ->
                State.Found(task, Action.Move(decision.stream, decision.displayId)) to
                    listOf(Action.Move(decision.stream, decision.displayId))
            else -> State.Kept(task) to emptyList()
        }
    }

    /** The caller's move answer: the arrival settles either way. */
    fun onMoved(state: State, moved: Boolean): State {
        val found = state as? State.Found ?: return state
        return if (moved) State.Moved(found.move.stream, found.move.displayId) else State.Kept(found.task)
    }

    companion object {
        /** 16 ms: a display refresh, so the move follows the landing closely. */
        const val RETRY_MS = 16L
        /** 63 reads at 16 ms are about one second, the brief's bound. */
        const val MAX_TRIES = 63
    }
}
