package dev.pocketdeck.server

import android.os.IBinder
import java.lang.reflect.Method

/**
 * Powers the *physical* panel off and back on through SurfaceFlinger.
 *
 * Needed only on builds where a streaming virtual display shares the panel's
 * display group: the group wake the VD needs also turns the panel on, and this
 * puts the panel back off without disturbing the VD. It is the same lever the
 * platform's own display power controller uses, so a later platform state change
 * (the user waking the phone) re-applies the normal mode by itself.
 *
 * Physical display tokens moved out of `SurfaceControl` on Android 14, so the
 * token comes from `com.android.server.display.DisplayControl` (a `services.jar`
 * class whose JNI lives in `libandroid_servers.so`), loaded the way
 * screen-mirroring clients do: a class loader over `SYSTEMSERVERCLASSPATH` plus
 * `Runtime.loadLibrary0`.
 */
internal class PanelPower(private val log: (String) -> Unit) {

    private companion object {
        const val POWER_MODE_OFF = 0
        const val POWER_MODE_NORMAL = 2
        const val DISPLAY_CONTROL = "com.android.server.display.DisplayControl"
    }

    private val displayControl: Class<*>? = loadDisplayControl()

    /** Last mode we applied, so the log only shows real transitions. */
    private var lastMode = -1

    private val setDisplayPowerMode: Method? = runCatching {
        Class.forName("android.view.SurfaceControl")
            .getMethod("setDisplayPowerMode", IBinder::class.java, Int::class.javaPrimitiveType)
    }.getOrNull()

    private val getPhysicalDisplayIds: Method? = runCatching {
        displayControl?.getMethod("getPhysicalDisplayIds")
    }.getOrNull()

    private val getPhysicalDisplayToken: Method? = runCatching {
        displayControl?.getMethod("getPhysicalDisplayToken", Long::class.javaPrimitiveType)
    }.getOrNull()

    val available: Boolean
        get() = setDisplayPowerMode != null && getPhysicalDisplayIds != null && getPhysicalDisplayToken != null

    /** @return true when every physical display accepted the mode. */
    fun setMode(mode: Int): Boolean {
        val set = setDisplayPowerMode
        val ids = runCatching { getPhysicalDisplayIds?.invoke(null) as? LongArray }.getOrNull()
        if (set == null || ids == null || ids.isEmpty()) return false
        var ok = true
        for (id in ids) {
            val token = runCatching {
                getPhysicalDisplayToken?.invoke(null, id) as? IBinder
            }.getOrNull()
            if (token == null) {
                ok = false
                continue
            }
            ok = runCatching { set.invoke(null, token, mode); true }.getOrDefault(false) && ok
        }
        if (ok && mode != lastMode) {
            lastMode = mode
            log("panel power mode -> ${if (mode == POWER_MODE_OFF) "OFF" else "NORMAL"} (${ids.size} physical display)")
        }
        return ok
    }

    fun panelOff(): Boolean = setMode(POWER_MODE_OFF)

    fun panelNormal(): Boolean = setMode(POWER_MODE_NORMAL)

    private fun loadDisplayControl(): Class<*>? = runCatching {
        val factory = Class.forName("com.android.internal.os.ClassLoaderFactory")
        val create = factory.methods.firstOrNull {
            it.name == "createClassLoader" &&
                it.parameterTypes.size == 7 &&
                it.parameterTypes[0] == String::class.java &&
                it.parameterTypes[3] == ClassLoader::class.java
        }
        if (create == null) {
            log("panel control: ClassLoaderFactory.createClassLoader unavailable")
            return null
        }
        val classpath = System.getenv("SYSTEMSERVERCLASSPATH")?.takeIf { it.isNotBlank() }
            ?: "/system/framework/services.jar"
        val loader = create.invoke(
            null,
            classpath,
            null,
            null,
            ClassLoader.getSystemClassLoader(),
            0,
            true,
            null,
        ) as ClassLoader
        val cls = loader.loadClass(DISPLAY_CONTROL)
        val loadLibrary0 = Runtime::class.java.getDeclaredMethod(
            "loadLibrary0",
            Class::class.java,
            String::class.java,
        )
        loadLibrary0.isAccessible = true
        loadLibrary0.invoke(Runtime.getRuntime(), cls, "android_servers")
        cls
    }.getOrNull()
}
