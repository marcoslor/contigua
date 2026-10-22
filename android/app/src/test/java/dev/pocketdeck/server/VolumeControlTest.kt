package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/** The clamp and the change plumbing behind `phone.volume`. */
class VolumeControlTest {

    private class FakeSettings(var level: Int?, var max: Int?) : VolumeSettings {
        var refuse = false
        var observed: (() -> Unit)? = null
        val written = CopyOnWriteArrayList<Int>()

        override fun read(): Pair<Int, Int>? {
            val l = level ?: return null
            val m = max ?: return null
            return if (m <= 0) null else l to m
        }

        override fun listen(onChange: () -> Unit): AutoCloseable? {
            observed = onChange
            return AutoCloseable { observed = null }
        }

        override fun set(level: Int): Boolean {
            if (refuse) return false
            written.add(level)
            this.level = level
            return true
        }
    }

    @Test
    fun `the level is clamped to zero and the maximum`() {
        val settings = FakeSettings(6, 15)
        val control = VolumeControl(settings, pollIntervalMs = 0)
        assertTrue(control.apply(99))
        assertTrue(control.apply(-3))
        assertTrue(control.apply(7))
        assertEquals(listOf(15, 0, 7), settings.written)
        assertEquals(7, control.current())
        assertEquals(15, control.max())
    }

    @Test
    fun `an unreadable stream writes nothing`() {
        val settings = FakeSettings(null, null)
        val control = VolumeControl(settings, pollIntervalMs = 0)
        assertFalse(control.apply(5))
        assertTrue(settings.written.isEmpty())
    }

    @Test
    fun `a refused write reports false`() {
        val settings = FakeSettings(6, 15).also { it.refuse = true }
        val control = VolumeControl(settings, pollIntervalMs = 0)
        assertFalse(control.apply(9))
        assertEquals(6, control.current())
    }

    @Test
    fun `a change is passed on once, not per repeated reading`() {
        val settings = FakeSettings(6, 15)
        val control = VolumeControl(settings, pollIntervalMs = 0)
        val seen = CopyOnWriteArrayList<Pair<Int, Int>>()
        val handle = control.start { level, max -> seen.add(level to max) }
        // The first read closes the start race; the caller's tracker drops it
        // when the pair is the one its state already carries.
        assertEquals(listOf(6 to 15), seen)
        settings.level = 9
        settings.observed?.invoke()
        assertEquals(listOf(6 to 15, 9 to 15), seen)
        settings.observed?.invoke()
        assertEquals(listOf(6 to 15, 9 to 15), seen)
        settings.level = 11
        settings.observed?.invoke()
        assertEquals(listOf(6 to 15, 9 to 15, 11 to 15), seen)
        handle.close()
    }

    @Test
    fun `the poll catches a change the phone never announced`() {
        val settings = FakeSettings(6, 15)
        val control = VolumeControl(settings, pollIntervalMs = 20)
        // No listener on this phone: only the poll can see the new level.
        settings.observed = null
        val seen = CopyOnWriteArrayList<Pair<Int, Int>>()
        val handle = control.start { level, max -> seen.add(level to max) }
        settings.level = 9
        val deadline = System.currentTimeMillis() + 2_000
        while (seen.none { it.first == 9 } && System.currentTimeMillis() < deadline) {
            Thread.sleep(10)
        }
        assertEquals(9 to 15, seen.lastOrNull())
        handle.close()
    }
}
