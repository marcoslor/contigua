package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/**
 * `phone.ringer` (docs/design/controls.md): one shell command, no volume and no
 * other phone setting, and no write at all while Do Not Disturb is on.
 */
class RingerControlTest {

    private class FakeRinger(var mode: RingerMode? = RingerMode.NORMAL) : RingerSettings {
        var observed: ((RingerMode?) -> Unit)? = null
        override fun read(): RingerMode? = mode
        override fun listen(onChange: (RingerMode?) -> Unit): AutoCloseable? {
            observed = onChange
            return AutoCloseable { observed = null }
        }
    }

    private val writes = CopyOnWriteArrayList<RingerMode>()
    private val logs = CopyOnWriteArrayList<String>()

    private fun control(
        settings: FakeRinger,
        accept: Boolean = true,
        dnd: DndMode = DndMode.OFF,
    ) = RingerControl(
        settings,
        RingerSetter { mode ->
            writes.add(mode)
            if (accept) settings.mode = mode
            accept
        },
        { dnd },
        { logs.add(it) },
        pollIntervalMs = 0,
    )

    @Test
    fun `normal, vibrate and silent are written in order`() {
        val settings = FakeRinger()
        val control = control(settings)
        assertEquals(RingerControl.Result.SET, control.apply(RingerMode.VIBRATE))
        assertEquals(RingerControl.Result.SET, control.apply(RingerMode.SILENT))
        assertEquals(RingerControl.Result.SET, control.apply(RingerMode.NORMAL))
        assertEquals(listOf(RingerMode.VIBRATE, RingerMode.SILENT, RingerMode.NORMAL), writes.toList())
        assertEquals(RingerMode.NORMAL, settings.mode)
    }

    @Test
    fun `the mode already set is not written again`() {
        val settings = FakeRinger(RingerMode.SILENT)
        val control = control(settings)
        assertEquals(RingerControl.Result.SAME, control.apply(RingerMode.SILENT))
        assertTrue(writes.isEmpty())
    }

    @Test
    fun `a write while DND is on is refused and changes nothing`() {
        for (dnd in listOf(DndMode.PRIORITY, DndMode.ALARMS, DndMode.NONE)) {
            writes.clear()
            val settings = FakeRinger()
            val control = control(settings, dnd = dnd)
            assertEquals(RingerControl.Result.REFUSED_DND, control.apply(RingerMode.SILENT))
            assertTrue("wrote while $dnd", writes.isEmpty())
            assertEquals(RingerMode.NORMAL, settings.mode)
        }
    }

    @Test
    fun `an unreadable mode writes nothing`() {
        val settings = FakeRinger(null)
        val control = control(settings)
        assertEquals(RingerControl.Result.UNREADABLE, control.apply(RingerMode.SILENT))
        assertTrue(writes.isEmpty())
    }

    @Test
    fun `a refused write reports refused`() {
        val settings = FakeRinger()
        val control = control(settings, accept = false)
        assertEquals(RingerControl.Result.REFUSED, control.apply(RingerMode.SILENT))
        assertEquals(RingerMode.NORMAL, settings.mode)
    }

    @Test
    fun `wire names and android values map both ways`() {
        assertEquals(RingerMode.NORMAL, RingerMode.fromWire("normal"))
        assertEquals(RingerMode.VIBRATE, RingerMode.fromWire("vibrate"))
        assertEquals(RingerMode.SILENT, RingerMode.fromWire("silent"))
        for (mode in RingerMode.entries) {
            assertEquals(mode, RingerMode.fromAndroid(mode.android))
        }
        assertEquals(null, RingerMode.fromWire("loud"))
        assertEquals(null, RingerMode.fromAndroid(7))
    }
}
