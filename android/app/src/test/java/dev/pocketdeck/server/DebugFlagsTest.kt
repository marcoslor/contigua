package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * I-1: pairing is auto-approved only when a debug build has the explicit
 * `debug.pocketdeck.auto_approve=1` opt-in; an absent property is off.
 */
class DebugFlagsTest {

    @Test
    fun offWhenThePropertyIsAbsent() {
        assertEquals(false, DebugFlags.autoApprovePairing(debug = true, property = null))
        assertEquals(false, DebugFlags.autoApprovePairing(debug = true, property = ""))
        assertEquals(false, DebugFlags.autoApprovePairing(debug = true, property = "0"))
        assertEquals(false, DebugFlags.autoApprovePairing(debug = true, property = "true"))
    }

    @Test
    fun onOnlyForTheExactDebugOptIn() {
        assertEquals(true, DebugFlags.autoApprovePairing(debug = true, property = "1"))
        assertEquals(false, DebugFlags.autoApprovePairing(debug = false, property = "1"))
    }
}
