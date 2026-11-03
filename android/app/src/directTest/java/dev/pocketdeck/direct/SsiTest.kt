package dev.pocketdeck.direct

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * The service-specific info (docs/design/direct-link.md §6, transport
 * DIRECT-10): an 8-byte HMAC per ten-minute window, and nothing else on the
 * air. The vectors were computed from the written formula.
 */
class SsiTest {

    private val key = ByteArray(32) { it.toByte() }

    @Test
    fun theWrittenFormulaHasFixedVectors() {
        assertEquals("79f9fb0dab2fb6bb", Ssi.hex(key, 0))
        assertEquals("c3d0b584e839dec9", Ssi.hex(key, 1))
        assertEquals("83dede3e40c31eee", Ssi.hex(key, 17))
    }

    @Test
    fun theWindowTurnsEveryTenMinutes() {
        assertEquals(0, Ssi.window(0))
        assertEquals(0, Ssi.window(599))
        assertEquals(1, Ssi.window(600))
        assertEquals(1, Ssi.window(1199))
        assertEquals(2, Ssi.window(1200))
    }

    @Test
    fun aDifferentWindowGivesDifferentBytes() {
        val zero = Ssi.bytes(key, 0)
        val one = Ssi.bytes(key, 1)
        assertEquals(8, zero.size)
        assertFalse(zero.contentEquals(one))
    }

    @Test
    fun aDifferentKeyGivesDifferentBytes() {
        val other = ByteArray(32) { (it + 1).toByte() }
        assertFalse(Ssi.bytes(key, 3).contentEquals(Ssi.bytes(other, 3)))
    }
}
