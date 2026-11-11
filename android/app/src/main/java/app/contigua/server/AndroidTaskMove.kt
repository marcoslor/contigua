package app.contigua.server

import android.app.ActivityOptions
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle

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
    private var loggedReadFailure = false
    private var loggedRecentsPath = false


    /**
     * Package(s) that answer CATEGORY_HOME. The task list's `isHomeTask` flag
     * is not reliably set across API levels (verified: the launcher's task
     * reports no flag on API 36), so the home surface is excluded by name too.
     */
    @Volatile private var homePackages: Set<String> = emptySet()

    override fun tasks(): List<SystemTask>? = read(verbose = true)

    /**
     * The same read without the per-call log lines: `remove` re-reads the list
     * every 50 ms while the system settles, and a full task list per poll would
     * bury the one line that matters.
     */
    private fun quietTasks(): List<SystemTask>? = read(verbose = false)

    private fun read(verbose: Boolean): List<SystemTask>? {
        if (homePackages.isEmpty()) {
            homePackages = resolveHomePackages()
            log("home packages: $homePackages")
        }
        val raw = viaGetTasks() ?: viaAllRootTaskInfos() ?: run {
            if (verbose) log("task list: no source answered (getTasks / getAllRootTaskInfos)")
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
        if (verbose) {
            log("picked pool: ${out.joinToString { "${it.pkg}#" + it.taskId + "@d" + it.displayId + (if (it.isHome) "(home)" else "") + (if (it.isSystemUi) "(sysui)" else "") }}")
        }
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

    /**
     * WIN-46: adopts a task the app started itself. `moveRootTaskToDisplay`
     * refuses a task that is a child of the adjacent split, but Recents with a
     * launch display reparents it into the target display's fullscreen root
     * (docs/research/in-stream-window.md). The service's return code is not the
     * proof: the task list is re-read and the id must report the display.
     */
    override fun adopt(taskId: Int, displayId: Int): Boolean {
        if (taskId <= 0 || displayId < 0) return false
        val tm = taskManager ?: return false
        val cls = taskManagerClass ?: return false
        val method = Hidden.method(cls, "startActivityFromRecents", Hidden.T_INT, Bundle::class.java)
            ?: run { log("no IActivityTaskManager.startActivityFromRecents"); return false }
        val options = ActivityOptions.makeBasic()
        options.setLaunchDisplayId(displayId)
        val fullscreen = runCatching {
            options.javaClass
                .getMethod("setLaunchWindowingMode", Int::class.javaPrimitiveType)
                .invoke(options, WINDOWING_FULLSCREEN)
        }.isSuccess
        val result = try {
            method.invoke(tm, taskId, options.toBundle())
        } catch (e: Throwable) {
            val cause = (e as? java.lang.reflect.InvocationTargetException)?.cause ?: e
            log("startActivityFromRecents($taskId -> $displayId) refused: ${cause.message ?: cause}")
            return false
        }
        val landed = runCatching { tasks() }.getOrNull()
        val verified = landed != null && landed.any { it.taskId == taskId && it.displayId == displayId }
        log("adopt task=$taskId display=$displayId result=$result fullscreen=$fullscreen verified=$verified")
        if (!verified) log("adopt: task $taskId did not report display $displayId after the call")
        return verified
    }

    /**
     * WIN-31: ends one task and proves it went. The service returns void, so the
     * task is re-read from both lists — running tasks and Recents — because a
     * closed window's card outlives its activity. A task the system still lists
     * after a second is reported as not removed.
     */
    override fun remove(taskId: Int): Boolean {
        val tm = taskManager ?: return false
        val cls = taskManagerClass ?: return false
        val method = Hidden.method(cls, "removeTask", Hidden.T_INT) ?: run {
            log("no IActivityTaskManager.removeTask")
            return false
        }
        try {
            method.invoke(tm, taskId)
        } catch (e: Throwable) {
            log("removeTask($taskId) refused: ${e.message ?: e}")
            return false
        }
        val deadline = System.currentTimeMillis() + REMOVE_VERIFY_MS
        var polls = 0
        while (true) {
            polls++
            val listed = runCatching { quietTasks() }.getOrNull()
            val recents = runCatching { recentTaskIds() }.getOrNull()
            val goneFromRunning = listed != null && listed.none { it.taskId == taskId }
            // A Recents read that is not available cannot veto a running-list
            // read that proves the task gone.
            val goneFromRecents = recents == null || taskId !in recents
            if (goneFromRunning && goneFromRecents) {
                log("removeTask($taskId): gone from tasks and recents after $polls read(s)")
                return true
            }
            if (System.currentTimeMillis() >= deadline) {
                log("removeTask($taskId): still listed after $polls read(s)")
                return false
            }
            Thread.sleep(50)
        }
    }

    /**
     * WIN-31: the ids Recents still holds, running or not
     * (`IActivityTaskManager.getRecentTasks`). An empty answer is treated as
     * unreadable: a session with windows always has tasks the phone remembers,
     * so an empty list means the call was filtered for this caller, and
     * "not there" must never be concluded from a filtered reply.
     */
    override fun recentTaskIds(): Set<Int>? {
        val tm = taskManager ?: return null
        val cls = taskManagerClass ?: return null
        val method = cls.methods.firstOrNull {
            it.name == "getRecentTasks" &&
                it.parameterTypes.contentEquals(arrayOf(Hidden.T_INT, Hidden.T_INT, Hidden.T_INT))
        } ?: run {
            if (!loggedRecentsPath) {
                loggedRecentsPath = true
                log("no IActivityTaskManager.getRecentTasks(int,int,int)")
            }
            return null
        }
        val raw = runCatching {
            method.invoke(tm, MAX_RECENTS, RECENT_FLAGS, currentUserId())
        }.onFailure { logReadFailure("getRecentTasks", it) }.getOrNull() as? List<*> ?: return null
        val ids = raw.mapNotNull { info -> info?.let { intValue(it, "taskId") } }.toSet()
        if (ids.isEmpty()) {
            if (!loggedRecentsPath) {
                loggedRecentsPath = true
                log("recents: empty answer treated as unreadable")
            }
            return null
        }
        if (!loggedRecentsPath) {
            loggedRecentsPath = true
            log("recents: ${ids.size} task id(s)")
        }
        return ids
    }

    // ------------------------------------------------------------------

    /** One line per removal: a verify loop that failed every 50 ms must not repeat itself. */
    private fun logReadFailure(what: String, e: Throwable) {
        if (loggedReadFailure) return
        loggedReadFailure = true
        log("$what failed: ${e.message ?: e}")
    }

    /** `IActivityTaskManager.getTasks(maxNum, filterOnlyVisible, keepIntentExtra, displayId)`; -1 = every display. */
    private fun viaGetTasks(): List<*>? {
        val tm = taskManager ?: return null
        val cls = taskManagerClass ?: return null
        val method = cls.methods.firstOrNull {
            it.name == "getTasks" && it.parameterTypes.contentEquals(arrayOf(Hidden.T_INT, Hidden.T_BOOL, Hidden.T_BOOL, Hidden.T_INT))
        }
        if (method == null) return null
        return runCatching { @Suppress("UNCHECKED_CAST") method.invoke(tm, MAX_TASKS, false, false, -1) as? List<*> }
            .onFailure { logReadFailure("getTasks", it) }
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
            .onFailure { logReadFailure("getAllRootTaskInfos", it) }
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

    /**
     * The user this process runs as, for `getRecentTasks`'s user argument.
     * `UserHandle.getUserId` is not in the public SDK, so it is reflected; the
     * phone's owner is user 0 when that fails.
     */
    private fun currentUserId(): Int = runCatching {
        Class.forName("android.os.UserHandle")
            .getMethod("getUserId", Int::class.javaPrimitiveType)
            .invoke(null, android.os.Process.myUid()) as Int
    }.getOrDefault(0)

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

        /** Recents keeps finished tasks too, so it needs the deeper cut. */
        const val MAX_RECENTS = 100

        /** `FLAG_ACTIVITY_...` flags are for launches; Recents needs none. */
        const val RECENT_FLAGS = 0

        /** How long a removed task may still be listed while the system settles. */
        const val REMOVE_VERIFY_MS = 1_000L

        /** `ActivityOptions`' hidden fullscreen windowing mode. */
        const val WINDOWING_FULLSCREEN = 1
    }
}
