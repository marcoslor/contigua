package app.contigua.server

import android.os.IBinder
import java.lang.reflect.Method

/**
 * Cached reflection into the hidden system services.
 *
 * The code below only ever runs inside the Shizuku user service (shell UID), so
 * hidden APIs are reachable. Method handles are resolved once and reused so the
 * input path never pays for lookup.
 */
internal object Hidden {

    /** Missing-handle messages already logged, so each one is reported once. */
    private val loggedOnce = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

    /** @return true the first time this exact message is seen in this process. */
    fun firstTime(message: String): Boolean = loggedOnce.add(message)


    val T_INT: Class<*> = Int::class.javaPrimitiveType!!
    val T_LONG: Class<*> = Long::class.javaPrimitiveType!!
    val T_FLOAT: Class<*> = Float::class.javaPrimitiveType!!
    val T_BOOL: Class<*> = Boolean::class.javaPrimitiveType!!

    fun binder(service: String): IBinder? = try {
        val sm = Class.forName("android.os.ServiceManager")
        sm.getMethod("getService", String::class.java).invoke(null, service) as? IBinder
    } catch (_: Throwable) {
        null
    }

    fun iface(name: String): Class<*>? = try {
        Class.forName(name)
    } catch (_: Throwable) {
        null
    }

    /**
     * `android.os.SystemProperties.get(name)`; "" when unset, null when
     * unavailable. Android 17 refuses the hidden call for a service loaded
     * from an app APK even as shell (the person's phone), so a refused lookup
     * falls back to the same read through `/system/bin/getprop`.
     */
    fun systemProperty(name: String): String? = try {
        Class.forName("android.os.SystemProperties")
            .getMethod("get", String::class.java)
            .invoke(null, name) as? String
    } catch (_: Throwable) {
        getprop(name)
    }

    /** The shell's own read, for when the hidden Java call is refused. */
    private fun getprop(name: String): String? = try {
        val p = Runtime.getRuntime().exec(arrayOf("/system/bin/getprop", name))
        val text = p.inputStream.bufferedReader().use { it.readText() }.trim()
        p.waitFor()
        text.takeIf { it.isNotEmpty() }
    } catch (_: Throwable) {
        null
    }

    /** `IXxx.Stub.asInterface(binder)` for a hidden AIDL interface. */
    fun proxy(interfaceName: String, service: String): Any? {
        val b = binder(service) ?: return null
        return try {
            val stub = Class.forName("$interfaceName\$Stub")
            stub.getMethod("asInterface", IBinder::class.java).invoke(null, b)
        } catch (_: Throwable) {
            null
        }
    }

    /** First method on [cls] with the given name and parameter types, or null. */
    fun method(cls: Class<*>?, name: String, vararg types: Class<*>): Method? {
        if (cls == null) return null
        return try {
            cls.getMethod(name, *types)
        } catch (_: Throwable) {
            null
        }
    }
}

/** Hidden `ImageReader`-free IME policy HIDE value from WindowManager. */
internal const val IME_POLICY_HIDE = 2
