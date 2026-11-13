package app.contigua.server

/**
 * The virtual-display flags an app window asks for (WIN-51, ISS-35).
 *
 * A window's display must not take the phone's top focus: Android's input
 * method serves only the top-focused display, so a display that takes it
 * leaves the phone's own screen without its keyboard for as long as the window
 * is open. `STEAL_TOP_FOCUS_DISABLED` keeps display 0 on top; the system
 * honours it only together with `OWN_FOCUS` on a trusted display, so all three
 * are one request.
 *
 * Pure (no Android imports): the values mirror DisplayManager's @hide
 * `VIRTUAL_DISPLAY_FLAG_*` constants, and the JVM test pins the whole set.
 */
internal object WindowDisplayFlags {

    const val PUBLIC = 1 shl 0
    const val PRESENTATION = 1 shl 1
    const val SECURE = 1 shl 2
    const val OWN_CONTENT_ONLY = 1 shl 3
    const val AUTO_MIRROR = 1 shl 4
    const val CAN_SHOW_WITH_INSECURE_KEYGUARD = 1 shl 5
    const val SUPPORTS_TOUCH = 1 shl 6
    const val ROTATES_WITH_CONTENT = 1 shl 7
    const val DESTROY_CONTENT_ON_REMOVAL = 1 shl 8
    const val SHOULD_SHOW_SYSTEM_DECORATIONS = 1 shl 9
    const val TRUSTED = 1 shl 10
    const val OWN_DISPLAY_GROUP = 1 shl 11
    const val ALWAYS_UNLOCKED = 1 shl 12
    const val TOUCH_FEEDBACK_DISABLED = 1 shl 13
    const val OWN_FOCUS = 1 shl 14
    const val DEVICE_DISPLAY_GROUP = 1 shl 15
    const val STEAL_TOP_FOCUS_DISABLED = 1 shl 16

    /**
     * The set a window asks for on [route] (WIN-74). Only the display-group
     * bits differ between routes: a virtual device's display joins the
     * device's own group through `DEVICE_DISPLAY_GROUP`, and asking for
     * `OWN_DISPLAY_GROUP` as well sends it back to the panel's group on One UI
     * (docs/research/lock-fade.md, option 1). A plain display earns its own
     * group with `OWN_DISPLAY_GROUP` where the platform honours it (AOSP).
     */
    fun requested(route: WindowRoute): Int {
        val group = when (route) {
            WindowRoute.DEVICE, WindowRoute.PLAIN_PANEL_GROUP -> DEVICE_DISPLAY_GROUP
            WindowRoute.PLAIN -> OWN_DISPLAY_GROUP
        }
        return PUBLIC or
            PRESENTATION or
            OWN_CONTENT_ONLY or
            SUPPORTS_TOUCH or
            ROTATES_WITH_CONTENT or
            DESTROY_CONTENT_ON_REMOVAL or
            TRUSTED or
            ALWAYS_UNLOCKED or
            TOUCH_FEEDBACK_DISABLED or
            OWN_FOCUS or
            STEAL_TOP_FOCUS_DISABLED or
            group
    }

    /** Names for the requested flags, so the server log shows what we asked for. */
    fun names(flags: Int): String {
        val set = ArrayList<String>()
        if (flags and PUBLIC != 0) set.add("PUBLIC")
        if (flags and PRESENTATION != 0) set.add("PRESENTATION")
        if (flags and SECURE != 0) set.add("SECURE")
        if (flags and AUTO_MIRROR != 0) set.add("AUTO_MIRROR")
        if (flags and OWN_CONTENT_ONLY != 0) set.add("OWN_CONTENT_ONLY")
        if (flags and CAN_SHOW_WITH_INSECURE_KEYGUARD != 0) set.add("CAN_SHOW_WITH_INSECURE_KEYGUARD")
        if (flags and SUPPORTS_TOUCH != 0) set.add("SUPPORTS_TOUCH")
        if (flags and ROTATES_WITH_CONTENT != 0) set.add("ROTATES_WITH_CONTENT")
        if (flags and DESTROY_CONTENT_ON_REMOVAL != 0) set.add("DESTROY_CONTENT_ON_REMOVAL")
        if (flags and SHOULD_SHOW_SYSTEM_DECORATIONS != 0) set.add("SHOULD_SHOW_SYSTEM_DECORATIONS")
        if (flags and TRUSTED != 0) set.add("TRUSTED")
        if (flags and OWN_DISPLAY_GROUP != 0) set.add("OWN_DISPLAY_GROUP")
        if (flags and ALWAYS_UNLOCKED != 0) set.add("ALWAYS_UNLOCKED")
        if (flags and TOUCH_FEEDBACK_DISABLED != 0) set.add("TOUCH_FEEDBACK_DISABLED")
        if (flags and OWN_FOCUS != 0) set.add("OWN_FOCUS")
        if (flags and DEVICE_DISPLAY_GROUP != 0) set.add("DEVICE_DISPLAY_GROUP")
        if (flags and STEAL_TOP_FOCUS_DISABLED != 0) set.add("STEAL_TOP_FOCUS_DISABLED")
        return set.joinToString("|")
    }
}

/** How an app window's display is made (docs/specs/app-windows.md WIN-74). */
internal enum class WindowRoute(val wire: String) {
    /** From Contigua's virtual device: the device's own display group. */
    DEVICE("device"),

    /** A plain virtual display with `OWN_DISPLAY_GROUP`: AOSP gives it a group. */
    PLAIN("plain"),

    /**
     * Debug only (`debug.contigua.vd_panel_group=1`): a plain display with the
     * device-group bit and no device, which lands in the panel's group 0 the
     * way One UI puts every plain display there. It proves the refusal.
     */
    PLAIN_PANEL_GROUP("plain-panel-group"),
}

/**
 * The one rule a window display must pass before anything launches on it
 * (WIN-74): a group of its own. The panel's group is 0 and an unreadable group
 * reads as 0 ([DisplayProbe.displayGroupId]), so both are refused; there is no
 * fallback that shares the panel's group.
 */
internal object WindowGroup {
    fun accepted(groupId: Int): Boolean = groupId > DisplayProbe.DEFAULT_GROUP_ID
}

/**
 * The display a window asked for sits in the panel's group (or its group could
 * not be read): it was released and nothing was launched. The session answers
 * `error {code: "windows_unsupported"}` for the stream.
 */
internal class WindowDisplayRefused(val route: WindowRoute, val groupId: Int) :
    IllegalStateException("window display refused: route=${route.wire} group=$groupId") {
    companion object {
        const val CODE = "windows_unsupported"
        const val MESSAGE = "this phone can't give app windows a display group of their own"
    }
}
