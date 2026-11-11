package app.contigua.server

import java.util.concurrent.CopyOnWriteArrayList

/** A task-stack port a test drives by hand; [accept] false is a refused registration. */
class FakeTaskEvents : TaskStackEvents {
    var started = 0
    var stopped = 0
    var accept = true
    var handler: ((TaskStackEvent) -> Unit)? = null

    override fun start(onEvent: (TaskStackEvent) -> Unit): Boolean {
        started++
        if (!accept) return false
        handler = onEvent
        return true
    }

    override fun stop() {
        stopped++
        handler = null
    }

    fun emit(event: TaskStackEvent) {
        handler?.invoke(event)
    }
}

/** A task list + move seam; [adoptResult] is what `startActivityFromRecents` answered. */
class FakeTaskMove : TaskMove {
    val adoptCalls = CopyOnWriteArrayList<Pair<Int, Int>>()
    val moves = CopyOnWriteArrayList<Pair<Int, Int>>()
    val removes = CopyOnWriteArrayList<Int>()
    var adoptResult = true
    var tasks: List<SystemTask> = emptyList()

    override fun tasks(): List<SystemTask> = tasks

    override fun move(taskId: Int, displayId: Int): Boolean {
        moves.add(taskId to displayId)
        return false
    }

    override fun remove(taskId: Int): Boolean {
        removes.add(taskId)
        return true
    }

    override fun adopt(taskId: Int, displayId: Int): Boolean {
        adoptCalls.add(taskId to displayId)
        return adoptResult
    }
}

/** A JSON number from a session message (the decoder hands back Long). */
fun Map<String, Any?>.intValue(key: String): Int = (this[key] as? Number)?.toInt() ?: -1

/** A display-presence seam whose answers a test can change. */
class FixedPresence(
    @Volatile var hasTask: Boolean? = true,
    @Volatile var taskId: Int? = 7,
    private val label: String? = null,
) : TaskPresence {
    override fun hasTask(displayId: Int): Boolean? = hasTask
    override fun taskId(displayId: Int): Int? = taskId
    override fun taskLabel(taskId: Int): String? = label
}
