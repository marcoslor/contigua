package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** WIN-74: a window display runs only in a display group of its own. */
class WindowDisplayRouteTest {

    @Test
    fun `WIN-74 the panel's group is refused`() {
        assertFalse(WindowGroup.accepted(DisplayProbe.DEFAULT_GROUP_ID))
    }

    @Test
    fun `WIN-74 a group that cannot be read is refused`() {
        // DisplayProbe answers the panel's group when it cannot read one, and
        // the platform's own "invalid group" is -1.
        assertFalse(WindowGroup.accepted(-1))
    }

    @Test
    fun `WIN-74 a group of its own is accepted`() {
        assertTrue(WindowGroup.accepted(1))
        assertTrue(WindowGroup.accepted(5))
    }

    @Test
    fun `WIN-74 the refusal carries the wire code and its route`() {
        val refused = WindowDisplayRefused(WindowRoute.PLAIN_PANEL_GROUP, 0)
        assertEquals("windows_unsupported", WindowDisplayRefused.CODE)
        assertEquals(WindowRoute.PLAIN_PANEL_GROUP, refused.route)
        assertEquals(0, refused.groupId)
        assertEquals(listOf("device", "plain", "plain-panel-group"), WindowRoute.entries.map { it.wire })
    }
}
