package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * P3's replay window and its cap-derived sizing (PATH-26). The window is one
 * u64 space per direction; the shipped 1024 must cover one second at the
 * 8 Mbit/s cap, and the test notices when a raised cap would outgrow it.
 */
class MediaReplayWindowTest {

    @Test
    fun `a sequence is accepted once, old ones are refused`() {
        val window = MediaReplayWindow()
        assertTrue(window.accept(1))
        assertTrue(window.accept(3))
        assertTrue("reordered but inside the window", window.accept(2))
        assertFalse("duplicate", window.accept(3))
        assertFalse("zero is not a sequence", window.accept(0))
        assertEquals(3L, window.highest())
    }

    @Test
    fun `a jump past the window resets it`() {
        val window = MediaReplayWindow()
        for (seq in 1L..2048L) assertTrue(window.accept(seq))
        assertFalse(window.accept(2048))
        assertFalse(window.accept(1025)) // highest - 1025 = 1023, but already seen
        assertFalse(window.accept(1))    // outside the 1024 window
        assertEquals(2048L, window.highest())
        assertTrue("a fresh sequence above the jump", window.accept(5000))
        assertEquals(5000L, window.highest())
        assertTrue("an unfilled slot inside the new window", window.accept(4500))
    }

    @Test
    fun `the window size is bounded`() {
        assertThrows(IllegalArgumentException::class.java) { MediaReplayWindow(63) }
        assertThrows(IllegalArgumentException::class.java) { MediaReplayWindow(65_600) }
        MediaReplayWindow(64)
        MediaReplayWindow(65_536)
    }

    @Test
    fun `1024 covers one second at 8 Mbit but not at 20 Mbit`() {
        val at8 = MediaCrypto.requiredReplayWindow(8_000_000)
        val at20 = MediaCrypto.requiredReplayWindow(20_000_000)
        assertEquals(878, at8)
        assertEquals(2193, at20)
        assertTrue(at8 <= MediaReplayWindow.SHIPPED)
        assertTrue("a raised cap must raise the window", at20 > MediaReplayWindow.SHIPPED)
    }
}
