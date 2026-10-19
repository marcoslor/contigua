package dev.pocketdeck.server

/**
 * Debug-only knobs that change what the shell server accepts (review I-1).
 *
 * Auto-approve pairing stays off unless a debug build has the system property
 * set explicitly: a debug APK on the owner's phone must not pair any LAN peer
 * that completes TLS without the Allow prompt and the code. Both the server (a
 * new session) and the Home screen call this fresh, so a test or an
 * `adb shell setprop` takes effect immediately (never cached for the process).
 */
object DebugFlags {

    const val AUTO_APPROVE_PROP = "debug.pocketdeck.auto_approve"

    /** The pure rule; [property] is the raw system-property value (null when unset). */
    fun autoApprovePairing(debug: Boolean, property: String?): Boolean = debug && property == "1"

    /** The live rule: a debug build with the property set right now. */
    fun autoApprovePairing(): Boolean = autoApprovePairing(
        dev.pocketdeck.BuildConfig.DEBUG,
        Hidden.systemProperty(AUTO_APPROVE_PROP),
    )
}
