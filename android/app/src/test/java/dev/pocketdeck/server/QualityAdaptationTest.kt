package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The automatic bitrate policy: backpressure drops take 25% off down to a
 * floor (1 Mbps, or 85% of a goodput below it), recovery adds 10% every 5 s
 * without a drop, and neither ever crosses the target. A measured goodput caps
 * recovery; probes climb the cap back with doubling steps while the link stays
 * good, and a failed probe pauses for two minutes.
 */
class QualityAdaptationTest {

    private val q = QualityAdaptation()

    @Test
    fun `the stream starts at its target`() {
        assertEquals(7_000_000, q.setTarget(7_000_000))
        assertEquals(7_000_000, q.bitrate)
        assertEquals(7_000_000, q.targetBps)
    }

    @Test
    fun `a drop takes a quarter off`() {
        q.setTarget(4_000_000)
        assertEquals(3_000_000, q.onDrop(0))
        assertEquals(2_250_000, q.onDrop(10))
    }

    @Test
    fun `drops stop at the one megabit floor`() {
        q.setTarget(2_000_000)
        assertEquals(1_500_000, q.onDrop(0))
        assertEquals(1_125_000, q.onDrop(0))
        assertEquals(1_000_000, q.onDrop(0))
        assertNull("already at the floor", q.onDrop(0))
        assertEquals(1_000_000, q.bitrate)
    }

    @Test
    fun `recovery adds ten percent every five seconds`() {
        q.setTarget(4_000_000)
        q.onDrop(0)
        assertNull("too early", q.maybeRecover(4_999))
        assertEquals(3_300_000, q.maybeRecover(5_000))
        assertNull("one step per interval", q.maybeRecover(5_001))
        assertEquals(3_630_000, q.maybeRecover(10_000))
    }

    @Test
    fun `a new drop resets the recovery clock`() {
        q.setTarget(4_000_000)
        q.onDrop(0)
        q.onDrop(4_000) // second drop, clock restarts
        assertNull(q.maybeRecover(5_000))
        assertEquals((q.bitrate * 1.1).toInt(), q.maybeRecover(9_000))
    }

    @Test
    fun `a measured goodput caps the drop and its recovery`() {
        q.setTarget(8_000_000)
        assertEquals(2_550_000, q.onDrop(0, measuredBps = 3_000_000))
        assertEquals(2_550_000, q.ceilingBps)
        assertNull("already at the measured cap", q.maybeRecover(5_000))
        // The first call after the probe interval adds its 5% step, then the
        // normal +10% recovery reaches the new cap.
        assertEquals(2_677_500, q.maybeRecover(30_000))
        assertEquals(2_677_500, q.ceilingBps)
    }

    @Test
    fun `a later higher measurement raises the cap`() {
        q.setTarget(8_000_000)
        assertEquals(2_550_000, q.onDrop(0, measuredBps = 3_000_000))
        assertEquals(1_912_500, q.onDrop(1_000, measuredBps = 5_000_000))
        assertEquals(4_250_000, q.ceilingBps)
        assertEquals(2_103_750, q.maybeRecover(6_000))
    }

    @Test
    fun `a reconfigure at the same target keeps the measured cap`() {
        q.setTarget(8_000_000)
        q.onDrop(0, measuredBps = 3_000_000)
        assertEquals(2_550_000, q.bitrate)
        assertEquals(2_550_000, q.ceilingBps)
        // configure() repeats the target on every resize/open; it is not a new
        // stream and must not replay the drop from 8 Mbit/s.
        assertEquals(2_550_000, q.setTarget(8_000_000))
        assertEquals(2_550_000, q.ceilingBps)
        assertEquals(8_000_000, q.targetBps)
    }

    @Test
    fun `one drop on a healthy link does not lower the ceiling`() {
        q.setTarget(8_000_000)
        assertEquals(6_000_000, q.onDrop(0, measuredBps = 7_600_000))
        assertEquals("7.6 of 8 Mbit/s is a transient, not the link", 8_000_000, q.ceilingBps)
        assertEquals(6_600_000, q.maybeRecover(5_000))
        assertEquals(7_260_000, q.maybeRecover(10_000))
        assertEquals(7_986_000, q.maybeRecover(15_000))
        assertEquals(8_000_000, q.maybeRecover(20_000))
    }

    @Test
    fun `a near-target drop after a recovery row does not cap`() {
        q.setTarget(8_000_000)
        // One healthy-link drop, then a full recovery: the row is broken by the
        // non-drop windows, so a later near-target drop is not the second one.
        assertEquals(6_000_000, q.onDrop(0, measuredBps = 7_600_000))
        assertEquals(8_000_000, q.ceilingBps)
        q.maybeRecover(5_000)
        q.maybeRecover(10_000)
        q.maybeRecover(15_000)
        q.maybeRecover(20_000)
        assertEquals(8_000_000, q.bitrate)
        assertEquals(6_000_000, q.onDrop(25_000, measuredBps = 7_700_000))
        assertEquals(8_000_000, q.ceilingBps)
    }

    @Test
    fun `two measured drops in a row trust the measurement`() {
        q.setTarget(8_000_000)
        assertEquals(6_000_000, q.onDrop(0, measuredBps = 7_600_000))
        assertEquals(8_000_000, q.ceilingBps)
        assertEquals(4_500_000, q.onDrop(1_000, measuredBps = 7_600_000))
        assertEquals(6_460_000, q.ceilingBps)
    }

    @Test
    fun `a hard three megabit link keeps one failed probe per two minutes`() {
        val link = 3_000_000
        q.setTarget(8_000_000)
        // The link cannot carry the target: the first drop is the baseline,
        // not a probe, so the probe clock starts from it.
        q.onDrop(0, measuredBps = link)
        var now = 1_000L
        var lastProbeAt = Long.MIN_VALUE
        var lastFailureAt = Long.MIN_VALUE
        var failures = 0
        var minGap = Long.MAX_VALUE
        var maxBitrate = 0
        while (now <= 600_000) {
            val ceilingBefore = q.ceilingBps
            q.maybeRecover(now)
            if (q.ceilingBps > ceilingBefore) lastProbeAt = now
            val reached = q.bitrate
            maxBitrate = maxOf(maxBitrate, reached)
            if (reached > link) {
                q.onDrop(now, measuredBps = link)
                if (lastProbeAt != Long.MIN_VALUE && now - lastProbeAt <= 10_000) {
                    failures++
                    if (lastFailureAt != Long.MIN_VALUE) {
                        minGap = minOf(minGap, now - lastFailureAt)
                    }
                    lastFailureAt = now
                    lastProbeAt = Long.MIN_VALUE
                }
            }
            now += 1_000
        }
        assertTrue("failed probes over ten minutes: $failures", failures >= 2)
        assertTrue(
            "probe-induced drops ${minGap}ms apart",
            minGap == Long.MAX_VALUE || minGap >= 120_000,
        )
        assertTrue(
            "the bitrate reached ${maxBitrate / 1000} kbps on a ${link / 1000} kbps link",
            maxBitrate <= 3_300_000,
        )
    }

    @Test
    fun `a drop after a probe pauses probes for two minutes`() {
        q.setTarget(8_000_000)
        q.onDrop(0, measuredBps = 3_000_000)
        q.maybeRecover(30_000) // the first 5% probe after the interval
        assertEquals(2_677_500, q.ceilingBps)
        q.onDrop(31_000, measuredBps = 2_900_000)
        assertEquals(2_465_000, q.ceilingBps)
        q.maybeRecover(61_000)
        q.maybeRecover(91_000)
        q.maybeRecover(121_000)
        assertEquals("still inside the two-minute pause", 2_465_000, q.ceilingBps)
        q.maybeRecover(151_000) // 120 s after the drop: a fresh 5% step
        assertEquals(2_588_250, q.ceilingBps)
    }

    @Test
    fun `a link below the floor takes the bitrate to eighty five percent of it`() {
        q.setTarget(1_100_000)
        // 900 kbps is below the 1 Mbps floor: the floor follows the link, so
        // the belief may fall to 765 kbps instead of stopping at 1 Mbps.
        assertEquals(765_000, q.onDrop(0, measuredBps = 900_000))
        assertNull("the narrow-link floor holds", q.onDrop(1_000, measuredBps = 900_000))
        assertEquals(765_000, q.bitrate)
    }

    @Test
    fun `a new target resets the measured cap`() {
        q.setTarget(8_000_000)
        q.onDrop(0, measuredBps = 3_000_000)
        assertEquals(2_550_000, q.ceilingBps)
        assertEquals(6_000_000, q.setTarget(6_000_000))
        assertEquals(6_000_000, q.ceilingBps)
    }

    @Test
    fun `recovery never grows past the target`() {
        q.setTarget(1_100_000)
        q.onDrop(0) // -> 1_000_000, the floor
        assertEquals(1_100_000, q.maybeRecover(5_000))
        assertNull("at the target", q.maybeRecover(10_000))
    }

    @Test
    fun `no recovery while the target is already reached`() {
        q.setTarget(3_000_000)
        assertNull(q.maybeRecover(60_000))
    }

    @Test
    fun `an explicit target below the floor never drops`() {
        q.setTarget(800_000)
        assertNull(q.onDrop(0))
        assertEquals(800_000, q.bitrate)
    }

    @Test
    fun `a lower explicit target restarts the stream at it`() {
        q.setTarget(4_000_000)
        q.onDrop(0)
        assertEquals(1_000_000, q.setTarget(1_000_000))
        assertNull("the floor is the target now", q.onDrop(0))
    }
}
