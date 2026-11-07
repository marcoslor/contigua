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
    fun `the sequence space is session lifetime, not epoch lifetime`() {
        val window = MediaReplayWindow()
        for (seq in 1L..1004L) assertTrue(window.accept(seq))
        // The headline is the sequence, not the media epoch: switching epochs
        // continues the same space. A sender that restarted at 1 would reuse
        // a nonce, and the receiver would still refuse the duplicate.
        assertFalse("a reset to 1 after an epoch switch is a duplicate", window.accept(1))
        assertTrue("the next sequence continues across the switch", window.accept(1005))
        assertEquals(1005L, window.highest())
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
        assertEquals(896, at8)
        assertEquals(2240, at20)
        assertTrue(at8 <= MediaReplayWindow.SHIPPED)
        assertTrue("a raised cap must raise the window", at20 > MediaReplayWindow.SHIPPED)
        // Both are valid constructor sizes, so a future cap can use the answer
        // without a second rounding step (B/R13).
        MediaReplayWindow(at8)
        MediaReplayWindow(at20)
    }
}
