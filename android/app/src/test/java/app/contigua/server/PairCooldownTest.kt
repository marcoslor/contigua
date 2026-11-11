package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Test

/** M-1: one denied/timed-out prompt silences new pairing requests for 30 s. */
class PairCooldownTest {

    @Test
    fun windowOpensOnStartAndClosesAfterThirtySeconds() {
        var ms = 1_000L
        val cooldown = PairCooldown(now = { ms })
        assertEquals(false, cooldown.active())
        cooldown.start()
        assertEquals(true, cooldown.active())
        ms += PairCooldown.WINDOW_MS - 1
        assertEquals(true, cooldown.active())
        ms += 1
        assertEquals(false, cooldown.active())
    }

    @Test
    fun aSecondDenialRestartsTheWindow() {
        var ms = 0L
        val cooldown = PairCooldown(now = { ms })
        cooldown.start()
        ms += 20_000
        cooldown.start()
        ms += 20_000
        assertEquals(true, cooldown.active())
        ms += 10_000
        assertEquals(false, cooldown.active())
    }
}
