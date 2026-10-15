package dev.pocketdeck.server

/**
 * The system's task list and its task-to-display move, through reflection at
 * shell UID (docs/design/handoff.md).
 *
 * Listing goes through `IActivityTaskManager.getTasks` (service
 * "activity_task"), with the public `ActivityManager.getRunningTasks` behind
 * it. Moving goes through `IActivityTaskManager.moveRootTaskToDisplay`, which
 * is the binder call `am stack movetask`-style shell commands end up in; the
 * shell holds MANAGE_ACTIVITY_TASKS through the com.android.shell manifest.
 * A refusal is logged and returns false: the session relaunches the same
 * package on the new display instead ("fresh" handoff).
 */
internal class AndroidTaskMove(private val log: (String) -> Unit) : TaskMove {

    private val taskManager: Any? = Hidden.proxy("android.app.IActivityTaskManager", "activity_task")
    private val taskManagerClass: Class<*>? = Hidden.iface("android.app.IActivityTaskManager")

    private var loggedTasksPath = false
    private var loggedMovePath = false

    override fun tasks(): List<SystemTask>? {
        val raw = listViaTaskManager() ?: runGetRunningTasks() ?: return null
        val out = ArrayList<SystemTask>(raw.size)
        for (item in raw) {
            val info = item ?: continue
            val task = toSystemTask(info) ?: continue
            out.add(task)
        }
        if (!loggedTasksPath) {
            loggedTasksPath = true
            log("task list: ${raw.size} tasks -> ${out.size} continuable-shaped")
        }
        return out
    }

    override fun move(taskId: Int, displayId: Int): Boolean {
        return try {
            val tm = taskManager ?: return false
            val cls = taskManagerClass ?: return false
            val method = Hidden.method(cls, "moveRootTaskToDisplay", Hidden.T_INT, Hidden.T_INT)
                ?: return false
            method.invoke(tm, taskId, displayId)
            if (!loggedMovePath) {
                loggedMovePath = true
                log("moving task $taskId via IActivityTaskManager.moveRootTaskToDisplay")
            }
            true
        } catch (e: Throwable) {
            log("moveRootTaskToDisplay($taskId -> $displayId) failed: ${e.message ?: e}")
            false
        }
    }

    // ------------------------------------------------------------------

    /** `IActivityTaskManager.getTasks(maxNum)` -> the raw task list. */
    private fun listViaTaskManager(): List<*>? = runCatching {
        val tm = taskManager ?: return null
        val cls = taskManagerClass ?: return null
        val method = cls.methods.firstOrNull {
            it.name == "getTasks" && it.parameterTypes.size == 1 &&
                it.parameterTypes[0] == Hidden.T_INT
        } ?: return null
        method.invoke(tm, MAX_TASKS) as? List<*>
    }.getOrNull()

    /** The public (deprecated) API: full for shell UID, truncated for apps. */
    private fun runGetRunningTasks(): List<*>? = runCatching {
        val am = Class
            .forName("android.app.ActivityManager")
            .getMethod("getRunningTasks", Hidden.T_INT)
            .invoke(null, MAX_TASKS) as? List<*>
        if (am == null) null else am
    }.getOrNull()

    /** Reads a TaskInfo / RunningTaskInfo-shaped object (public fields, var names). */
    private fun toSystemTask(info: Any): SystemTask? {
        val id = intValue(info, "taskId") ?: return null
        val display = intValue(info, "displayId") ?: return null
        val component = componentValue(info, "topActivity") ?: componentValue(info, "baseActivity")
        val pkg = component?.packageName ?: ""
        val home = boolValue(info, "isHomeTask")
        return SystemTask(
            taskId = id,
            pkg = pkg,
            activity = component?.className,
            displayId = display,
            isHome = home,
            isSystemUi = pkg == "com.android.systemui",
        )
    }

    private fun intValue(info: Any, name: String): Int? = readMember(info, name) as? Int

    private fun boolValue(info: Any, name: String): Boolean = readMember(info, name) as? Boolean ?: false

    private fun componentValue(info: Any, name: String): android.content.ComponentName? =
        readMember(info, name) as? android.content.ComponentName

    /** A public field first, then a getter with the field's name; null when absent. */
    private fun readMember(info: Any, name: String): Any? {
        for (field in info.javaClass.fields) {
            if (field.name == name) {
                return runCatching { field.get(info) }.getOrNull()
            }
        }
        for (method in info.javaClass.methods) {
            if (method.name == "get${name.replaceFirstChar { it.uppercase() }}" && method.parameterTypes.isEmpty()) {
                return runCatching { method.invoke(info) }.getOrNull()
            }
        }
        return null
    }

    private companion object {
        /** The list is read newest-first; plenty for "what is on top of the screen". */
        const val MAX_TASKS = 20
    }
}
