package dev.pocketdeck.app

import org.junit.Assert.assertEquals
import org.junit.Test

class PairingCodeTest {

    @Test
    fun `six digits are grouped three plus three`() {
        assertEquals("482 913", formatPairingCode("482913"))
    }

    @Test
    fun `anything that is not six digits is unchanged`() {
        assertEquals("4829", formatPairingCode("4829"))
        assertEquals("", formatPairingCode(""))
        assertEquals("abc", formatPairingCode("abc"))
    }
}
