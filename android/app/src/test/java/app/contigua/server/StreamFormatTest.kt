package app.contigua.server

import android.media.MediaFormat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * WIN-61's encoder format: the default is the pre-switch format key for key,
 * an explicit fps reaches both the frame-rate and operating-rate keys, and low
 * latency is set only when the codec supports it.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class StreamFormatTest {

    @Test
    fun `the default has a 60 fps frame rate and no operating rate or low latency`() {
        val plan = build(StreamStrategy.DEFAULT)
        assertEquals(60, plan.format.getInteger(MediaFormat.KEY_FRAME_RATE))
        assertFalse(plan.format.containsKey(StreamFormat.KEY_OPERATING_RATE))
        assertFalse(plan.format.containsKey(StreamFormat.KEY_LOW_LATENCY))
        assertFalse(plan.applied.lowLatency)
    }

    @Test
    fun `fps 120 sets both rate keys to 120`() {
        val plan = build(parse("fps" to "120"))
        assertEquals(120, plan.format.getInteger(MediaFormat.KEY_FRAME_RATE))
        assertEquals(120, plan.format.getInteger(StreamFormat.KEY_OPERATING_RATE))
    }

    @Test
    fun `a supported low latency sets the key and is applied`() {
        val plan = build(parse("low_latency" to "on"), lowLatencySupported = true)
        assertEquals(1, plan.format.getInteger(StreamFormat.KEY_LOW_LATENCY))
        assertTrue(plan.applied.lowLatency)
    }

    @Test
    fun `an unsupported low latency leaves the key out and is not applied`() {
        val plan = build(parse("low_latency" to "on"), lowLatencySupported = false)
        assertFalse(plan.format.containsKey(StreamFormat.KEY_LOW_LATENCY))
        assertFalse(plan.applied.lowLatency)
    }

    @Test
    fun `low latency off adds nothing even when supported`() {
        val plan = build(StreamStrategy.DEFAULT, lowLatencySupported = true)
        assertFalse(plan.format.containsKey(StreamFormat.KEY_LOW_LATENCY))
        assertFalse(plan.applied.lowLatency)
    }

    @Test
    fun `fps and low latency leave the other keys alone`() {
        val plan = build(parse("fps" to "120", "low_latency" to "on"), lowLatencySupported = true)
        assertEquals(8_000_000, plan.format.getInteger(MediaFormat.KEY_BIT_RATE))
        assertEquals(10, plan.format.getInteger(MediaFormat.KEY_I_FRAME_INTERVAL))
        assertEquals(0, plan.format.getInteger(MediaFormat.KEY_PRIORITY))
        assertEquals(0, plan.format.getInteger(MediaFormat.KEY_MAX_B_FRAMES))
        assertFalse(plan.format.containsKey(StreamFormat.KEY_MAX_FPS))
    }

    private fun parse(vararg values: Pair<String, String>): StreamStrategy {
        val properties = values.toMap()
        return StreamStrategy.parse { key -> properties[key] }
    }

    private fun build(
        strategy: StreamStrategy,
        lowLatencySupported: Boolean = false,
    ): StreamFormat.Plan = StreamFormat.build(
        w = 1232,
        h = 2410,
        bitrateBps = strategy.bitrateFor(1232, 2410),
        strategy = strategy,
        cbrSupported = true,
        intraRefreshSupported = true,
        repeatPreviousFrame = true,
        maxFps = null,
        encodingStatistics = false,
        lowLatencySupported = lowLatencySupported,
    )
}
