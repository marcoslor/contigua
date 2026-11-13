package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The keep-alive step's rules (docs/specs/phone-app.md PHONE-12, PHONE-22):
 * app windows poke only their own displays, never display 0; the hold alone
 * pokes display 0, every 2 s.
 */
class KeepAliveTest {

    @Test
    fun `PHONE-22 a step names the window displays and never display 0`() {
        val targets = KeepAlive.targets(listOf(7, 8), holding = false)
        assertEquals(listOf(7, 8), targets)
        assertFalse(KeepAlive.PANEL_DISPLAY_ID in targets)
    }

    @Test
    fun `PHONE-22 display 0 in the window set is still never poked`() {
        assertEquals(listOf(7), KeepAlive.targets(listOf(0, 7), holding = false))
    }

    @Test
    fun `PHONE-12 the hold pokes display 0, with or without windows`() {
        assertEquals(listOf(0), KeepAlive.targets(emptyList(), holding = true))
        val both = KeepAlive.targets(listOf(7), holding = true)
        assertTrue(7 in both && 0 in both)
        assertEquals(2, both.size)
    }

    @Test
    fun `nothing open and no hold pokes nothing`() {
        assertEquals(emptyList<Int>(), KeepAlive.targets(emptyList(), holding = false))
    }

    @Test
    fun `PHONE-12 the hold runs every 2 s`() {
        assertEquals(2_000L, KeepAlive.intervalMs(holding = true, displayLocksHeld = false))
        assertEquals(2_000L, KeepAlive.intervalMs(holding = true, displayLocksHeld = true))
    }

    @Test
    fun `PHONE-22 the cadence with and without display locks`() {
        assertEquals(60_000L, KeepAlive.intervalMs(holding = false, displayLocksHeld = true))
        assertEquals(10_000L, KeepAlive.intervalMs(holding = false, displayLocksHeld = false))
    }
}
