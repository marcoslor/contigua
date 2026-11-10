package dev.pocketdeck.server

/**
 * Debug-only knobs for the still-screen rig (like [DebugFlags]). A release APK
 * never takes them: a test knob must not change what a person's phone does.
 */
internal object StreamDebug {

    /**
     * `debug.pocketdeck.ignore_repeat_frame=1`: configure the encoder without
     * `KEY_REPEAT_PREVIOUS_FRAME_AFTER`, the way some vendor encoders behave on
     * a still screen. The emulator rig reproduces the field bug with it.
     */
    const val IGNORE_REPEAT = "debug.pocketdeck.ignore_repeat_frame"

    /**
     * `debug.pocketdeck.freeze_drain=1`: the drain thread stops taking output,
     * as a stuck encoder would. The rig proves the Mac still says "Not
     * responding" for a real stall.
     */
    const val FREEZE_DRAIN = "debug.pocketdeck.freeze_drain"

    /** The pure rule; [property] is the raw system-property value (null when unset). */
    fun ignoreRepeatFrame(debug: Boolean, property: String?): Boolean = debug && property == "1"

    /** The live rule: a debug build with the property set right now. */
    fun ignoreRepeatFrame(): Boolean =
        dev.pocketdeck.BuildConfig.DEBUG && ignoreRepeatFrame(true, Hidden.systemProperty(IGNORE_REPEAT))

    fun freezeDrain(debug: Boolean, property: String?): Boolean = debug && property == "1"

    /** A release build never reads the property: the drain asks twice a second. */
    fun freezeDrain(): Boolean =
        dev.pocketdeck.BuildConfig.DEBUG && freezeDrain(true, Hidden.systemProperty(FREEZE_DRAIN))

    /**
     * `debug.pocketdeck.rate_control=0` (debug builds only): the early
     * delay-based signal never lowers the bitrate. Unset means on, so a debug
     * phone behaves like the product and the reviewer can A/B one half.
     */
    const val RATE_CONTROL = "debug.pocketdeck.rate_control"

    /**
     * `debug.pocketdeck.ladder=0` (debug builds only): the resolution/fps
     * ladder never steps; an active rung returns to the Mac's asked box.
     */
    const val LADDER = "debug.pocketdeck.ladder"

    /** A debug switch defaults ON; only the exact value "0" turns it off. */
    fun enabled(debug: Boolean, property: String?): Boolean = !debug || property != "0"

    fun rateControlEnabled(): Boolean =
        enabled(dev.pocketdeck.BuildConfig.DEBUG, Hidden.systemProperty(RATE_CONTROL))

    fun ladderEnabled(): Boolean =
        enabled(dev.pocketdeck.BuildConfig.DEBUG, Hidden.systemProperty(LADDER))
}
