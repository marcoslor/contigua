package dev.pocketdeck.server

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
     * The set a window asks for. [panelGroup] is the debug `VD_PANEL_GROUP`
     * knob: it swaps the display's own group for the panel's and changes those
     * two bits only.
     */
    fun requested(panelGroup: Boolean): Int {
        val group = if (panelGroup) DEVICE_DISPLAY_GROUP else OWN_DISPLAY_GROUP
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
