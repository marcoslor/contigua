package app.contigua.server

import android.media.MediaCodec

/**
 * What the platform encoder accepts, in the terms the Mac needs (ISS-39): the
 * alignment each axis takes, the maximum frame, and the largest pixel count it
 * encodes at 60 fps. The Mac asks for the window's exact pixels inside these,
 * so its frame is drawn one video pixel per screen pixel.
 *
 * `EncoderCapabilities` is the seam: `MediaCodecInfo.VideoCapabilities` cannot
 * be built in a JVM test, so the search below is proved against a fake.
 */
internal interface EncoderCapabilities {
    val maxWidth: Int
    val maxHeight: Int
    val widthAlignment: Int
    val heightAlignment: Int
    fun isSizeAndRateSupported(width: Int, height: Int, fps: Double): Boolean
}

internal data class EncoderReport(
    val widthAlign: Int,
    val heightAlign: Int,
    val maxWidth: Int,
    val maxHeight: Int,
    val maxPixelsAt60: Int,
) {
    /** The `welcome.device.encoder` object (docs/PROTOCOL.md). */
    fun wire(): Map<String, Any?> = mapOf(
        "widthAlign" to widthAlign,
        "heightAlign" to heightAlign,
        "maxWidth" to maxWidth,
        "maxHeight" to maxHeight,
        "maxPixels60" to maxPixelsAt60,
    )

    companion object {
        /** The stream codec whose encoder the report describes. */
        private const val MIME = "video/avc"
        const val FPS = 60.0

        /**
         * The report for [caps]. The 60 fps pixel count is the largest area the
         * codec takes, found by a binary search over the area with a square-ish
         * size inside the box: once per session, not per frame.
         */
        fun from(caps: EncoderCapabilities): EncoderReport {
            val box = caps.maxWidth.toLong() * caps.maxHeight.toLong()
            var low = 0L
            var high = maxOf(box, 0L)
            var best = 0L
            while (low <= high) {
                val middle = (low + high) / 2
                val size = candidate(caps, middle)
                if (size != null && caps.isSizeAndRateSupported(size.first, size.second, FPS)) {
                    best = size.first.toLong() * size.second.toLong()
                    low = middle + 1
                } else {
                    high = middle - 1
                }
            }
            return EncoderReport(
                widthAlign = maxOf(1, caps.widthAlignment),
                heightAlign = maxOf(1, caps.heightAlignment),
                maxWidth = caps.maxWidth,
                maxHeight = caps.maxHeight,
                maxPixelsAt60 = best.coerceIn(0L, Int.MAX_VALUE.toLong()).toInt(),
            )
        }

        /**
         * A size whose area is about [area], inside the box and aligned: the
         * box scaled by the same factor on both axes, so the search reaches the
         * full box (a square candidate could never fill a wide one).
         */
        private fun candidate(caps: EncoderCapabilities, area: Long): Pair<Int, Int>? {
            if (area <= 0) return null
            val widthAlign = maxOf(1, caps.widthAlignment)
            val heightAlign = maxOf(1, caps.heightAlignment)
            val box = caps.maxWidth.toDouble() * caps.maxHeight.toDouble()
            if (box <= 0) return null
            val scale = Math.sqrt(area.toDouble() / box)
            val width = alignDown(minOf(caps.maxWidth, (caps.maxWidth * scale).toInt()), widthAlign)
            val height = alignDown(minOf(caps.maxHeight, (caps.maxHeight * scale).toInt()), heightAlign)
            if (width <= 0 || height <= 0) return null
            return width to height
        }

        private fun alignDown(value: Int, align: Int): Int = (value / align) * align

        /**
         * The codec's report for this session's encoder type. nil when no
         * encoder can be probed; the Mac then keeps its 16 px / 2560 rule.
         */
        fun probe(): EncoderReport? {
            val codec = runCatching { MediaCodec.createEncoderByType(MIME) }.getOrNull()
                ?: return null
            return try {
                val caps = runCatching {
                    codec.codecInfo.getCapabilitiesForType(MIME).videoCapabilities
                }.getOrNull() ?: return null
                from(object : EncoderCapabilities {
                    override val maxWidth: Int = caps.supportedWidths.upper
                    override val maxHeight: Int = caps.supportedHeights.upper
                    override val widthAlignment: Int = caps.widthAlignment
                    override val heightAlignment: Int = caps.heightAlignment

                    override fun isSizeAndRateSupported(width: Int, height: Int, fps: Double): Boolean =
                        runCatching { caps.areSizeAndRateSupported(width, height, fps) }.getOrDefault(false)
                })
            } finally {
                runCatching { codec.release() }
            }
        }
    }
}
