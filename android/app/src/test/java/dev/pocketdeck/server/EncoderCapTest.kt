package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The cap on the codec key: a drop measures the encoder's output against the
 * link's goodput, lowers the key by that ratio, and probes back up 5% at most
 * twice after 30 s without a drop.
 */
class EncoderCapTest {

    private val cap = EncoderCap()

    @Test
    fun `a drop lowers the key by the measured output ratio`() {
        // 16 Mbps key, 11.5 Mbps real output, 5 Mbps link: the key that would
        // have produced 85% of the link is 16 * 4.25 / 11.5.
        assertEquals(5_913_043, cap.onDrop(0, 5_000_000, 11_500_000, 16_000_000))
        assertEquals(5_913_043, cap.capBps)
    }

    @Test
    fun `an output that already fits leaves the cap alone`() {
        assertNull(cap.onDrop(0, 5_000_000, 4_000_000, 16_000_000))
        assertEquals(Int.MAX_VALUE, cap.capBps)
    }

    @Test
    fun `missing measurements leave the cap alone`() {
        assertNull(cap.onDrop(0, null, 11_500_000, 16_000_000))
        assertNull(cap.onDrop(0, 5_000_000, null, 16_000_000))
        assertNull(cap.onDrop(0, 0, 11_500_000, 16_000_000))
        assertEquals(Int.MAX_VALUE, cap.capBps)
    }

    @Test
    fun `the cap probes five percent after thirty seconds, twice`() {
        cap.onDrop(0, 5_000_000, 11_500_000, 16_000_000)
        assertNull("too early", cap.maybeProbe(29_999))
        assertEquals(6_208_695, cap.maybeProbe(30_000))
        assertEquals(6_519_129, cap.maybeProbe(60_000))
        assertNull("the probe budget is spent", cap.maybeProbe(90_000))
    }

    @Test
    fun `a drop after a probe holds the cap`() {
        cap.onDrop(0, 5_000_000, 11_500_000, 16_000_000)
        cap.maybeProbe(30_000)
        assertEquals(1, cap.probesLeft)
        // The probe found the link's limit: the next drop spends the rest of
        // the budget instead of starting another 30 s walk.
        cap.onDrop(31_000, 5_000_000, 11_500_000, 6_208_695)
        assertEquals(0, cap.probesLeft)
        assertNull(cap.maybeProbe(120_000))
    }

    @Test
    fun `a later higher measurement raises the cap`() {
        cap.onDrop(0, 3_000_000, 10_000_000, 8_000_000)
        assertEquals(2_040_000, cap.capBps)
        // The link improved; the same measured ratio now supports a higher key.
        assertEquals(5_828_571, cap.onDrop(5_000, 6_000_000, 7_000_000, 8_000_000))
    }

    @Test
    fun `the cap has a quarter megabit floor`() {
        assertEquals(250_000, cap.onDrop(0, 100_000, 1_000_000, 1_000_000))
    }

    @Test
    fun `a reset forgets the measured cap`() {
        cap.onDrop(0, 5_000_000, 11_500_000, 16_000_000)
        cap.reset()
        assertEquals(Int.MAX_VALUE, cap.capBps)
        assertEquals(2, cap.probesLeft)
        assertTrue(cap.maybeProbe(1_000_000) == null)
    }
}
