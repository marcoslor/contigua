package dev.pocketdeck.server

import android.media.MediaCodecInfo
import android.media.MediaFormat

/**
 * Builds one encoder's [MediaFormat] from a [StreamStrategy]. The default
 * strategy sets exactly the keys and values the stream has always set: the
 * switch code lives here, behind one pure seam, so K1 can compare the default
 * format against the pre-switch one key by key.
 *
 * The codec's ability to honour a switch is passed in (not probed here), and a
 * refused switch leaves today's key in place.
 */
internal object StreamFormat {
    const val MIME = "video/avc"
    const val FPS = 60
    const val I_FRAME_INTERVAL_S = 10

    /** With intra refresh there is no periodic keyframe; keyframes only on request. */
    const val REFRESH_I_FRAME_INTERVAL_S = 3600

    /** `MediaFormat.KEY_MAX_FPS_TO_ENCODER`, kept as a string: some builds' encoders reject it. */
    const val KEY_MAX_FPS = "max-fps-to-encoder"

    /** How long a still encoder repeats its last frame, so the Mac sees a heartbeat. */
    const val REPEAT_PREVIOUS_FRAME_US = 500_000L

    data class Plan(val format: MediaFormat, val applied: StreamStrategy.Applied)

    fun build(
        w: Int,
        h: Int,
        bitrateBps: Int,
        strategy: StreamStrategy,
        cbrSupported: Boolean,
        intraRefreshSupported: Boolean,
        repeatPreviousFrame: Boolean,
        maxFps: Int?,
        encodingStatistics: Boolean,
    ): Plan {
        val format = MediaFormat.createVideoFormat(MIME, w, h)
        format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
        format.setInteger(MediaFormat.KEY_BIT_RATE, bitrateBps)
        format.setInteger(MediaFormat.KEY_FRAME_RATE, FPS)
        val refreshFrames = strategy.intraRefreshFrames
            .takeIf { it > 0 && intraRefreshSupported } ?: 0
        if (refreshFrames > 0) {
            format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, REFRESH_I_FRAME_INTERVAL_S)
            format.setInteger(MediaFormat.KEY_INTRA_REFRESH_PERIOD, refreshFrames)
        } else {
            format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, I_FRAME_INTERVAL_S)
        }
        if (repeatPreviousFrame) {
            runCatching { format.setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, REPEAT_PREVIOUS_FRAME_US) }
        }
        format.setInteger(MediaFormat.KEY_PRIORITY, 0) // realtime
        format.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
        val rateControl = if (strategy.rateControl == StreamStrategy.RateControl.Cbr && cbrSupported) {
            MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR
        } else {
            MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR
        }
        format.setInteger(MediaFormat.KEY_BITRATE_MODE, rateControl)
        runCatching { format.setInteger(MediaFormat.KEY_LATENCY, 1) }
        // Where the encoder supports the key it caps the frame rate itself;
        // where it does not, the drain loop drops frames above the cap.
        maxFps?.let { runCatching { format.setInteger(KEY_MAX_FPS, it) } }
        if (encodingStatistics) {
            runCatching {
                format.setInteger(
                    MediaFormat.KEY_VIDEO_ENCODING_STATISTICS_LEVEL,
                    MediaFormat.VIDEO_ENCODING_STATISTICS_LEVEL_1,
                )
            }
        }
        return Plan(
            format,
            StreamStrategy.Applied(
                rateControl = if (rateControl == MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR) {
                    StreamStrategy.RateControl.Cbr
                } else {
                    StreamStrategy.RateControl.Vbr
                },
                intraRefreshFrames = refreshFrames,
            ),
        )
    }
}
