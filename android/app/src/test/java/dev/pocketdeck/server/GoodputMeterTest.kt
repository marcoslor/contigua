package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * P4's fallback measurement: the writer's dequeued bytes over the last 3 s are
 * the TCP goodput proxy, per stream; a sub-500 ms window and a clock jump say
 * nothing rather than inventing a cap.
 */
class GoodputMeterTest {

    @Test
    fun `a steady writer gives its bit rate`() {
        val meter = GoodputMeter()
        for (i in 0 until 20) meter.note(1, 1_000, i * 100_000L)
        // 20 × 1000 bytes over 1.9 s (first at 0, last at 1.9), asked at 2 s.
        assertEquals(80_000, meter.rateBps(1, 2_000_000L))
    }

    @Test
    fun `streams have their own windows`() {
        val meter = GoodputMeter()
        meter.note(1, 1_000, 0)
        meter.note(2, 10_000, 0)
        meter.note(1, 1_000, 1_000_000)
        meter.note(2, 10_000, 1_000_000)
        assertEquals(16_000, meter.rateBps(1, 1_000_000))
        assertEquals(160_000, meter.rateBps(2, 1_000_000))
        assertNull(meter.rateBps(3, 1_000_000))
    }

    @Test
    fun `less than half a second says nothing`() {
        val meter = GoodputMeter()
        meter.note(1, 1_000, 0)
        meter.note(1, 1_000, 400_000)
        assertNull(meter.rateBps(1, 499_999))
        assertEquals(32_000, meter.rateBps(1, 500_000))
    }

    @Test
    fun `old samples leave the window`() {
        val meter = GoodputMeter()
        meter.note(1, 1_000, 0)
        meter.note(1, 1_000, 4_000_000)
        assertNull("the 0 s sample was pruned, leaving no span", meter.rateBps(1, 4_000_000))
        meter.note(1, 1_000, 4_500_000)
        assertEquals(32_000, meter.rateBps(1, 4_500_000))
    }

    @Test
    fun `a backwards clock resets instead of inventing a rate`() {
        val meter = GoodputMeter()
        meter.note(1, 1_000, 10_000_000)
        meter.note(1, 1_000, 1_000_000)
        assertNull(meter.rateBps(1, 1_000_000))
        assertEquals("the old clock's sample is gone", 16_000, meter.rateBps(1, 1_500_000))
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
