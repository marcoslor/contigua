package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** MCP-107: which display each window is on, as the settle watch reads it. */
class WindowDisplaysTest {

    private val content = SettleWatch.TYPE_WINDOW_CONTENT_CHANGED
    private val windowsChanged = SettleWatch.TYPE_WINDOWS_CHANGED

    @Test
    fun testAWindowMissedThenListedByWindowsChangedCounts() { // [MCP-107]
        val map = WindowDisplays()
        map.replace(mapOf(5 to listOf(1)))
        assertEquals(5, map.displayOf(1))
        // An unknown window's first event reads the list again...
        assertTrue(map.needsRead(content, 7))
        // ...but the read does not list it yet (the window is still arriving).
        map.replace(mapOf(5 to listOf(1)))
        assertNull(map.displayOf(7))
        // Its later content changes do not read again: once per id.
        assertFalse(map.needsRead(content, 7))
        // The platform's windows-changed always reads again, every time...
        assertTrue(map.needsRead(windowsChanged, -1))
        map.replace(mapOf(5 to listOf(1, 7)))
        // ...so the window it missed now counts on its display.
        assertEquals(5, map.displayOf(7))
        assertTrue(map.needsRead(windowsChanged, -1))
    }

    @Test
    fun testAReadReplacesTheWholeMap() { // [MCP-107]
        val map = WindowDisplays()
        map.replace(mapOf(5 to listOf(1), 0 to listOf(2)))
        map.replace(mapOf(0 to listOf(1)))
        assertEquals(0, map.displayOf(1))
        assertNull(map.displayOf(2))
    }
}
