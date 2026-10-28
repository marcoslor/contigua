package dev.pocketdeck.server

/**
 * WIN-31: closing one window ends only that display's task.
 *
 * A virtual display is created with `FLAG_DESTROY_CONTENT_ON_REMOVAL`
 * ([WindowStream]), so releasing it usually takes its task with it — the
 * emulator check reports which of the two happened. When the task outlives its
 * display, the phone removes it by id. It never stops the app: the app's other
 * windows keep streaming and the session stays up.
 *
 * Pure: the session reads the facts, this decides, and the caller performs it.
 */
internal object CloseTask {

    enum class Action { NONE, REMOVE_TASK }

    /**
     * @property counted an app stream (the Phone Mirror has no task of its own).
     * @property taskId the task the closed display showed; 0 when unknown.
     * @property otherTasks tasks the session's other windows show right now.
     * @property tasksNow the system's task ids after the display went; null when
     *   the phone could not read them (the display's own removal is then trusted).
     */
    data class Facts(
        val counted: Boolean,
        val taskId: Int,
        val otherTasks: Set<Int>,
        val tasksNow: Set<Int>?,
    )

    fun decide(facts: Facts): Action {
        if (!facts.counted) return Action.NONE
        if (facts.taskId <= 0) return Action.NONE
        // Another window shows this task: ending it would end that window too.
        if (facts.otherTasks.contains(facts.taskId)) return Action.NONE
        val tasks = facts.tasksNow ?: return Action.NONE
        return if (tasks.contains(facts.taskId)) Action.REMOVE_TASK else Action.NONE
    }
}
