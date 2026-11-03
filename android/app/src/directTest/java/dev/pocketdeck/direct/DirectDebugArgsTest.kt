package dev.pocketdeck.direct

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The reviewer's debug control (docs/design/direct-link.md §7, brief item 7):
 * `on`, `off`, `permission` and `state`, and nothing else. No person-facing UI.
 */
class DirectDebugArgsTest {

    @Test
    fun theFourDocumentedOperationsAreAccepted() {
        for (op in listOf("on", "off", "permission", "state")) {
            assertEquals(op, DirectDebugArgs.parse(op)?.op)
        }
    }

    @Test
    fun caseAndWhitespaceAreForgiven() {
        assertEquals("on", DirectDebugArgs.parse(" ON ")?.op)
        assertEquals("state", DirectDebugArgs.parse("State")?.op)
    }

    @Test
    fun anythingElseIsIgnored() {
        assertNull(DirectDebugArgs.parse(null))
        assertNull(DirectDebugArgs.parse(""))
        assertNull(DirectDebugArgs.parse("on; reboot"))
        assertNull(DirectDebugArgs.parse("start"))
        assertNull(DirectDebugArgs.parse("OFFF"))
    }
}
