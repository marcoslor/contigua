package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * P4's fallback measurement: the writer's dequeued bytes over the last
 * contiguous backlogged run are the TCP goodput proxy, per stream. An idle gap
 * starts a new run (a static 2 fps screen is not the link's rate), a sub-250 ms
 * run says nothing, and an idle stream's old samples are pruned as it is noted.
 */
class GoodputMeterTest {

    @Test
    fun `a steady writer gives its bit rate`() {
        val meter = GoodputMeter()
        for (i in 0 until 20) meter.note(1, 1_000, i * 100_000L)
        // 20 × 1000 bytes over 2 s (first at 0, asked at 2 s).
        assertEquals(80_000, meter.rateBps(1, 2_000_000L))
    }

    @Test
    fun `streams have their own windows`() {
        val meter = GoodputMeter()
        for (i in 0..2) {
            meter.note(1, 1_000, i * 100_000L)
            meter.note(2, 10_000, i * 100_000L)
        }
        assertEquals(80_000, meter.rateBps(1, 300_000L))
        assertEquals(800_000, meter.rateBps(2, 300_000L))
        assertNull(meter.rateBps(3, 300_000L))
    }

    @Test
    fun `a run shorter than a quarter second says nothing`() {
        val meter = GoodputMeter()
        meter.note(1, 1_000, 0)
        meter.note(1, 1_000, 100_000)
        meter.note(1, 1_000, 200_000)
        assertNull(meter.rateBps(1, 200_000))
        meter.note(1, 1_000, 250_000)
        assertEquals(128_000, meter.rateBps(1, 250_000))
    }

    @Test
    fun `two seconds idle then a 0_3 s burst measures the burst`() {
        val meter = GoodputMeter()
        // Static screen: two frames 2 s apart write almost nothing.
        meter.note(1, 500, 0)
        meter.note(1, 500, 1_500_000)
        // A scroll starts: four 10 KB frames in 300 ms.
        for (i in 0..3) meter.note(1, 10_000, 2_000_000L + i * 100_000L)
        // Only the burst counts; the idle gap is not the denominator.
        assertEquals(1_066_666, meter.rateBps(1, 2_300_000L))
    }

    @Test
    fun `a keyframe's bytes count in the run`() {
        val meter = GoodputMeter()
        meter.note(1, 1_000, 0)
        meter.note(1, 1_000, 100_000)
        meter.note(1, 1_000, 200_000)
        meter.note(1, 100_000, 300_000) // the keyframe after a drop
        // If keyframes were filtered, this would read 80_000.
        assertEquals(2_746_666, meter.rateBps(1, 300_000L))
    }

    @Test
    fun `old samples leave the window and do not leak while idle`() {
        val meter = GoodputMeter()
        for (i in 0 until 100) meter.note(1, 1_000, i * 100_000L)
        assertTrue("at most one 3 s window", meter.sampleCount(1) <= 31)
        // A long idle stream then one frame: the old run is gone, not averaged.
        meter.note(1, 1_000, 20_000_000L)
        assertEquals(1, meter.sampleCount(1))
        assertNull(meter.rateBps(1, 20_000_000L))
    }

    @Test
    fun `a stale run says nothing`() {
        val meter = GoodputMeter()
        meter.note(1, 1_000, 0)
        meter.note(1, 1_000, 100_000)
        meter.note(1, 1_000, 200_000)
        assertNull("the last sample is 300 ms old", meter.rateBps(1, 500_000L))
    }

    @Test
    fun `a backwards clock resets instead of inventing a rate`() {
        val meter = GoodputMeter()
        meter.note(1, 1_000, 10_000_000)
        meter.note(1, 1_000, 1_000_000)
        meter.note(1, 1_000, 1_100_000)
        meter.note(1, 1_000, 1_300_000)
        assertEquals("the old clock's samples are gone", 80_000, meter.rateBps(1, 1_300_000))
    }

    @Test
    fun `forget drops a closed stream`() {
        val meter = GoodputMeter()
        meter.note(1, 1_000, 0)
        meter.note(1, 1_000, 100_000)
        meter.forget(1)
        assertEquals(0, meter.sampleCount(1))
        assertNull(meter.rateBps(1, 100_000))
    }

    @Test
    fun `zero streams and zero bytes are ignored`() {
        val meter = GoodputMeter()
        meter.note(0, 1_000, 0)
        meter.note(1, 0, 0)
        assertNull(meter.rateBps(0, 1_000_000))
        assertNull(meter.rateBps(1, 1_000_000))
    }
}
