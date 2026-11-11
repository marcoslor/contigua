package app.contigua.server

/**
 * The phone's task-arrival machine (WIN-44, WIN-48, WIN-49).
 *
 * Inputs are the system's task-stack callbacks, the phone's own launches and
 * moves, and the open app streams. Outputs are one `window.task` report, a
 * `moved_to_phone` close, an `app_exited` close, or nothing. The transition is
 * pure; the session performs the actions.
 *
 * Two states only: `Idle` (no app stream is open, so nothing can be reported)
 * and `Watching`. Everything else is a fact about the open streams and the
 * task ids already seen, not a mode.
 */
internal enum class TaskArrivalPhase { IDLE, WATCHING }

internal data class ArrivalStream(
    val stream: Int,
    val displayId: Int,
    val pkg: String,
    val taskId: Int,
)

internal sealed class TaskArrivalEvent {
    data class StreamOpened(
        val stream: Int,
        val displayId: Int,
        val pkg: String,
        val taskId: Int,
    ) : TaskArrivalEvent()

    /** The stream's task id was learned after the open (`window.opened`). */
    data class StreamTask(val stream: Int, val taskId: Int) : TaskArrivalEvent()

    data class StreamClosed(val stream: Int) : TaskArrivalEvent()

    /** The phone's own launch starts (window.open / window.launch). */
    data class OwnLaunchStarted(val pkg: String) : TaskArrivalEvent()

    /** ...and finishes, with the id it created when the phone could read one. */
    data class OwnLaunchFinished(val pkg: String, val taskId: Int) : TaskArrivalEvent()

    /** The phone moved a task itself (task.continue, window.adopt). */
    data class OwnMove(val taskId: Int) : TaskArrivalEvent()

    data class Created(val taskId: Int, val pkg: String?, val nowMs: Long) : TaskArrivalEvent()

    data class DisplayChanged(val taskId: Int, val displayId: Int, val nowMs: Long) : TaskArrivalEvent()

    data class Removed(val taskId: Int) : TaskArrivalEvent()

    /**
     * The answer to [TaskArrivalAction.ProbeDisplay] when the display has a
     * task but its top id could not be read; a readable top task answers with
     * [StreamTask] instead, and an empty display with [DisplayEmpty].
     */
    data class MoveCheck(val stream: Int, val displayStillHasTask: Boolean) : TaskArrivalEvent()

    /** The session's own exit poll found the stream's display empty. */
    data class DisplayEmpty(val stream: Int) : TaskArrivalEvent()
}

internal sealed class TaskArrivalAction {
    data class Report(val stream: Int, val taskId: Int, val pkg: String) : TaskArrivalAction()
    data class CloseMovedToPhone(val stream: Int) : TaskArrivalAction()
    data class CloseAppExited(val stream: Int) : TaskArrivalAction()
    data class ProbeDisplay(val stream: Int, val displayId: Int) : TaskArrivalAction()
}

internal data class TaskArrivalState(
    val phase: TaskArrivalPhase = TaskArrivalPhase.IDLE,
    val streams: Map<Int, ArrivalStream> = emptyMap(),
    /** Task ids the phone launched or moved: never reported (WIN-48). */
    val ownTasks: Set<Int> = emptySet(),
    /** Task ids already reported, or deliberately dropped by the throttle. */
    val reported: Set<Int> = emptySet(),
    val lastReportMs: Map<String, Long> = emptyMap(),
    /** Packages with a launch in flight. */
    val launchPkgs: Set<String> = emptySet(),
    /** Ids seen before their package was known (the first callback may omit it). */
    val unresolved: Map<Int, Long> = emptyMap(),
    /** Streams whose streamed task moved to the phone and await the empty check. */
    val moveChecks: Set<Int> = emptySet(),
)

internal data class TaskArrivalStep(
    val state: TaskArrivalState,
    val actions: List<TaskArrivalAction>,
)

internal object TaskArrivalMachine {

    /** The per-package report interval (WIN-44). */
    const val REPORT_INTERVAL_MS = 1_000L

    /** The phone's own display: a task moving there is the person opening it. */
    const val PHONE_DISPLAY = 0

    /** How long an id may wait for its package before the lead is dropped. */
    const val UNRESOLVED_MS = 5_000L

    fun transition(state: TaskArrivalState, event: TaskArrivalEvent): TaskArrivalStep {
        if (state.phase == TaskArrivalPhase.IDLE && event !is TaskArrivalEvent.StreamOpened) {
            return TaskArrivalStep(state, emptyList())
        }
        return when (event) {
            is TaskArrivalEvent.StreamOpened -> {
                val streams = state.streams + (event.stream to
                    ArrivalStream(event.stream, event.displayId, event.pkg, event.taskId))
                val own = if (event.taskId > 0) state.ownTasks + event.taskId else state.ownTasks
                TaskArrivalStep(
                    state.copy(
                        phase = TaskArrivalPhase.WATCHING,
                        streams = streams,
                        ownTasks = own,
                        unresolved = state.unresolved - event.taskId,
                        moveChecks = state.moveChecks - event.stream,
                    ),
                    emptyList(),
                )
            }

            is TaskArrivalEvent.StreamTask -> {
                val existing = state.streams[event.stream]
                    ?: return TaskArrivalStep(state, emptyList())
                if (existing.taskId == event.taskId) return TaskArrivalStep(state, emptyList())
                val own = if (event.taskId > 0) state.ownTasks + event.taskId else state.ownTasks
                TaskArrivalStep(
                    state.copy(
                        streams = state.streams + (event.stream to existing.copy(taskId = event.taskId)),
                        ownTasks = own,
                        unresolved = state.unresolved - event.taskId,
                        // A task is back on the display: the display-change
                        // probe no longer has an empty display to report.
                        moveChecks = state.moveChecks - event.stream,
                    ),
                    emptyList(),
                )
            }

            is TaskArrivalEvent.StreamClosed -> {
                val streams = state.streams - event.stream
                if (streams.isEmpty()) {
                    TaskArrivalStep(TaskArrivalState(), emptyList())
                } else {
                    TaskArrivalStep(
                        state.copy(streams = streams, moveChecks = state.moveChecks - event.stream),
                        emptyList(),
                    )
                }
            }

            is TaskArrivalEvent.OwnLaunchStarted ->
                TaskArrivalStep(state.copy(launchPkgs = state.launchPkgs + event.pkg), emptyList())

            is TaskArrivalEvent.OwnLaunchFinished -> {
                val own = if (event.taskId > 0) state.ownTasks + event.taskId else state.ownTasks
                TaskArrivalStep(
                    state.copy(
                        launchPkgs = state.launchPkgs - event.pkg,
                        ownTasks = own,
                        unresolved = state.unresolved - event.taskId,
                    ),
                    emptyList(),
                )
            }

            is TaskArrivalEvent.OwnMove -> {
                val own = if (event.taskId > 0) state.ownTasks + event.taskId else state.ownTasks
                TaskArrivalStep(
                    state.copy(ownTasks = own, unresolved = state.unresolved - event.taskId),
                    emptyList(),
                )
            }

            is TaskArrivalEvent.Created -> created(state, event)

            is TaskArrivalEvent.DisplayChanged -> {
                val moved = state.streams.values.filter {
                    it.taskId > 0 && it.taskId == event.taskId && it.displayId != event.displayId
                }
                var next = state
                val actions = ArrayList<TaskArrivalAction>(moved.size)
                for (stream in moved) {
                    if (event.displayId != PHONE_DISPLAY) continue
                    next = next.copy(moveChecks = next.moveChecks + stream.stream)
                    actions.add(TaskArrivalAction.ProbeDisplay(stream.stream, stream.displayId))
                }
                TaskArrivalStep(next, actions)
            }

            is TaskArrivalEvent.Removed -> {
                val stream = state.streams.values.firstOrNull { it.taskId == event.taskId }
                if (stream == null) {
                    TaskArrivalStep(state.copy(unresolved = state.unresolved - event.taskId), emptyList())
                } else {
                    // The removed task may have been a share sheet on top of
                    // the app's own task (ISS-33): only an empty display is
                    // the app's exit.
                    TaskArrivalStep(
                        state,
                        listOf(TaskArrivalAction.ProbeDisplay(stream.stream, stream.displayId)),
                    )
                }
            }

            is TaskArrivalEvent.MoveCheck -> {
                if (event.stream !in state.moveChecks) return TaskArrivalStep(state, emptyList())
                val next = state.copy(moveChecks = state.moveChecks - event.stream)
                if (event.displayStillHasTask) {
                    TaskArrivalStep(next, emptyList())
                } else {
                    TaskArrivalStep(closed(next, event.stream), listOf(TaskArrivalAction.CloseMovedToPhone(event.stream)))
                }
            }

            is TaskArrivalEvent.DisplayEmpty -> {
                val stream = state.streams[event.stream] ?: return TaskArrivalStep(state, emptyList())
                // The stream's task went to the phone and the display it left
                // is empty: that close is `moved_to_phone`. Otherwise the app
                // itself ended, even when its last top task was a share sheet.
                val action = if (event.stream in state.moveChecks) {
                    TaskArrivalAction.CloseMovedToPhone(stream.stream)
                } else {
                    TaskArrivalAction.CloseAppExited(stream.stream)
                }
                TaskArrivalStep(closed(state, stream.stream), listOf(action))
            }
        }
    }

    private fun created(state: TaskArrivalState, event: TaskArrivalEvent.Created): TaskArrivalStep {
        if (event.taskId in state.ownTasks) return TaskArrivalStep(state, emptyList())
        val pkg = event.pkg
        if (pkg == null) {
            // The first callback for an id may carry no component; keep it until
            // the second one names the package, but never forever.
            val stale = state.unresolved.filterValues { event.nowMs - it > UNRESOLVED_MS }.keys
            val unresolved = (state.unresolved - stale) +
                (event.taskId to (state.unresolved[event.taskId] ?: event.nowMs))
            return TaskArrivalStep(state.copy(unresolved = unresolved), emptyList())
        }
        var next = state.copy(unresolved = state.unresolved - event.taskId)
        if (pkg in next.launchPkgs) {
            return TaskArrivalStep(next.copy(ownTasks = next.ownTasks + event.taskId), emptyList())
        }
        val target = next.streams.values.filter { it.pkg == pkg }.minByOrNull { it.stream }
            ?: return TaskArrivalStep(next, emptyList())
        if (event.taskId in next.reported) return TaskArrivalStep(next, emptyList())
        val last = next.lastReportMs[pkg]
        if (last != null && event.nowMs - last < REPORT_INTERVAL_MS) {
            // The package already reported this second: the task is seen and
            // never reported later, which keeps "once per task" true.
            next = next.copy(reported = next.reported + event.taskId)
            return TaskArrivalStep(next, emptyList())
        }
        next = next.copy(
            reported = next.reported + event.taskId,
            lastReportMs = next.lastReportMs + (pkg to event.nowMs),
        )
        return TaskArrivalStep(next, listOf(TaskArrivalAction.Report(target.stream, event.taskId, pkg)))
    }

    /** Forget a closed stream; the machine returns to Idle with the last one. */
    private fun closed(state: TaskArrivalState, stream: Int): TaskArrivalState {
        val streams = state.streams - stream
        return if (streams.isEmpty()) TaskArrivalState() else
            state.copy(streams = streams, moveChecks = state.moveChecks - stream)
    }
}

/**
 * The synchronized face of [TaskArrivalMachine]: one event in, its actions out.
 * The log line is ids and event names only — a label is never printed.
 */
internal class TaskArrival(private val log: (String) -> Unit = {}) {

    @Volatile private var state = TaskArrivalState()

    val phase: TaskArrivalPhase get() = state.phase

    fun streamTask(stream: Int): Int? = state.streams[stream]?.taskId

    @Synchronized
    fun on(event: TaskArrivalEvent): List<TaskArrivalAction> {
        val before = state.phase
        val step = TaskArrivalMachine.transition(state, event)
        state = step.state
        if (before != state.phase) {
            log("task arrival: $before --${eventName(event)}--> ${state.phase}")
        } else if (step.actions.isNotEmpty()) {
            log("task arrival: ${eventName(event)} -> ${step.actions.joinToString { actionName(it) }}")
        }
        return step.actions
    }

    private fun eventName(event: TaskArrivalEvent): String = when (event) {
        is TaskArrivalEvent.StreamOpened -> "stream.open ${event.stream}"
        is TaskArrivalEvent.StreamTask -> "stream.task ${event.stream}"
        is TaskArrivalEvent.StreamClosed -> "stream.closed ${event.stream}"
        is TaskArrivalEvent.OwnLaunchStarted -> "own.launch ${event.pkg}"
        is TaskArrivalEvent.OwnLaunchFinished -> "own.launched task=${event.taskId}"
        is TaskArrivalEvent.OwnMove -> "own.move task=${event.taskId}"
        is TaskArrivalEvent.Created -> "created task=${event.taskId}"
        is TaskArrivalEvent.DisplayChanged -> "display task=${event.taskId} display=${event.displayId}"
        is TaskArrivalEvent.Removed -> "removed task=${event.taskId}"
        is TaskArrivalEvent.MoveCheck -> "move.check stream=${event.stream} hasTask=${event.displayStillHasTask}"
        is TaskArrivalEvent.DisplayEmpty -> "display.empty stream=${event.stream}"
    }

    private fun actionName(action: TaskArrivalAction): String = when (action) {
        is TaskArrivalAction.Report -> "report stream=${action.stream} task=${action.taskId}"
        is TaskArrivalAction.CloseMovedToPhone -> "close.moved_to_phone stream=${action.stream}"
        is TaskArrivalAction.CloseAppExited -> "close.app_exited stream=${action.stream}"
        is TaskArrivalAction.ProbeDisplay -> "probe stream=${action.stream} display=${action.displayId}"
    }
}
