package dev.pocketdeck.server

import android.content.ComponentName
import android.content.Context
import java.lang.reflect.Method

/**
 * Best-effort task lookup on a hidden `IActivityTaskManager.getTasks`: the top
 * app (for `window.title`) and whether the display still has any task (for
 * app-exit detection). The signature varies across releases, so every candidate
 * is tried and any failure yields null (no title sent / no exit decision).
 */
internal class AndroidWindowObserver(private val ctx: Context, private val log: (String) -> Unit) : WindowObserver, TaskPresence {

    private val atm: Any? = Hidden.proxy("android.app.IActivityTaskManager", "activity_task")
        ?: Hidden.proxy("android.app.IActivityManager", "activity")
    private val methods: List<Method> =
        Hidden.iface("android.app.IActivityTaskManager")?.methods?.filter { it.name == "getTasks" }.orEmpty()

    private var loggedFailure = false

    override fun topTask(displayId: Int): TopTask? {
        val info = firstTask(displayId) ?: return null
        val pkg = packageOf(info) ?: return null
        val taskId = runCatching { info.javaClass.getField("taskId").get(info) as? Int }.getOrNull() ?: 0
        return TopTask(pkg, label(pkg), taskId, taskLabel(info) ?: descriptionLabel(taskId))
    }

    /**
     * `taskDescription.label`: the task's own title, which a browser or a chat
     * app updates as the person moves around. Never logged as text (R-PRIV-1).
     */
    private fun taskLabel(info: Any): String? = runCatching {
        val description = info.javaClass.getField("taskDescription").get(info) ?: return null
        val text = description.javaClass.getMethod("getLabel").invoke(description) as? CharSequence
        text?.toString()?.takeIf { it.isNotBlank() }
    }.getOrNull()

    /**
     * A task list read without extras can arrive with a description that carries
     * only colours: ask the task manager for the description by id then. Null
     * when this phone has neither, and the app's label is the fallback.
     */
    private fun descriptionLabel(taskId: Int): String? {
        if (taskId <= 0) return null
        val manager = atm ?: return null
        val cls = Hidden.iface("android.app.IActivityTaskManager") ?: return null
        val method = Hidden.method(cls, "getTaskDescription", Hidden.T_INT) ?: return null
        return runCatching {
            val description = method.invoke(manager, taskId) ?: return null
            val text = description.javaClass.getMethod("getLabel").invoke(description) as? CharSequence
            text?.toString()?.takeIf { it.isNotBlank() }
        }.getOrNull()
    }

    /** null when the query could not be made (as opposed to an empty task list). */
    /** The display's top task id for `window.opened`; null when the query fails. */
    override fun taskId(displayId: Int): Int? {
        val info = firstTask(displayId) ?: return null
        return runCatching { info.javaClass.getField("taskId").get(info) as? Int }.getOrNull()
    }

    override fun hasTask(displayId: Int): Boolean? {
        val manager = atm ?: return null
        for (method in methods) {
            val tasks = try {
                method.invoke(manager, *buildArgs(method.parameterTypes, displayId)) as? List<*>
            } catch (e: Throwable) {
                logFailure(e)
                continue
            }
            return tasks?.isNotEmpty() ?: false
        }
        return null
    }

    private fun firstTask(displayId: Int): Any? {
        val manager = atm ?: return null
        for (method in methods) {
            val tasks = try {
                method.invoke(manager, *buildArgs(method.parameterTypes, displayId)) as? List<*>
            } catch (e: Throwable) {
                logFailure(e)
                continue
            }
            return tasks?.firstOrNull() ?: return null
        }
        return null
    }

    private fun logFailure(e: Throwable) {
        if (!loggedFailure) {
            loggedFailure = true
            log("task query failed: ${e.message}")
        }
    }

    private fun buildArgs(types: Array<Class<*>>, displayId: Int): Array<Any?> {
        val args = Array<Any?>(types.size) { null }
        for (i in types.indices) {
            val t = types[i]
            args[i] = when {
                t == Int::class.javaPrimitiveType && i == types.lastIndex -> displayId
                t == Int::class.javaPrimitiveType -> 1 // maxNum
                t == Boolean::class.javaPrimitiveType -> false
                else -> null
            }
        }
        return args
    }

    private fun packageOf(info: Any): String? {
        for (name in listOf("topActivity", "baseActivity", "baseIntent")) {
            val component = runCatching { info.javaClass.getField(name).get(info) }.getOrNull() ?: continue
            when (component) {
                is ComponentName -> return component.packageName
                is android.content.Intent -> component.component?.packageName?.let { return it }
            }
        }
        return runCatching {
            (info.javaClass.getField("topActivityInfo").get(info) as? android.content.pm.ActivityInfo)?.packageName
        }.getOrNull()
    }

    private fun label(pkg: String): String = runCatching {
        val pm = ctx.packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
    }.getOrDefault(pkg)
}
