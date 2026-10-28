package dev.pocketdeck.server

/**
 * WIN-31: closing one window ends only that display's task.
 *
 * A virtual display is created with `FLAG_DESTROY_CONTENT_ON_REMOVAL`
 * ([WindowStream]), so releasing it usually takes the task's activity with it.
 * The task itself often survives: the phone's Recents keeps its card after the
 * display is gone, and every closed Mac window would leave one behind. So the
 * question is not "does it still run" but "does it still exist", running or in
 * Recents; the close removes the task in either case, and never stops the app:
 * its other windows keep streaming and the session stays up.
 *
 * Pure: the session reads the facts, this decides, and the caller performs it.
 * One transition per close, with a reason from a closed set for the log line.
 */
internal object CloseTask {

    enum class Action { NONE, REMOVE_TASK }

    /** Why. Ids and states only, so the line that carries it is R-PRIV-1 safe. */
    enum class Reason {
        /** The Phone Mirror: no task of its own. */
        MIRROR,
        /** The stream never reported a task id. */
        NO_TASK,
        /** Another window of this session shows the same task. */
        SHARED,
        /** The task still exists (running, or a card in Recents): end it. */
        EXISTS,
        /** Neither list knows it: the display's own removal was enough. */
        GONE,
        /** A list could not be read; `removeTask` on a gone id is a no-op, so remove. */
        UNREAD,
    }

    data class Decision(val action: Action, val reason: Reason)

    /**
     * @property counted an app stream (the Phone Mirror has no task of its own).
     * @property taskId the task the closed display showed; 0 when unknown.
     * @property otherTasks tasks the session's other windows show right now.
     * @property runningNow the system's running task ids after the display went;
     *   null when the phone could not read them.
     * @property recentsNow the task ids the system remembers in Recents (running
     *   or not); null when that read is not available.
     */
    data class Facts(
        val counted: Boolean,
        val taskId: Int,
        val otherTasks: Set<Int>,
        val runningNow: Set<Int>?,
        val recentsNow: Set<Int>?,
    )

    fun judge(facts: Facts): Decision {
        if (!facts.counted) return Decision(Action.NONE, Reason.MIRROR)
        if (facts.taskId <= 0) return Decision(Action.NONE, Reason.NO_TASK)
        // Another window shows this task: ending it would end that window too.
        if (facts.otherTasks.contains(facts.taskId)) return Decision(Action.NONE, Reason.SHARED)
        val running = facts.runningNow
        val recents = facts.recentsNow
        if (running?.contains(facts.taskId) == true) return Decision(Action.REMOVE_TASK, Reason.EXISTS)
        if (recents?.contains(facts.taskId) == true) return Decision(Action.REMOVE_TASK, Reason.EXISTS)
        if (running == null || recents == null) return Decision(Action.REMOVE_TASK, Reason.UNREAD)
        return Decision(Action.NONE, Reason.GONE)
    }
}
