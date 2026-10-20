package dev.pocketdeck.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The debug fake media session's argument parsing (android/app/src/debug,
 * docs/design/notify.md "Media part 2"). Pure: no device, no session.
 */
class MediaDebugArgsTest {

    @Test
    fun `start needs a slot among the two fake sessions`() {
        val first = MediaDebugArgs.parse("start", 1, paused = false)!!
        assertTrue(first.start)
        assertEquals(1, first.index)
        assertFalse(first.paused)
        assertEquals(2, MediaDebugArgs.parse("start", 2, paused = true)!!.index)
        assertNull(MediaDebugArgs.parse("start", null, paused = false))
        assertNull(MediaDebugArgs.parse("start", 0, paused = false))
        assertNull(MediaDebugArgs.parse("start", 3, paused = false))
    }

    @Test
    fun `stop without a slot stops both`() {
        val both = MediaDebugArgs.parse("stop", null, paused = false)!!
        assertFalse(both.start)
        assertNull(both.index)
        assertEquals(2, MediaDebugArgs.parse("stop", 2, paused = false)!!.index)
    }

    @Test
    fun `anything else is not ours`() {
        assertNull(MediaDebugArgs.parse(null, 1, paused = false))
        assertNull(MediaDebugArgs.parse("", 1, paused = false))
        assertNull(MediaDebugArgs.parse("launch", 1, paused = false))
        // Case and stray spaces are the shell's, not a different operation.
        assertEquals("start", MediaDebugArgs.parse(" Start ", 1, paused = false)!!.op)
    }
}
