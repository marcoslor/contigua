package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The restore rule (docs/design/focus.md): only a DND Contigua turned on is
 * turned off, only while the phone is still in that mode, and a reconnect does
 * not claim or re-apply a mode twice.
 */
class ZenControlTest {

    private class FakeZen(var mode: DndMode = DndMode.OFF) : ZenSettings {
        val writes = CopyOnWriteArrayList<DndMode>()
        var observed: ((DndMode?) -> Unit)? = null
        var accept = true

        override fun read(): DndMode? = mode

        override fun listen(onChange: (DndMode?) -> Unit): AutoCloseable? {
            observed = onChange
            return AutoCloseable { observed = null }
        }

        /** The person changes the mode on the phone. */
        fun personSets(next: DndMode) {
            mode = next
            observed?.invoke(next)
        }
    }

    private lateinit var zen: FakeZen
    private lateinit var control: ZenControl
    private val logs = CopyOnWriteArrayList<String>()

    private fun setUp(initial: DndMode = DndMode.OFF) {
        zen = FakeZen(initial)
        val setter = ZenSetter { mode ->
            if (!zen.accept) return@ZenSetter false
            zen.writes.add(mode)
            zen.mode = mode
            true
        }
        control = ZenControl(zen, setter, { logs.add(it) }, pollIntervalMs = 0)
        // A session would start the observer; the fake then delivers the
        // person's changes like the platform does.
        control.start { }
    }

    @Test
    fun `mac set then focus ends turns DND off`() {
        setUp()
        assertTrue(control.apply(DndMode.PRIORITY))
        assertEquals(DndMode.PRIORITY, zen.mode)
        assertEquals(DndMode.PRIORITY, control.setByMac)
        assertTrue(control.apply(DndMode.OFF))
        assertEquals(DndMode.OFF, zen.mode)
        assertNull(control.setByMac)
        assertEquals(listOf(DndMode.PRIORITY, DndMode.OFF), zen.writes.toList())
    }

    @Test
    fun `a mac DND moves to another level and still turns off when the focus ends`() {
        setUp()
        assertTrue(control.apply(DndMode.PRIORITY))
        assertTrue(control.apply(DndMode.ALARMS))
        assertEquals(DndMode.ALARMS, zen.mode)
        assertEquals(DndMode.ALARMS, control.setByMac)
        assertTrue(control.apply(DndMode.OFF))
        assertEquals(DndMode.OFF, zen.mode)
        assertEquals(listOf(DndMode.PRIORITY, DndMode.ALARMS, DndMode.OFF), zen.writes.toList())
    }

    @Test
    fun `a person's DND is not moved to another level`() {
        setUp(DndMode.PRIORITY)
        assertFalse(control.apply(DndMode.ALARMS))
        assertEquals(DndMode.PRIORITY, zen.mode)
        assertTrue(zen.writes.isEmpty())
    }

    @Test
    fun `alarms and nothing map through the same rule`() {
        setUp()
        assertTrue(control.apply(DndMode.ALARMS))
        assertEquals(DndMode.ALARMS, zen.mode)
        assertTrue(control.apply(DndMode.OFF))
        assertEquals(DndMode.OFF, zen.mode)

        assertTrue(control.apply(DndMode.NONE))
        assertEquals(DndMode.NONE, zen.mode)
        assertTrue(control.apply(DndMode.OFF))
        assertEquals(DndMode.OFF, zen.mode)
    }

    @Test
    fun `a mode the person changed is left alone`() {
        setUp()
        assertTrue(control.apply(DndMode.PRIORITY))
        zen.personSets(DndMode.ALARMS)
        assertNull(control.setByMac)
        assertFalse(control.apply(DndMode.OFF))
        assertEquals(DndMode.ALARMS, zen.mode)
        // Only the one set; the focus end never sent off.
        assertEquals(listOf(DndMode.PRIORITY), zen.writes.toList())
    }

    @Test
    fun `a change the observer missed is still left alone`() {
        setUp()
        assertTrue(control.apply(DndMode.PRIORITY))
        // The observer is not reachable: the mode changes underneath us.
        zen.mode = DndMode.ALARMS
        assertFalse(control.apply(DndMode.OFF))
        assertEquals(DndMode.ALARMS, zen.mode)
        assertNull(control.setByMac)
        assertEquals(listOf(DndMode.PRIORITY), zen.writes.toList())
    }

    @Test
    fun `a person's own DND is never adopted or turned off`() {
        setUp(DndMode.PRIORITY)
        assertFalse(control.apply(DndMode.PRIORITY))
        assertNull(control.setByMac)
        assertFalse(control.apply(DndMode.OFF))
        assertEquals(DndMode.PRIORITY, zen.mode)
        assertTrue(zen.writes.isEmpty())
    }

    @Test
    fun `a person's other mode is not overwritten by a focus on`() {
        setUp(DndMode.ALARMS)
        assertFalse(control.apply(DndMode.PRIORITY))
        assertEquals(DndMode.ALARMS, zen.mode)
        assertNull(control.setByMac)
        assertEquals(emptyList<DndMode>(), zen.writes.toList())
    }

    @Test
    fun `a reconnect does not re-apply a mode it already set`() {
        setUp()
        assertTrue(control.apply(DndMode.PRIORITY))
        // Same command arrives again on the next connection or reconcile.
        assertFalse(control.apply(DndMode.PRIORITY))
        assertEquals(listOf(DndMode.PRIORITY), zen.writes.toList())
        assertTrue(control.apply(DndMode.OFF))
        assertEquals(listOf(DndMode.PRIORITY, DndMode.OFF), zen.writes.toList())
    }

    @Test
    fun `off with nothing of ours is a no-op`() {
        setUp(DndMode.OFF)
        assertFalse(control.apply(DndMode.OFF))
        assertTrue(zen.writes.isEmpty())
    }

    @Test
    fun `a refused write is not remembered`() {
        setUp()
        zen.accept = false
        assertFalse(control.apply(DndMode.PRIORITY))
        assertNull(control.setByMac)
        assertFalse(control.apply(DndMode.OFF))
        assertEquals(DndMode.OFF, zen.mode)
    }

    @Test
    fun `an unreadable mode is left alone`() {
        setUp()
        val blind = object : ZenSettings {
            override fun read(): DndMode? = null
            override fun listen(onChange: (DndMode?) -> Unit): AutoCloseable? = null
        }
        var wrote = false
        val control = ZenControl(blind, ZenSetter { wrote = true; true }, pollIntervalMs = 0)
        assertFalse(control.apply(DndMode.PRIORITY))
        assertFalse(wrote)
        assertNull(control.setByMac)
    }
}
