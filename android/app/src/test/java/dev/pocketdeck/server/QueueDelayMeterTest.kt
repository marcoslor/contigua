package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNull
import org.junit.Test

/** The early signal's measurement: a 500 ms p95 that goes null when writes stop. */
class QueueDelayMeterTest {

    private val meter = QueueDelayMeter()

    private fun fill(atUs: Long = 0, count: Int = 30, delayUs: Long = 1_000) {
        repeat(count) { i -> meter.note(1, atUs + i * 16_667L, delayUs) }
    }

    @Test
    fun `a stream without samples has no window`() {
        assertNull(meter.p95Us(1, 0))
        assertEquals(0, meter.sampleCount(1, 0))
    }

    @Test
    fun `too few samples is not a window`() {
        fill(count = QueueDelayMeter.MIN_SAMPLES - 1)
        assertNull(meter.p95Us(1, 400_000))
    }

    @Test
    fun `the window reports its p95`() {
        // 30 samples at 1 ms; the newest 10 carry 200 ms (a stalled link).
        for (i in 0 until 20) meter.note(1, i * 16_667L, 1_000)
        for (i in 20 until 30) meter.note(1, i * 16_667L, 200_000)
        assertEquals(200_000L, meter.p95Us(1, 330_000))
    }

    @Test
    fun `a below-threshold window stays below`() {
        fill(delayUs = 40_000)
        assertEquals(40_000L, meter.p95Us(1, 500_000))
    }

    @Test
    fun `samples older than the window are pruned`() {
        fill(atUs = 0)
        assertNull("all samples are older than the window", meter.p95Us(1, 3_000_000))
        assertEquals(0, meter.sampleCount(1, 3_000_000))
    }

    @Test
    fun `a stalled writer leaves no window instead of a calm one`() {
        fill(atUs = 0, count = 30)
        assertEquals(30, meter.sampleCount(1, 400_000))
        // Writes stopped: the next read is beyond the two-second window.
        assertNull(meter.p95Us(1, 3_000_000))
    }

    @Test
    fun `the deep run reports the link pace`() {
        // 30 KB over 0.48 s at 60 fps: the link carried about 0.5 Mbit/s.
        repeat(30) { i -> meter.note(1, i * 16_667L, 120_000, 1_000) }
        val rate = meter.deepRateBps(1, 30 * 16_667L)
        assertNotNull(rate)
        assertTrue("rate $rate", rate!! in 480_000..510_000)
    }

    @Test
    fun `a shallow newest sample is the app, not the link`() {
        repeat(30) { i -> meter.note(1, i * 16_667L, 120_000, 1_000) }
        meter.note(1, 30 * 16_667L, 5_000, 1_000)
        assertNull(meter.deepRateBps(1, 31 * 16_667L))
    }

    @Test
    fun `a stall starts a new deep run`() {
        repeat(15) { i -> meter.note(1, i * 16_667L, 120_000, 1_000) }
        repeat(20) { i -> meter.note(1, 433_000L + i * 16_667L, 120_000, 1_000) }
        val rate = meter.deepRateBps(1, 750_000L)
        assertNotNull(rate)
        assertTrue("a stalled span would read about 335 kbps, not $rate", rate!! > 400_000)
    }

    @Test
    fun `a short deep run says nothing`() {
        repeat(5) { i -> meter.note(1, i * 16_667L, 120_000, 1_000) }
        assertNull(meter.deepRateBps(1, 5 * 16_667L))
    }

    @Test
    fun `an app-limited stream has no deep run`() {
        repeat(30) { i -> meter.note(1, i * 16_667L, 5_000, 1_000) }
        assertNull(meter.deepRateBps(1, 30 * 16_667L))
    }

    @Test
    fun `a backwards clock starts a new window`() {
        fill(atUs = 1_000_000)
        meter.note(1, 500_000, 20_000)
        assertEquals(1, meter.sampleCount(1, 500_000))
    }

    @Test
    fun `a stalled clock sample is not a queue delay`() {
        fill(count = 30)
        meter.note(1, 300_000, QueueDelayMeter.MAX_DELAY_US + 1)
        assertEquals(30, meter.sampleCount(1, 490_000))
        meter.note(1, 310_000, -1)
        assertEquals(30, meter.sampleCount(1, 490_000))
    }

    @Test
    fun `each stream has its own window`() {
        repeat(30) { i -> meter.note(1, i * 16_667L, 20_000) }
        assertNull(meter.p95Us(2, 400_000))
        assertEquals(20_000L, meter.p95Us(1, 400_000))
    }

    @Test
    fun `a forgotten stream keeps no samples`() {
        fill()
        meter.forget(1)
        assertNull(meter.p95Us(1, 400_000))
    }
}
