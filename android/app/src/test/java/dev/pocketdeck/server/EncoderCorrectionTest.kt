package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * R1's inner loop: the codec key follows the sender's believed bitrate through
 * the encoder's measured gain. A steady overshoot settles in a few seconds, a
 * static screen walks the key back up without jumping past the uncorrected key,
 * and a reset forgets the measurement.
 */
class EncoderCorrectionTest {

    private val believed = 8_000_000

    @Test
    fun `a steady three times overshoot settles within five seconds`() {
        val correction = EncoderCorrection()
        var now = 0L
        var key = correction.keyFor(now, believed, believed)
        repeat(5) {
            now += 1_000
            val output = key * 3
            assertTrue("a sample must land at ${now}ms", correction.sample(now, output, key))
            key = correction.keyFor(now, believed, believed)
            assertTrue("the key ${key / 1000} kbps went above the uncorrected key", key <= believed)
        }
        val output = key * 3
        val error = kotlin.math.abs(output - believed).toDouble() / believed
        assertTrue("key ${key / 1000} kbps, output ${output / 1000} kbps, " +
            "believed ${believed / 1000} kbps: error $error", error <= 0.15)
        assertEquals(EncoderCorrection.State.Tracking, correction.state)
    }

    @Test
    fun `a static screen walks the key back up but never above the uncorrected key`() {
        val correction = EncoderCorrection()
        var now = 0L
        var key = correction.keyFor(now, believed, believed)
        now += 1_000
        correction.sample(now, key * 3, key)
        key = correction.keyFor(now, believed, believed)
        assertEquals(2_666_666, key)

        var previous = key
        repeat(60) {
            now += 1_000
            assertTrue("the static sample must land", correction.sample(now, 80_000, key))
            key = correction.keyFor(now, believed, believed)
            assertTrue("the key $key went above the uncorrected key", key <= believed)
            assertTrue(
                "the key grew from $previous to $key in one second, more than 10%",
                key <= previous + previous / 10 + 1,
            )
            previous = key
        }
        assertEquals("the static screen walked all the way back", believed, key)
    }

    @Test
    fun `the key never goes below a quarter megabit`() {
        val correction = EncoderCorrection()
        var key = correction.keyFor(0, believed, believed)
        correction.sample(1_000, believed * 3, key)
        key = correction.keyFor(1_000, 500_000, believed)
        assertEquals(250_000, key)
    }

    @Test
    fun `a reset forgets the measured gain`() {
        val correction = EncoderCorrection()
        var key = correction.keyFor(0, believed, believed)
        correction.sample(1_000, believed * 3, key)
        key = correction.keyFor(1_000, believed, believed)
        assertEquals(2_666_666, key)
        assertEquals(EncoderCorrection.State.Settling, correction.state)
        correction.reset()
        assertEquals(EncoderCorrection.State.Unmeasured, correction.state)
        assertEquals(believed, correction.keyFor(2_000, believed, believed))
    }

    @Test
    fun `a sample while the key is still settling is ignored`() {
        val correction = EncoderCorrection()
        var key = correction.keyFor(0, believed, believed)
        correction.sample(1_000, believed * 3, key)
        key = correction.keyFor(1_000, believed, believed)
        assertEquals(2_666_666, key)
        // The key only ran for half a second: its output says nothing yet.
        assertTrue(!correction.sample(1_500, believed * 4, key))
        assertEquals(3.0, correction.gain, 0.0001)
    }
}
