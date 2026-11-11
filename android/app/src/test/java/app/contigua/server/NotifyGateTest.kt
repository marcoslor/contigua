package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The notification gate after the phone's own switch was removed
 * (docs/design/notify.md, docs/specs/settings-devices.md SET-DEV-09): the Mac's
 * `notify.enable` is the only person-facing switch, and the phone's listener
 * access decides whether it can be honoured.
 */
class NotifyGateTest {

    @Test
    fun `the gate truth table`() {
        // Mac off: nothing forwards, whichever way the listener grant stands.
        assertEquals(NotifyGate.OFF, notifyGate(macOn = false, listenerGranted = false))
        assertEquals(NotifyGate.OFF, notifyGate(macOn = false, listenerGranted = true))
        // Mac on: forwarding only with the phone's access.
        assertEquals(NotifyGate.NO_ACCESS, notifyGate(macOn = true, listenerGranted = false))
        assertEquals(NotifyGate.FORWARDING, notifyGate(macOn = true, listenerGranted = true))
    }

    @Test
    fun `only no access carries a reason and never claims forwarding`() {
        val off = notifyStateMessage(NotifyGate.OFF)
        assertEquals(false, off["on"])
        assertNull(off["reason"])

        val noAccess = notifyStateMessage(NotifyGate.NO_ACCESS)
        assertEquals(false, noAccess["on"])
        assertEquals("no_access", noAccess["reason"])

        val forwarding = notifyStateMessage(NotifyGate.FORWARDING)
        assertEquals(true, forwarding["on"])
        assertNull(forwarding["reason"])
    }

    @Test
    fun `no access while the Mac asked is the phone's attention item`() {
        assertTrue(needsNotificationAccessAttention(NotifyGate.NO_ACCESS))
        assertTrue(!needsNotificationAccessAttention(NotifyGate.OFF))
        assertTrue(!needsNotificationAccessAttention(NotifyGate.FORWARDING))
    }
}
