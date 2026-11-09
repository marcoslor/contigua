package dev.pocketdeck.server

import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * R2: a dip must not pin the codec key for the life of the window. With a
 * well-behaved encoder (gain 1, so the key equals the believed bitrate) the
 * outer loop owns the ceiling; the inner loop only follows the belief. On a
 * hard 3 Mbps dip the ceiling falls to 85% of it, and after the link recovers
 * the probes must climb back instead of holding at the dip's rate.
 */
class OverrunRecoveryTest {

    @Test
    fun `a ten second dip does not pin the codec key`() {
        val q = QualityAdaptation()
        val target = 30_000_000
        q.setTarget(target)
        var now = 0L
        while (now < 10_000) {
            q.maybeRecover(now)
            now += 1_000
        }
        val preDip = q.bitrate

        val dipEnd = now + 10_000
        var drops = 0
        while (now < dipEnd) {
            if (q.bitrate > 2_550_000) {
                if (q.onDrop(now, measuredBps = 3_000_000) != null) drops++
            }
            q.maybeRecover(now)
            now += 1_000
        }
        assertTrue("the 3 Mbps dip must drop at least once", drops > 0)

        // Five simulated minutes on the good link again.
        while (now < dipEnd + 300_000) {
            q.maybeRecover(now)
            now += 1_000
        }
        assertTrue(
            "the key was ${preDip / 1000} kbps before the dip and is " +
                "${q.bitrate / 1000} kbps five minutes after it",
            q.bitrate >= preDip * 9 / 10,
        )
    }
}
