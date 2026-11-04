package dev.pocketdeck.server

import android.content.ComponentName
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.Process

/**
 * `ITaskStackListener` at shell UID (WIN-44, WIN-48, WIN-49).
 *
 * The AIDL interface is hidden, so a dynamic proxy implements it and a plain
 * [Binder] decodes the callbacks the interface declares. Only the three events
 * the product needs are read: `onTaskCreated` (id and optional component),
 * `onTaskDisplayChanged` (id and display) and `onTaskRemoved` (id). Everything
 * else is acknowledged and ignored.
 *
 * Registration needs `MANAGE_ACTIVITY_TASKS`, held by the shell manifest. A
 * refusal is logged as a code and returns false: the session then has no report
 * path, and every other window operation is untouched.
 */
internal class AndroidTaskStackEvents(private val log: (String) -> Unit) : TaskStackEvents {

    @Volatile private var handler: ((TaskStackEvent) -> Unit)? = null
    private var manager: Any? = null
    private var listener: Any? = null
    private var registered = false

    override fun start(onEvent: (TaskStackEvent) -> Unit): Boolean {
        if (registered) {
            handler = onEvent
            return true
        }
        handler = onEvent
        return try {
            val iface = Class.forName(DESCRIPTOR)
            val stub = Class.forName("$DESCRIPTOR\$Stub")
            val codes = codes(iface, stub)
            val binder = CallbackBinder(codes, { handler })
            val proxy = java.lang.reflect.Proxy.newProxyInstance(
                iface.classLoader ?: ClassLoader.getSystemClassLoader(),
                arrayOf(iface),
            ) { _, method, _ ->
                when (method.name) {
                    "asBinder" -> binder
                    "toString" -> "PocketDeckTaskStackListener"
                    "hashCode" -> System.identityHashCode(binder)
                    "equals" -> false
                    else -> null
                }
            }
            val atmClass = Hidden.iface("android.app.IActivityTaskManager")
            val atm = Hidden.proxy("android.app.IActivityTaskManager", "activity_task")
            val register = Hidden.method(atmClass, "registerTaskStackListener", iface)
            if (atm == null || register == null) {
                log("task listener: refused (no register method)")
                handler = null
                return false
            }
            register.invoke(atm, proxy)
            manager = atm
            listener = proxy
            registered = true
            log("task listener: started uid=${Process.myUid()}")
            true
        } catch (t: Throwable) {
            val cause = (t as? java.lang.reflect.InvocationTargetException)?.cause ?: t
            log("task listener: refused (${cause.message ?: cause})")
            handler = null
            false
        }
    }

    override fun stop() {
        handler = null
        if (!registered) return
        registered = false
        val atm = manager
        val proxy = listener
        manager = null
        listener = null
        runCatching {
            val iface = Class.forName(DESCRIPTOR)
            val unregister = Hidden.method(
                Hidden.iface("android.app.IActivityTaskManager"),
                "unregisterTaskStackListener",
                iface,
            )
            if (atm != null && proxy != null && unregister != null) unregister.invoke(atm, proxy)
        }.onFailure { log("task listener: unregister failed (${it.message ?: it})") }
    }

    /**
     * The transaction codes, read from the Stub's declared fields (they are not
     * public), then the interface's, then the android16 declaration order.
     */
    private fun codes(iface: Class<*>, stub: Class<*>): Map<Int, Event> {
        val order = listOf(
            "onTaskStackChanged", "onActivityPinned", "onActivityUnpinned",
            "onActivityRestartAttempt", "onActivityForcedResizable",
            "onActivityDismissingDockedTask",
            "onActivityLaunchOnSecondaryDisplayFailed",
            "onActivityLaunchOnSecondaryDisplayRerouted",
            "onTaskCreated", "onTaskRemoved", "onTaskMovedToFront",
            "onTaskDescriptionChanged", "onActivityRequestedOrientationChanged",
            "onTaskRemovalStarted", "onTaskProfileLocked",
            "onTaskSnapshotChanged", "onTaskSnapshotInvalidated",
            "onBackPressedOnTaskRoot", "onTaskDisplayChanged",
            "onRecentTaskListUpdated", "onRecentTaskListFrozenChanged",
            "onRecentTaskRemovedForAddTask", "onTaskFocusChanged",
            "onTaskRequestedOrientationChanged", "onActivityRotation",
            "onTaskMovedToBack", "onLockTaskModeChanged",
        )
        fun code(name: String): Int {
            for (cls in listOf(iface, stub)) {
                val found = runCatching {
                    val field = cls.getDeclaredField("TRANSACTION_$name")
                    field.isAccessible = true
                    field.getInt(null)
                }.getOrNull()
                if (found != null) return found
            }
            return IBinder.FIRST_CALL_TRANSACTION + order.indexOf(name)
        }
        val map = HashMap<Int, Event>(3)
        map[code("onTaskCreated")] = Event.CREATED
        map[code("onTaskDisplayChanged")] = Event.DISPLAY_CHANGED
        map[code("onTaskRemoved")] = Event.REMOVED
        return map
    }

    private enum class Event { CREATED, DISPLAY_CHANGED, REMOVED }

    private class CallbackBinder(
        private val codes: Map<Int, Event>,
        private val handler: () -> ((TaskStackEvent) -> Unit)?,
    ) : Binder() {

        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code == IBinder.INTERFACE_TRANSACTION) return super.onTransact(code, data, reply, flags)
            val event = codes[code] ?: return true
            val emit = handler() ?: return true
            try {
                data.enforceInterface(DESCRIPTOR)
                when (event) {
                    Event.CREATED -> {
                        val taskId = data.readInt()
                        val component = if (data.readInt() != 0) {
                            ComponentName.CREATOR.createFromParcel(data)
                        } else {
                            null
                        }
                        emit(TaskStackEvent.Created(taskId, component?.packageName))
                    }
                    Event.DISPLAY_CHANGED -> {
                        val taskId = data.readInt()
                        emit(TaskStackEvent.DisplayChanged(taskId, data.readInt()))
                    }
                    Event.REMOVED -> emit(TaskStackEvent.Removed(data.readInt()))
                }
            } catch (_: Throwable) {
                // A parcel this build cannot read is not a reason to break the
                // system's callback or the stream.
            }
            return true
        }
    }

    private companion object {
        const val DESCRIPTOR = "android.app.ITaskStackListener"
    }
}
