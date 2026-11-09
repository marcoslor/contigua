package dev.pocketdeck.server

/**
 * Whether a codec is hardware backed. API 29 added the platform's own answer;
 * older releases know only the name, where the platform's software encoders
 * share these prefixes (the emulator's `c2.android.hevc.encoder` is one).
 */
internal object EncoderHardware {

    private val SOFTWARE_PREFIXES = listOf("OMX.google.", "c2.android.")

    fun isHardware(name: String, sdk: Int, hardwareAccelerated: Boolean?): Boolean =
        if (sdk >= 29) hardwareAccelerated == true
        else SOFTWARE_PREFIXES.none { name.startsWith(it) }
}
