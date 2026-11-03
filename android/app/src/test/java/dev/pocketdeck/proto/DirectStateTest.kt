package dev.pocketdeck.proto

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `direct.state` (docs/PROTOCOL.md "Direct link", transport DIRECT-12): the
 * phone's switch and permission state with one of four closed reasons.
 */
class DirectStateTest {

    @Test
    fun onCarriesNoReason() {
        val message = PhoneDirectState(on = true).message()
        assertEquals("direct.state", message["t"])
        assertEquals(true, message["on"])
        assertFalse(message.containsKey("reason"))
    }

    @Test
    fun offCanNameTheReason() {
        val message = PhoneDirectState(on = false, reason = "no_permission").message()
        assertEquals("direct.state", message["t"])
        assertEquals(false, message["on"])
        assertEquals("no_permission", message["reason"])
    }

    @Test
    fun onlyTheFourDocumentedReasonsSurvive() {
        assertEquals(
            setOf("no_permission", "no_feature", "location_off", "aware_busy"),
            PhoneDirectState.REASONS,
        )
        for (reason in PhoneDirectState.REASONS) {
            assertEquals(reason, PhoneDirectState.of(false, reason).reason)
        }
        assertNull(PhoneDirectState.of(false, "Something went wrong").reason)
        assertNull(PhoneDirectState.of(false, null).reason)
        assertNull(PhoneDirectState.of(false, "no_permission ").reason)
    }

    @Test
    fun aMalformedReasonIsDroppedNotPassedThrough() {
        val message = PhoneDirectState.of(true, "internal").message()
        assertTrue(message["on"] as Boolean)
        assertFalse("a code from outside the set never reaches the wire", message.containsKey("reason"))
    }
}
