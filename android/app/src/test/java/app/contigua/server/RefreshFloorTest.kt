package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The panel's refresh floor while app windows stream
 * (docs/specs/app-windows.md WIN-76): at most one token, at 60 Hz, released
 * once; a phone without the token streams on.
 */
class RefreshFloorTest {

    private class FakePlatform(var answer: Boolean = true, var acquireFails: Boolean = false, var releaseFails: Boolean = false) {
        val asked = mutableListOf<Int>()
        var released = 0

        fun acquire(hz: Int): (() -> Unit)? {
            asked += hz
            if (acquireFails) throw SecurityException("refused")
            if (!answer) return null
            return {
                released++
                if (releaseFails) throw IllegalStateException("gone")
            }
        }
    }

    @Test
    fun `WIN-76 a hold takes one token at 60 Hz`() {
        val platform = FakePlatform()
        val floor = RefreshFloor(platform::acquire)
        assertEquals("floor=60", floor.hold())
        assertEquals(listOf(60), platform.asked)
        assertTrue(floor.held)
    }

    @Test
    fun `WIN-76 a second hold takes no second token`() {
        val platform = FakePlatform()
        val floor = RefreshFloor(platform::acquire)
        floor.hold()
        assertEquals("floor=60", floor.hold())
        assertEquals(1, platform.asked.size)
    }

    @Test
    fun `WIN-76 a drop releases the token once`() {
        val platform = FakePlatform()
        val floor = RefreshFloor(platform::acquire)
        floor.hold()
        floor.drop()
        floor.drop()
        assertEquals(1, platform.released)
        assertFalse(floor.held)
    }

    @Test
    fun `WIN-76 a drop with nothing held releases nothing`() {
        val platform = FakePlatform()
        RefreshFloor(platform::acquire).drop()
        assertEquals(0, platform.released)
        assertTrue(platform.asked.isEmpty())
    }

    @Test
    fun `WIN-76 a phone without the token is floor none and streams on`() {
        val platform = FakePlatform(answer = false)
        val floor = RefreshFloor(platform::acquire)
        assertEquals("floor=none", floor.hold())
        assertFalse(floor.held)
        floor.drop()
        assertEquals(0, platform.released)
    }

    @Test
    fun `WIN-76 a failing call is floor none`() {
        val floor = RefreshFloor(FakePlatform(acquireFails = true)::acquire)
        assertEquals("floor=none", floor.hold())
        assertFalse(floor.held)
    }

    @Test
    fun `WIN-76 a failing release still drops the floor`() {
        val platform = FakePlatform(releaseFails = true)
        val floor = RefreshFloor(platform::acquire)
        floor.hold()
        floor.drop()
        assertFalse(floor.held)
        assertEquals(1, platform.released)
    }

    @Test
    fun `WIN-76 a hold after a drop takes a new token`() {
        val platform = FakePlatform()
        val floor = RefreshFloor(platform::acquire)
        floor.hold()
        floor.drop()
        assertEquals("floor=60", floor.hold())
        assertEquals(listOf(60, 60), platform.asked)
        assertTrue(floor.held)
    }
}
