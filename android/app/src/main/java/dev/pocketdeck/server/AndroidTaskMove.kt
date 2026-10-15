package dev.pocketdeck.server

import android.content.Intent
import android.content.pm.PackageManager

/**
 * The system's task list and its task-to-display move, through reflection at
 * shell UID (docs/design/handoff.md).
 *
 * Listing prefers `IActivityTaskManager.getTasks(int, boolean, boolean, int)`
 * (the one-arg form of older versions and the public `getRunningTasks` behind
 * it), falling back to `getAllRootTaskInfos`. The move is
 * `IActivityTaskManager.moveRootTaskToDisplay(taskId, displayId)` — the binder
 * call the `cmd activity display move-stack`-style shell commands end in; the
 * shell holds MANAGE_ACTIVITY_TASKS through the com.android.shell manifest.
 * A move is verified by re-reading the list (the service returns void and
 * quietly ignores an unknown task id); a refusal logs and returns false, and
 * the session relaunches the same package on the display instead ("fresh").
 */
internal class AndroidTaskMove(private val ctx: android.content.Context, private val log: (String) -> Unit) : TaskMove {

    private val taskManager: Any? = Hidden.proxy("android.app.IActivityTaskManager", "activity_task")
    private val taskManagerClass: Class<*>? = Hidden.iface("android.app.IActivityTaskManager")

    private var loggedTasksPath = false


    /**
     * Package(s) that answer CATEGORY_HOME. The task list's `isHomeTask` flag
     * is not reliably set across API levels (verified: the launcher's task
     * reports no flag on API 36), so the home surface is excluded by name too.
     */
    @Volatile private var homePackages: Set<String> = emptySet()

    override fun tasks(): List<SystemTask>? {
        if (homePackages.isEmpty()) {
            homePackages = resolveHomePackages()
            log("home packages: $homePackages")
        }
        val raw = viaGetTasks() ?: viaAllRootTaskInfos() ?: run {
            log("task list: no source answered (getTasks / getAllRootTaskInfos)")
            return null
        }
        val out = ArrayList<SystemTask>(raw.size)
        for (item in raw) {
            val info = item ?: continue
            val task = toSystemTask(info) ?: continue
            out.add(task)
        }
        if (!loggedTasksPath) {
            loggedTasksPath = true
            log("task list (first): ${raw.size} entries, ${out.size} with a package")
        }
        log("picked pool: ${out.joinToString { "${it.pkg}#" + it.taskId + "@d" + it.displayId + (if (it.isHome) "(home)" else "") + (if (it.isSystemUi) "(sysui)" else "") }}")
        return out
    }

    override fun move(taskId: Int, displayId: Int): Boolean {
        val ok = try {
            val tm = taskManager ?: return false
            val cls = taskManagerClass ?: return false
            val method = Hidden.method(cls, "moveRootTaskToDisplay", Hidden.T_INT, Hidden.T_INT)
                ?: run { log("no IActivityTaskManager.moveRootTaskToDisplay"); return false }
            method.invoke(tm, taskId, displayId)
            log("moving task $taskId via IActivityTaskManager.moveRootTaskToDisplay")
            true
        } catch (e: Throwable) {
            log("moveRootTaskToDisplay($taskId -> $displayId) refused: ${e.message ?: e}")
            false
        }
        // The service returns void and logs-and-returns on an unknown id, so
        // the reply alone is no proof: check where the task actually ended up.
        if (!ok) return false
        val landed = runCatching { tasks() }.getOrNull()
        val verified = landed != null && landed.any { it.taskId == taskId && it.displayId == displayId }
        if (!verified) log("move: task $taskId did not report display $displayId after the call")
        return verified
    }

    // ------------------------------------------------------------------

    /** `IActivityTaskManager.getTasks(maxNum, filterOnlyVisible, keepIntentExtra, displayId)`; -1 = every display. */
    private fun viaGetTasks(): List<*>? {
        val tm = taskManager ?: return null
        val cls = taskManagerClass ?: return null
        val method = cls.methods.firstOrNull {
            it.name == "getTasks" && it.parameterTypes.contentEquals(arrayOf(Hidden.T_INT, Hidden.T_BOOL, Hidden.T_BOOL, Hidden.T_INT))
        }
        if (method == null) return null
        return runCatching { @Suppress("UNCHECKED_CAST") method.invoke(tm, MAX_TASKS, false, false, -1) as? List<*> }
            .onFailure { log("getTasks failed: ${it.message ?: it}") }
            .getOrNull()
            ?.takeIf { it.isNotEmpty() }
    }

    /** One entry per root task (a display's task stack); enough to find the top task. */
    private fun viaAllRootTaskInfos(): List<*>? {
        val tm = taskManager ?: return null
        val cls = taskManagerClass ?: return null
        val method = cls.methods.firstOrNull { it.name == "getAllRootTaskInfos" && it.parameterTypes.isEmpty() }
            ?: return null
        return runCatching { method.invoke(tm) as? List<*> }
            .onFailure { log("getAllRootTaskInfos failed: ${it.message ?: it}") }
            .getOrNull()
            ?.takeIf { it.isNotEmpty() }
    }

    /** Reads a TaskInfo / RunningTaskInfo-shaped object (public fields, then getters). */
    private fun toSystemTask(info: Any): SystemTask? {
        val id = intValue(info, "taskId") ?: return null
        val display = intValue(info, "displayId") ?: return null
        val component = componentValue(info, "topActivity") ?: componentValue(info, "baseActivity")
        val pkg = component?.packageName ?: ""
        val home = boolValue(info, "isHomeTask") || homePackages.contains(pkg)
        return SystemTask(
            taskId = id,
            pkg = pkg,
            activity = component?.className,
            displayId = display,
            isHome = home,
            isSystemUi = pkg == "com.android.systemui",
        )
    }

    /** The default package that answers CATEGORY_HOME. Only the default home:
     *  queryIntentActivities also returns stray home declarations (Settings does on AOSP). */
    private fun resolveHomePackages(): Set<String> {
        val out = HashSet<String>()
        runCatching {
            val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
            ctx.packageManager.resolveActivity(home, PackageManager.MATCH_DEFAULT_ONLY)
                ?.activityInfo?.packageName?.let(out::add)
        }.onFailure { log("home resolution failed: ${it.message ?: it}") }
        return out
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
