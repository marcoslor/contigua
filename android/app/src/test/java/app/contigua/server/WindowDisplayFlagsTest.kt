package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WIN-51 / ISS-35: a window's display must never take the phone's top focus.
 * The input method serves only the top-focused display, so without
 * `STEAL_TOP_FOCUS_DISABLED` the phone's own screen loses its keyboard while a
 * window is open.
 */
class WindowDisplayFlagsTest {

    private val own = WindowDisplayFlags.requested(WindowRoute.PLAIN)
    private val device = WindowDisplayFlags.requested(WindowRoute.DEVICE)

    @Test
    fun `a window's display asks not to take the phone's top focus`() {
        for (flags in listOf(own, device)) {
            assertTrue(flags and WindowDisplayFlags.STEAL_TOP_FOCUS_DISABLED != 0)
            // The system drops STEAL_TOP_FOCUS_DISABLED unless the display is
            // trusted and has its own focus: the three are one request.
            assertTrue(flags and WindowDisplayFlags.OWN_FOCUS != 0)
            assertTrue(flags and WindowDisplayFlags.TRUSTED != 0)
        }
    }

    @Test
    fun `a window's display asks for exactly that set`() {
        val allowed = setOf(
            WindowDisplayFlags.PUBLIC,
            WindowDisplayFlags.PRESENTATION,
            WindowDisplayFlags.OWN_CONTENT_ONLY,
            WindowDisplayFlags.SUPPORTS_TOUCH,
            WindowDisplayFlags.ROTATES_WITH_CONTENT,
            WindowDisplayFlags.DESTROY_CONTENT_ON_REMOVAL,
            WindowDisplayFlags.TRUSTED,
            WindowDisplayFlags.ALWAYS_UNLOCKED,
            WindowDisplayFlags.TOUCH_FEEDBACK_DISABLED,
            WindowDisplayFlags.OWN_FOCUS,
            WindowDisplayFlags.STEAL_TOP_FOCUS_DISABLED,
            WindowDisplayFlags.OWN_DISPLAY_GROUP,
        )
        assertEquals(allowed, bits(own))
        assertEquals(0, own and WindowDisplayFlags.SECURE)
        assertEquals(0, own and WindowDisplayFlags.AUTO_MIRROR)
    }

    @Test
    fun `WIN-74 each route changes only the group bits`() {
        assertEquals(WindowDisplayFlags.OWN_DISPLAY_GROUP or WindowDisplayFlags.DEVICE_DISPLAY_GROUP,
            own xor device)
        // OWN_DISPLAY_GROUP sends a device display back to the panel's group on
        // One UI, so the device route must never carry it.
        assertEquals(0, device and WindowDisplayFlags.OWN_DISPLAY_GROUP)
        val group = WindowDisplayFlags.OWN_DISPLAY_GROUP or WindowDisplayFlags.DEVICE_DISPLAY_GROUP
        assertEquals(own and group.inv(), device and group.inv())
        // The debug panel-group route is the device set with no device behind it.
        assertEquals(device, WindowDisplayFlags.requested(WindowRoute.PLAIN_PANEL_GROUP))
    }

    @Test
    fun `WIN-74 the device route is the spike's set plus the top-focus flag`() {
        // 0xf5cb is the set the 2026-11-04 probe saw in group 5 on One UI.
        assertEquals(0xf5cb or WindowDisplayFlags.STEAL_TOP_FOCUS_DISABLED, device)
    }

    @Test
    fun `the log names the flag it asked for`() {
        val names = WindowDisplayFlags.names(own).split("|")
        assertTrue("STEAL_TOP_FOCUS_DISABLED" in names)
        assertTrue("OWN_FOCUS" in names)
        assertTrue("TRUSTED" in names)
        assertFalse("SECURE" in names)
        assertFalse("AUTO_MIRROR" in names)
    }

    private fun bits(value: Int): Set<Int> =
        (0 until 32).filter { value and (1 shl it) != 0 }.map { 1 shl it }.toSet()
}
