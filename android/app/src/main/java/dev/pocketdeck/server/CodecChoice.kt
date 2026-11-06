package dev.pocketdeck.server

/**
 * The one codec decision (WIN-59): the arm asks, the Mac says it decodes HEVC
 * in hardware, and the phone's HEVC encoder takes the size. The first failing
 * condition becomes the closed reason on the one fallback line; anything else
 * is H.264.
 */
internal object CodecChoice {

    data class Choice(val codec: VideoCodec, val reason: String? = null) {
        /** The one line a fallback writes; nil when HEVC was chosen. */
        val fallbackLine: String?
            get() = reason?.let { "codec=hevc unsupported: $it" }
    }

    fun choose(
        arm: VideoCodec,
        macCodecs: Set<VideoCodec>,
        hevcEncoder: Boolean,
        sizeSupported: Boolean,
    ): Choice {
        if (arm != VideoCodec.Hevc) return Choice(VideoCodec.Avc)
        if (VideoCodec.Hevc !in macCodecs) return Choice(VideoCodec.Avc, "mac")
        if (!hevcEncoder) return Choice(VideoCodec.Avc, "encoder")
        if (!sizeSupported) return Choice(VideoCodec.Avc, "size")
        return Choice(VideoCodec.Hevc)
    }

    /**
     * The Mac's `hello.codecs` names: `"avc"` and `"hevc"`. A hello without the
     * list is an older Mac and means AVC only; an unknown name never adds one.
     */
    fun macCodecs(value: Any?): Set<VideoCodec> {
        val names = value as? List<*> ?: return setOf(VideoCodec.Avc)
        val parsed = names.mapNotNull { item ->
            (item as? String)?.trim()?.takeIf { it == VideoCodec.Hevc.token }?.let { VideoCodec.Hevc }
                ?: (item as? String)?.trim()?.takeIf { it == VideoCodec.Avc.token }?.let { VideoCodec.Avc }
        }.toSet()
        return if (parsed.isEmpty()) setOf(VideoCodec.Avc) else parsed
    }
}
