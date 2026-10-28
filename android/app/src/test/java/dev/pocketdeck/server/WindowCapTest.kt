package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WIN-32, the cap: four app streams per session, the Phone Mirror has its own
 * encoder and is not counted, and the refusal happens before a display exists
 * so a refused window costs the phone nothing.
 */
class WindowCapTest : SessionFixture() {

    @Test
    fun `the count is every app stream and never the mirror`() {
        assertTrue(WindowCap.counted(WindowContent.App("com.a", null)))
        assertTrue(WindowCap.counted(WindowContent.Link("https://example.com")))
        assertFalse("the Phone Mirror is a separate encoder", WindowCap.counted(WindowContent.Phone))
        assertFalse("a stream without content yet", WindowCap.counted(null))
    }

    @Test
    fun `four app streams fit and a fifth does not`() {
        assertEquals(4, WindowCap.MAX_WINDOWS)
        for (open in 0 until WindowCap.MAX_WINDOWS) {
            assertTrue("$open open", WindowCap.allows(open))
        }
        assertFalse(WindowCap.allows(WindowCap.MAX_WINDOWS))
        assertFalse(WindowCap.allows(WindowCap.MAX_WINDOWS + 1))
    }

    @Test
    fun `state reports the cap`() {
        connect()
        assertEquals(WindowCap.MAX_WINDOWS.toLong(), readUntil("state")["maxWindows"])
    }

    @Test
    fun `a fifth app window is refused and creates no display`() {
        connect()
        for (stream in 1..WindowCap.MAX_WINDOWS) {
            open(stream, "com.a")
            assertEquals(stream.toLong(), readUntil("window.opened")["stream"])
        }
        assertEquals(WindowCap.MAX_WINDOWS, platform.opens.size)
        val displays = platform.opens.map { it.displayId }

        open(5, "com.a")
        val error = readUntil("error")
        assertEquals("too_many_windows", error["code"])
        assertEquals(5L, error["stream"])
        assertEquals("a refused window creates no display", WindowCap.MAX_WINDOWS, platform.opens.size)
        assertEquals(displays, platform.opens.map { it.displayId })

        // With newInstance too: the cap is the cap.
        open(6, "com.a", newInstance = true)
        assertEquals("too_many_windows", readUntil("error")["code"])
        assertEquals(WindowCap.MAX_WINDOWS, platform.opens.size)
    }

    @Test
    fun `the mirror is not counted and still opens at the cap`() {
        connect()
        for (stream in 1..WindowCap.MAX_WINDOWS) {
            open(stream, "com.a")
            readUntil("window.opened")
        }
        open(9, "com.a", phone = true)
        val opened = readUntil("window.opened")
        assertEquals(9L, opened["stream"])
        assertEquals("display 0 is the phone's own screen", 0L, opened["displayId"])
        assertEquals("the mirror makes no virtual display", WindowCap.MAX_WINDOWS, platform.opens.size)
        assertEquals(1, platform.mirrors.size)
    }

    @Test
    fun `closing one window makes room again`() {
        connect()
        for (stream in 1..WindowCap.MAX_WINDOWS) {
            open(stream, "com.a")
            readUntil("window.opened")
        }
        send(mapOf("t" to "window.close", "stream" to 2))
        readUntil("window.closed")
        open(7, "com.a")
        assertEquals(7L, readUntil("window.opened")["stream"])
    }

    @Test
    fun `a reopened stream id is not counted against itself`() {
        // The Mac reuses a stream id after a drop; replacing it must not be a
        // sixth window while it is still the same one.
        connect()
        for (stream in 1..WindowCap.MAX_WINDOWS) {
            open(stream, "com.a")
            readUntil("window.opened")
        }
        open(4, "com.a", newInstance = true)
        val opened = readUntil("window.opened")
        assertEquals(4L, opened["stream"])
        assertEquals(WindowCap.MAX_WINDOWS + 1, platform.opens.size)
    }
}
