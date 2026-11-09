package dev.pocketdeck.server

import dev.pocketdeck.server.AppLink.Action
import dev.pocketdeck.server.AppLink.Event
import dev.pocketdeck.server.AppLink.State
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The shell service serves only what the app process currently vouches for
 * (docs/specs/pairing.md PAIR-19/PAIR-20): every transition, including the
 * events that must be ignored.
 */
class AppLinkTest {

    private val macA = PairedClient("a1", "Studio Mac", "aa".repeat(32))
    private val macB = PairedClient("b2", "Pixel 8", "bb".repeat(32))
    private val fpOld = "11".repeat(32)
    private val fpNew = "22".repeat(32)

    private fun linked(
        fp: String = fpOld,
        pairs: List<PairedClient> = listOf(macA),
    ) = State.Linked(identityFp = fp, certPem = "CERT-$fp", keyP8 = "KEY-$fp", pairs = pairs)

    private fun push(
        fp: String = fpOld,
        pairs: List<PairedClient> = listOf(macA),
        cert: String = "CERT-$fp",
        key: String = "KEY-$fp",
    ) = Event.AppPushed(identityFp = fp, certPem = cert, keyP8 = key, pairs = pairs)

    @Test
    fun `nothing is served before the app vouches`() {
        val t = AppLink.transition(State.Unlinked, Event.AppGone)

        assertSame(State.Unlinked, t.state)
        assertEquals(emptyList<Action>(), t.actions)
    }

    @Test
    fun `the first push is adopted without dropping anything`() {
        val t = AppLink.transition(State.Unlinked, push())

        assertEquals(linked(), t.state)
        assertEquals(emptyList<Action>(), t.actions)
    }

    @Test
    fun `the same identity and paired set keep the live session`() {
        val t = AppLink.transition(linked(), push())

        assertEquals(linked(), t.state)
        assertEquals(emptyList<Action>(), t.actions)
    }

    @Test
    fun `pairing order and display names are not a new trust decision`() {
        val renamed = macA.copy(name = "Renamed Mac")
        val t = AppLink.transition(
            linked(pairs = listOf(macA, macB)),
            push(pairs = listOf(macB, renamed)),
        )

        assertEquals(linked(pairs = listOf(macB, renamed)), t.state)
        assertEquals(emptyList<Action>(), t.actions)
    }

    @Test
    fun `a different identity tells every Mac it was forgotten before the drop`() {
        val t = AppLink.transition(linked(), push(fp = fpNew))

        assertEquals(linked(fp = fpNew), t.state)
        assertEquals(listOf(Action.NOTIFY_FORGOTTEN(null), Action.DROP_SESSIONS, Action.FORGET_CACHE),
                     t.actions)
    }

    @Test
    fun `a removed Mac is told it was forgotten before the drop`() {
        val t = AppLink.transition(linked(pairs = listOf(macA, macB)), push(pairs = listOf(macA)))

        assertEquals(linked(pairs = listOf(macA)), t.state)
        assertEquals(listOf(Action.NOTIFY_FORGOTTEN(setOf("b2")), Action.DROP_SESSIONS,
                            Action.FORGET_CACHE), t.actions)
    }

    @Test
    fun `an added Mac is a different paired set but nobody was forgotten`() {
        val t = AppLink.transition(linked(pairs = listOf(macA)), push(pairs = listOf(macA, macB)))

        assertEquals(linked(pairs = listOf(macA, macB)), t.state)
        assertEquals(listOf(Action.DROP_SESSIONS, Action.FORGET_CACHE), t.actions)
    }

    @Test
    fun `a Mac with the same client id but a new pin is told it was forgotten`() {
        val rotated = macA.copy(macFpHex = "cc".repeat(32))
        val t = AppLink.transition(linked(), push(pairs = listOf(rotated)))

        assertEquals(linked(pairs = listOf(rotated)), t.state)
        assertEquals(listOf(Action.NOTIFY_FORGOTTEN(setOf("a1")), Action.DROP_SESSIONS,
                            Action.FORGET_CACHE), t.actions)
    }

    @Test
    fun `the app dying drops the session and forgets the cached material`() {
        val t = AppLink.transition(linked(), Event.AppGone)

        assertSame(State.Unlinked, t.state)
        assertEquals(listOf(Action.DROP_SESSIONS, Action.FORGET_CACHE), t.actions)
    }

    @Test
    fun `a push without an identity is handled as the app being gone`() {
        val noIdentity = push(fp = "", cert = "", key = "")
        val t = AppLink.transition(linked(), noIdentity)

        assertSame(State.Unlinked, t.state)
        assertEquals(listOf(Action.DROP_SESSIONS, Action.FORGET_CACHE), t.actions)
    }

    @Test
    fun `the app coming back after a death is adopted without dropping a session`() {
        val afterDeath = AppLink.transition(linked(), Event.AppGone).state
        val t = AppLink.transition(afterDeath, push())

        assertEquals(linked(), t.state)
        assertEquals(emptyList<Action>(), t.actions)
    }

    @Test
    fun `a completed pairing joins the linked set without a drop`() {
        val t = AppLink.transition(linked(pairs = emptyList()), Event.PhonePaired(macB))

        assertEquals(linked(pairs = listOf(macB)), t.state)
        assertEquals(emptyList<Action>(), t.actions)
    }

    @Test
    fun `a completed pairing replaces the row with the same client id`() {
        val again = macA.copy(macFpHex = "dd".repeat(32))
        val t = AppLink.transition(linked(), Event.PhonePaired(again))

        assertEquals(linked(pairs = listOf(again)), t.state)
    }

    @Test
    fun `a completed pairing with no app link is ignored`() {
        val t = AppLink.transition(State.Unlinked, Event.PhonePaired(macA))

        assertSame(State.Unlinked, t.state)
        assertTrue(t.actions.isEmpty())
    }

    @Test
    fun `the transition log names no key material`() {
        val text = AppLink.describe(linked()) + " " + AppLink.describe(push()) +
            " " + AppLink.describe(Event.AppGone)
        assertTrue(text, !text.contains("CERT-") && !text.contains("KEY-"))
    }
}
