package app.contigua.server

import android.view.Display
import java.lang.reflect.Field
import java.lang.reflect.Method

/**
 * Read-only view of the hidden per-display state.
 *
 * `DisplayInfo` is the one place that carries both a display's own flags and its
 * `displayGroupId`, which is what says whether a virtual display got its own
 * display group or ended up in the panel's (group 0) — the same fields
 * `dumpsys display` prints. Every lookup is reflective and resolved once.
 */
internal object DisplayProbe {

    /** `Display.DEFAULT_DISPLAY_GROUP` — the panel's group on every phone. */
    const val DEFAULT_GROUP_ID = 0

    // @hide Display flags (android.view.Display), verified against AOSP 14-16.
    const val FLAG_TRUSTED = 1 shl 7
    const val FLAG_OWN_DISPLAY_GROUP = 1 shl 8
    const val FLAG_ALWAYS_UNLOCKED = 1 shl 9
    const val FLAG_TOUCH_FEEDBACK_DISABLED = 1 shl 10
    const val FLAG_OWN_FOCUS = 1 shl 11

    private val global: Any? = runCatching {
        Class.forName("android.hardware.display.DisplayManagerGlobal")
            .getMethod("getInstance")
            .invoke(null)
    }.getOrNull()

    private val getDisplayInfo: Method? = runCatching {
        global?.javaClass?.getMethod("getDisplayInfo", Int::class.javaPrimitiveType)
    }.getOrNull()

    private val infoClass: Class<*>? = runCatching {
        Class.forName("android.view.DisplayInfo")
    }.getOrNull()

    private val flagsField: Field? = field("flags")
    private val groupField: Field? = field("displayGroupId")
    private val stateField: Field? = field("state")

    private fun field(name: String): Field? = runCatching { infoClass?.getField(name) }.getOrNull()

    private fun info(displayId: Int): Any? =
        runCatching { getDisplayInfo?.invoke(global, displayId) }.getOrNull()

    fun flags(displayId: Int): Int = read(displayId, flagsField, 0)

    /** The display's group; [DEFAULT_GROUP_ID] is the panel's group. */
    fun displayGroupId(displayId: Int): Int = read(displayId, groupField, DEFAULT_GROUP_ID)

    /** A `Display.STATE_*` value. */
    fun state(displayId: Int): Int = read(displayId, stateField, Display.STATE_UNKNOWN)

    private fun read(displayId: Int, field: Field?, fallback: Int): Int =
        (info(displayId)?.let { runCatching { field?.get(it) }.getOrNull() } as? Int) ?: fallback

    /** `display 57: group=1 state=ON flags=0x140 (OWN_DISPLAY_GROUP|ALWAYS_UNLOCKED)` */
    fun describe(displayId: Int): String {
        if (info(displayId) == null) return "display $displayId: info unavailable"
        val f = flags(displayId)
        return "display $displayId: group=${displayGroupId(displayId)} " +
            "state=${stateName(state(displayId))} flags=0x${f.toString(16)} (${flagNames(f)})"
    }

    fun stateName(state: Int): String = when (state) {
        Display.STATE_OFF -> "OFF"
        Display.STATE_ON -> "ON"
        Display.STATE_DOZE -> "DOZE"
        Display.STATE_DOZE_SUSPEND -> "DOZE_SUSPEND"
        Display.STATE_VR -> "VR"
        Display.STATE_ON_SUSPEND -> "ON_SUSPEND"
        else -> "UNKNOWN"
    }

    private fun flagNames(flags: Int): String {
        val set = ArrayList<String>()
        if (flags and FLAG_TRUSTED != 0) set.add("TRUSTED")
        if (flags and FLAG_OWN_DISPLAY_GROUP != 0) set.add("OWN_DISPLAY_GROUP")
        if (flags and FLAG_ALWAYS_UNLOCKED != 0) set.add("ALWAYS_UNLOCKED")
        if (flags and FLAG_TOUCH_FEEDBACK_DISABLED != 0) set.add("TOUCH_FEEDBACK_DISABLED")
        if (flags and FLAG_OWN_FOCUS != 0) set.add("OWN_FOCUS")
        return if (set.isEmpty()) "none" else set.joinToString("|")
    }

    /** The display's current logical size (rotation applied), or null when unknown. */
    fun logicalSize(displayId: Int): IntSize? = runCatching {
        val info = getDisplayInfo?.invoke(global, displayId) ?: return null
        val c = info.javaClass
        IntSize(c.getField("logicalWidth").getInt(info), c.getField("logicalHeight").getInt(info))
    }.getOrNull()?.takeIf { it.w > 0 && it.h > 0 }
}
