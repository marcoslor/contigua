package dev.pocketdeck.server

import android.media.MediaCodecInfo
import android.media.MediaFormat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * ISS-40's switch set: every key parses into one value with today's defaults,
 * clamps out-of-range numbers and sends junk back to the default; the default
 * encoder format is byte-for-byte the one the stream had before the switches.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class StreamStrategyTest {

    private fun parse(vararg values: Pair<String, String?>): StreamStrategy {
        val properties = values.toMap()
        return StreamStrategy.parse { key -> properties[key] }
    }

    @Test
    fun `no properties give exactly today's values`() {
        val strategy = StreamStrategy.parse { null }
        assertEquals(StreamStrategy.DEFAULT, strategy)
        assertEquals(StreamStrategy.Overflow.Drop, strategy.overflow)
        assertEquals(250, strategy.queueMs)
        assertEquals(StreamStrategy.RateControl.Vbr, strategy.rateControl)
        assertEquals(8000, strategy.capKbps)
        assertEquals(120, strategy.bppMilli)
        assertEquals(0, strategy.intraRefreshFrames)
        assertFalse(strategy.refine)
        assertEquals(0, strategy.trafficClass)
        assertEquals(60, strategy.fps)
        assertEquals(0, strategy.vdRate)
        assertFalse(strategy.lowLatency)
        assertTrue(strategy.isDefault)
    }

    @Test
    fun `each key parses its non-default value`() {
        val strategy = parse(
            "overflow" to "suspend",
            "queue_ms" to "100",
            "rc" to "cbr",
            "cap_kbps" to "16000",
            "bpp_milli" to "180",
            "ir" to "60",
            "refine" to "on",
            "tos" to "136",
            "stall_ms" to "400",
            "stall_every_ms" to "3000",
        )
        assertEquals(StreamStrategy.Overflow.Suspend, strategy.overflow)
        assertEquals(100, strategy.queueMs)
        assertEquals(StreamStrategy.RateControl.Cbr, strategy.rateControl)
        assertEquals(16000, strategy.capKbps)
        assertEquals(180, strategy.bppMilli)
        assertEquals(60, strategy.intraRefreshFrames)
        assertTrue(strategy.refine)
        assertEquals(136, strategy.trafficClass)
        assertEquals(400, strategy.stallMs)
        assertEquals(3000, strategy.stallEveryMs)
        assertFalse(strategy.isDefault)
    }

    @Test
    fun `the stall is off by default and clamps to its documented ranges`() {
        assertEquals(0, StreamStrategy.DEFAULT.stallMs)
        assertEquals(5000, StreamStrategy.DEFAULT.stallEveryMs)
        assertEquals(50, parse("stall_ms" to "1").stallMs)
        assertEquals(2000, parse("stall_ms" to "9999").stallMs)
        assertEquals("0 is off, never clamped to 50", 0, parse("stall_ms" to "0").stallMs)
        assertEquals(1000, parse("stall_every_ms" to "1").stallEveryMs)
        assertEquals(30000, parse("stall_every_ms" to "99999").stallEveryMs)
        assertEquals(0, parse("stall_ms" to "soon").stallMs)
        assertEquals(5000, parse("stall_every_ms" to "soon").stallEveryMs)
    }

    @Test
    fun `numbers clamp to their documented range`() {
        assertEquals(30, parse("queue_ms" to "1").queueMs)
        assertEquals(1000, parse("queue_ms" to "5000").queueMs)
        assertEquals(1000, parse("cap_kbps" to "1").capKbps)
        assertEquals(100_000, parse("cap_kbps" to "999999").capKbps)
        assertEquals(50, parse("bpp_milli" to "0").bppMilli)
        assertEquals(500, parse("bpp_milli" to "900").bppMilli)
        assertEquals(10, parse("ir" to "1").intraRefreshFrames)
        assertEquals(600, parse("ir" to "9000").intraRefreshFrames)
        assertEquals(0, parse("ir" to "0").intraRefreshFrames)
        assertEquals(0, parse("tos" to "-1").trafficClass)
        assertEquals(255, parse("tos" to "999").trafficClass)
    }

    @Test
    fun `junk and unknown tokens fall back to today's value`() {
        val junk = parse(
            "overflow" to "sometimes",
            "queue_ms" to "soon",
            "rc" to "auto",
            "cap_kbps" to "lots",
            "bpp_milli" to "sharp",
            "ir" to "bands",
            "refine" to "maybe",
            "tos" to "fast",
        )
        assertEquals(StreamStrategy.DEFAULT, junk)
        assertEquals(0, parse("ir" to "-5").intraRefreshFrames)
    }

    @Test
    fun `quality off is a debug switch that disables adaptation`() {
        val strategy = parse("quality" to "off")
        assertFalse(strategy.quality)
        assertEquals("quality=off", strategy.describe())
    }

    @Test
    fun `the line says default with nothing set`() {
        assertEquals("default", StreamStrategy.DEFAULT.describe())
    }

    @Test
    fun `the line lists the active switches in a fixed order`() {
        val strategy = parse(
            "overflow" to "suspend",
            "queue_ms" to "100",
            "rc" to "cbr",
            "cap_kbps" to "16000",
            "bpp_milli" to "120",
            "ir" to "60",
            "refine" to "on",
            "tos" to "136",
            "stall_ms" to "400",
            "stall_every_ms" to "5000",
        )
        assertEquals(
            "rc=cbr cap_kbps=16000 ir=60 queue_ms=100 overflow=suspend refine=on tos=0x88 stall=400/5000",
            strategy.describe(
                StreamStrategy.Applied(
                    rateControl = StreamStrategy.RateControl.Cbr,
                    intraRefreshFrames = 60,
                ),
            ),
        )
    }

    @Test
    fun `a switch the codec refuses names its fallback`() {
        val strategy = parse("rc" to "cbr", "ir" to "60")
        assertEquals(
            "rc=cbr unsupported ir=60 unsupported",
            strategy.describe(StreamStrategy.Applied()),
        )
        assertEquals(
            "rc=cbr ir=60",
            strategy.describe(
                StreamStrategy.Applied(
                    rateControl = StreamStrategy.RateControl.Cbr,
                    intraRefreshFrames = 60,
                ),
            ),
        )
    }

    @Test
    fun `fps, vd_rate and low_latency parse their values`() {
        val strategy = parse("fps" to "120", "vd_rate" to "90", "low_latency" to "on")
        assertEquals(120, strategy.fps)
        assertEquals(90, strategy.vdRate)
        assertTrue(strategy.lowLatency)
        assertFalse(strategy.isDefault)
        assertEquals(60, parse("fps" to "60", "vd_rate" to "0", "low_latency" to "off").fps)
        assertEquals(0, parse("low_latency" to "off").vdRate)
        assertFalse(parse("low_latency" to "maybe").lowLatency)
    }

    @Test
    fun `fps clamps to 30-120 and junk is 60`() {
        assertEquals(30, parse("fps" to "29").fps)
        assertEquals(30, parse("fps" to "1").fps)
        assertEquals(120, parse("fps" to "200").fps)
        assertEquals(60, parse("fps" to "soon").fps)
        assertEquals(30, parse("fps" to "-1").fps)
    }

    @Test
    fun `the overrun overshoot is off by default and clamps to 1-32`() {
        assertEquals(1, StreamStrategy.DEFAULT.overshoot)
        assertEquals(3, parse("overshoot" to "3").overshoot)
        assertEquals(32, parse("overshoot" to "999").overshoot)
        assertEquals(1, parse("overshoot" to "0").overshoot)
        assertEquals(1, parse("overshoot" to "soon").overshoot)
        assertEquals("overshoot=3", parse("overshoot" to "3").describe())
        assertEquals("default", parse("overshoot" to "1").describe())
    }

    @Test
    fun `vd_rate is off at 0 or junk and clamps to 60-120`() {
        assertEquals(0, parse("vd_rate" to "0").vdRate)
        assertEquals(0, parse("vd_rate" to "soon").vdRate)
        assertEquals(0, parse("vd_rate" to "-1").vdRate)
        assertEquals(60, parse("vd_rate" to "30").vdRate)
        assertEquals(60, parse("vd_rate" to "60").vdRate)
        assertEquals(90, parse("vd_rate" to "90").vdRate)
        assertEquals(120, parse("vd_rate" to "120").vdRate)
        assertEquals(120, parse("vd_rate" to "200").vdRate)
    }

    @Test
    fun `fps, vd_rate and low_latency print in their fixed order`() {
        val strategy = parse(
            "fps" to "120",
            "vd_rate" to "90",
            "low_latency" to "on",
            "queue_ms" to "100",
        )
        assertEquals(
            "fps=120 vd_rate=90 low_latency=on queue_ms=100",
            strategy.describe(
                StreamStrategy.Applied(vdRate = true, lowLatency = true),
            ),
        )
    }

    @Test
    fun `a vd_rate or low_latency the codec refuses names its fallback`() {
        val strategy = parse("vd_rate" to "90", "low_latency" to "on")
        assertEquals(
            "vd_rate=90 unsupported low_latency=on unsupported",
            strategy.describe(StreamStrategy.Applied()),
        )
        assertEquals(
            "default",
            parse("fps" to "60", "vd_rate" to "0", "low_latency" to "off").describe(),
        )
    }

    @Test
    fun `the codec key parses, clamps and prints`() {
        assertEquals(VideoCodec.Hevc, StreamStrategy.DEFAULT.codec)
        assertEquals(VideoCodec.Hevc, parse("codec" to "hevc").codec)
        assertEquals(VideoCodec.Avc, parse("codec" to "avc").codec)
        assertEquals("junk is the default, never a guess", VideoCodec.Hevc,
                     parse("codec" to "h265").codec)
        // The line prints what differs from the default: only a forced AVC.
        assertEquals("codec=avc",
                     parse("codec" to "avc").describe(StreamStrategy.Applied(codec = VideoCodec.Avc)))
        assertEquals("default",
                     parse("codec" to "hevc").describe(StreamStrategy.Applied(codec = VideoCodec.Hevc)))
        // A requested HEVC the MAC or the encoder refused has its own reason
        // line; the strategy line stays at the default.
        assertEquals("default",
                     parse("codec" to "hevc").describe(StreamStrategy.Applied(codec = VideoCodec.Avc)))
    }

    @Test
    fun `the hevc format names its own mime`() {
        val plan = build(format = parse("codec" to "hevc"), cbrSupported = true,
                         intraRefreshSupported = true, codec = VideoCodec.Hevc)
        assertEquals(VideoCodec.Hevc.mime, plan.format.getString(MediaFormat.KEY_MIME))
        assertEquals(VideoCodec.Hevc, plan.applied.codec)
        assertEquals(VideoCodec.Avc.mime,
                     build(StreamStrategy.DEFAULT, true, true).format.getString(MediaFormat.KEY_MIME))
    }

    @Test
    fun `the default format is exactly the pre-switch format`() {
        val plan = build(format = StreamStrategy.DEFAULT, cbrSupported = true, intraRefreshSupported = true)
        val format = plan.format
        assertEquals(MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
                     format.getInteger(MediaFormat.KEY_COLOR_FORMAT))
        assertEquals(8_000_000, format.getInteger(MediaFormat.KEY_BIT_RATE))
        assertEquals(60, format.getInteger(MediaFormat.KEY_FRAME_RATE))
        assertEquals(10, format.getInteger(MediaFormat.KEY_I_FRAME_INTERVAL))
        assertEquals(500_000L, format.getLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER))
        assertEquals(0, format.getInteger(MediaFormat.KEY_PRIORITY))
        assertEquals(0, format.getInteger(MediaFormat.KEY_MAX_B_FRAMES))
        assertEquals(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR,
                     format.getInteger(MediaFormat.KEY_BITRATE_MODE))
        assertEquals(1, format.getInteger(MediaFormat.KEY_LATENCY))
        // No switch may add a key the pre-switch format did not have.
        assertFalse(format.containsKey(MediaFormat.KEY_INTRA_REFRESH_PERIOD))
        assertFalse(format.containsKey(StreamFormat.KEY_MAX_FPS))
        assertFalse(format.containsKey(MediaFormat.KEY_VIDEO_ENCODING_STATISTICS_LEVEL))
        assertEquals(StreamStrategy.Applied(), plan.applied)
    }

    @Test
    fun `cbr and intra refresh reach the format when the codec supports them`() {
        val strategy = parse("rc" to "cbr", "ir" to "60")
        val plan = build(strategy, cbrSupported = true, intraRefreshSupported = true)
        assertEquals(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR,
                     plan.format.getInteger(MediaFormat.KEY_BITRATE_MODE))
        assertEquals(60, plan.format.getInteger(MediaFormat.KEY_INTRA_REFRESH_PERIOD))
        assertEquals(3600, plan.format.getInteger(MediaFormat.KEY_I_FRAME_INTERVAL))
        assertEquals(StreamStrategy.RateControl.Cbr, plan.applied.rateControl)
        assertEquals(60, plan.applied.intraRefreshFrames)
    }

    @Test
    fun `an unhonoured cbr or ir keeps today's format`() {
        val strategy = parse("rc" to "cbr", "ir" to "60")
        val plan = build(strategy, cbrSupported = false, intraRefreshSupported = false)
        assertEquals(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR,
                     plan.format.getInteger(MediaFormat.KEY_BITRATE_MODE))
        assertEquals(10, plan.format.getInteger(MediaFormat.KEY_I_FRAME_INTERVAL))
        assertFalse(plan.format.containsKey(MediaFormat.KEY_INTRA_REFRESH_PERIOD))
        assertEquals(StreamStrategy.Applied(), plan.applied)
    }

    @Test
    fun `the default bitrate is today's formula for every size`() {
        val strategy = StreamStrategy.DEFAULT
        assertEquals(500_000, strategy.bitrateFor(160, 120))         // under the floor
        assertEquals(2_764_800, strategy.bitrateFor(800, 480))        // 800·480·7.2
        assertEquals(8_000_000, strategy.bitrateFor(1232, 2410))      // over the cap
    }

    @Test
    fun `the bitrate follows bpp and the cap`() {
        assertEquals(4_147_200, parse("bpp_milli" to "180").bitrateFor(800, 480))
        assertEquals(16_000_000, parse("cap_kbps" to "16000").bitrateFor(1232, 2410))
        assertEquals(25_000_000, parse("cap_kbps" to "25000", "bpp_milli" to "300").bitrateFor(1232, 2410))
    }

    @Test
    fun `the queue budget scales with queue_ms`() {
        assertEquals(256 * 1024, StreamStrategy.DEFAULT.queueBytes())
        assertEquals(256 * 1024 * 100 / 250, parse("queue_ms" to "100").queueBytes())
        assertEquals(250_000L, StreamStrategy.DEFAULT.queueDurationUs())
        assertEquals(100_000L, parse("queue_ms" to "100").queueDurationUs())
    }

    private fun build(
        format: StreamStrategy,
        cbrSupported: Boolean,
        intraRefreshSupported: Boolean,
        codec: VideoCodec = VideoCodec.Avc,
    ): StreamFormat.Plan = StreamFormat.build(
        w = 1232,
        h = 2410,
        bitrateBps = format.bitrateFor(1232, 2410),
        strategy = format,
        cbrSupported = cbrSupported,
        intraRefreshSupported = intraRefreshSupported,
        repeatPreviousFrame = true,
        maxFps = null,
        encodingStatistics = false,
        codec = codec,
    )
}
