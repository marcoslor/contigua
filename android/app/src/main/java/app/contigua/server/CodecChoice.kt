package app.contigua.server

/**
 * The one codec decision (WIN-59): HEVC is the default when the Mac says it
 * decodes HEVC in hardware and the phone's hardware HEVC encoder takes the
 * size; `codec=avc` forces H.264. The first failing condition becomes the
 * closed reason on the one fallback line.
 */
internal object CodecChoice {

    data class Choice(val codec: VideoCodec, val reason: String? = null) {
        /** The one line a fallback writes; nil when HEVC was chosen. */
        val fallbackLine: String?
            get() = reason?.let { "codec=hevc unsupported: $it" }
    }

    /** What the process knows about its HEVC encoder. */
    sealed interface Encoder {
        /** A hardware encoder exists; [supports] is its size check. */
        data class Available(val supports: (Int, Int) -> Boolean) : Encoder
        /** No hardware encoder, or one that already failed; [reason] is closed. */
        data class Unavailable(val reason: String) : Encoder
    }

    fun choose(
        arm: VideoCodec,
        macCodecs: Set<VideoCodec>,
        encoder: Encoder,
        size: IntSize,
    ): Choice {
        if (arm != VideoCodec.Hevc) return Choice(VideoCodec.Avc)
        if (VideoCodec.Hevc !in macCodecs) return Choice(VideoCodec.Avc, "mac")
        when (encoder) {
            is Encoder.Unavailable -> return Choice(VideoCodec.Avc, encoder.reason)
            is Encoder.Available ->
                if (!encoder.supports(size.w, size.h)) return Choice(VideoCodec.Avc, "size")
        }
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
