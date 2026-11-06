package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The automatic bitrate policy: backpressure drops take 25% off down to a
 * 1 Mbps floor, recovery adds 10% every 5 s without a drop, and neither ever
 * crosses the target.
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
        // 30 s later the 5% probe lifts the cap, then the normal +10% step.
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
