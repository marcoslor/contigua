package dev.pocketdeck.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NotifyEventsTest {

    @Test
    fun `notification event keeps fields and caps`() {
        val event = NotifyEvents.notificationEvent(
            id = "0_com.whatsapp_7_null_10213",
            pkg = "com.whatsapp",
            title = "Design review",
            text = "Deck vs slides at 4",
            when_ = 1_700_000_000_000,
        )
        assertNotNull(event)
        assertEquals("notify.post", event!!["t"])
        assertEquals("com.whatsapp", event["pkg"])
        assertEquals("Design review", event["title"])
        assertEquals("Deck vs slides at 4", event["text"])
        assertEquals(1_700_000_000_000L, event["when"])
    }

    @Test
    fun `long text is dropped whole, and empty content drops the event`() {
        assertNull(NotifyEvents.notificationEvent("a", "com.a", "", "", 0))
        // over the cap: null (nothing partial goes out)
        assertNull(
            NotifyEvents.notificationEvent("a", "com.a", "x".repeat(NotifyEvents.MAX_CHARS + 1), null, 5),
        )
        // title only, no text: still valid
        assertNotNull(NotifyEvents.notificationEvent("a", "com.a", "title only", null, 5))
    }

    @Test
    fun `our own package and malformed ids are skipped`() {
        assertNull(NotifyEvents.notificationEvent("a", "dev.pocketdeck", "t", "x", 1))
        assertNull(NotifyEvents.notificationEvent("a", "bad pkg!", "t", "x", 1))
        assertNull(NotifyEvents.notificationEvent("", "com.a", "t", "x", 1))
        assertNull(NotifyEvents.notificationEvent("a".repeat(65), "com.a", "t", "x", 1))
        assertNull(NotifyEvents.notificationEvent("has|space", "com.a", "t", "x", 1))
    }

    @Test
    fun `removed event is id only`() {
        assertEquals("notify.remove", NotifyEvents.removedEvent("k-1")!!["t"])
        assertEquals("k-1", NotifyEvents.removedEvent("k-1")!!["id"])
        assertNull(NotifyEvents.removedEvent(""))
        assertNull(NotifyEvents.removedEvent("bad /id"))
    }

    @Test
    fun `media state carries rate only while playing`() {
        val playing = NotifyEvents.mediaState(
            playing = true, pkg = "org.fossify.musicplayer", title = "tone440",
            artist = "Me", album = "Music", durationMs = 30_000, positionMs = 2_111, rate = 1.0,
        )
        assertEquals("tone440", playing["title"])
        assertEquals(30_000L, playing["durationMs"])
        assertEquals(2_111L, playing["positionMs"])
        assertEquals(1.0, playing["rate"])
        assertTrue(playing["playing"] == true)

        val paused = NotifyEvents.mediaState(
            playing = false, pkg = "org.fossify.musicplayer", title = "tone440",
            artist = null, album = null, durationMs = 30_000, positionMs = 2_500, rate = 0.0,
        )
        assertNull(paused["rate"])
        assertEquals(0, paused.keys.count { it == "artist" || it == "album" })
    }

    @Test
    fun `media clear and commands`() {
        val clear = NotifyEvents.mediaState(false, null, null, null, null, null, null, 0.0)
        assertEquals(2, clear.size) // t + playing only
        assertEquals("play", NotifyEvents.validMediaCommand("play"))
        assertEquals("prev", NotifyEvents.validMediaCommand("prev"))
        assertNull(NotifyEvents.validMediaCommand("seek"))
        assertNull(NotifyEvents.validMediaCommand(""))
    }

    // ---- actions (ROADMAP v0.2 #8) ----------------------------------------

    private fun candidate(
        index: Int,
        title: String?,
        hasIntent: Boolean = true,
        reply: Boolean = false,
        contextual: Boolean = false,
    ) = NotifyEvents.ActionCandidate(index, title, hasIntent, reply, contextual)

    @Test
    fun `actions keep original indexes, skip unusable ones and cap the title`() {
        val kept = NotifyEvents.selectActions(
            listOf(
                candidate(0, "  Mark as read  "),
                candidate(1, null),
                candidate(2, "No intent", hasIntent = false),
                candidate(3, "Smart reply", contextual = true),
                candidate(4, "Reply", reply = true),
                candidate(5, "Fourth button"),
            ),
        )
        assertEquals(listOf(0, 4, 5), kept.map { it.index })
        assertEquals("Mark as read", kept[0].title)
        assertTrue(kept[1].reply)
        // The advertised index is the phone's, not the position in the kept list.
        assertEquals(5, kept[2].index)
    }

    @Test
    fun `action titles are capped at 64 chars and at most three are advertised`() {
        val long = NotifyEvents.selectActions(listOf(candidate(0, "x".repeat(100))))
        assertEquals(NotifyEvents.MAX_ACTION_TITLE, long.single().title!!.length)

        val many = (0 until 6).map { candidate(it, "button $it") }
        assertEquals(NotifyEvents.MAX_ACTIONS, NotifyEvents.selectActions(many).size)
    }

    @Test
    fun `wire form carries i, title and reply only`() {
        val wire = NotifyEvents.actionWire(
            NotifyEvents.selectActions(listOf(candidate(2, "Reply", reply = true), candidate(0, "Open"))),
        )
        assertEquals(2, wire.size)
        assertEquals(2, wire[0]["i"])
        assertEquals("Reply", wire[0]["title"])
        assertEquals(true, wire[0]["reply"])
        assertNull(wire[1]["reply"])
        assertEquals(setOf("i", "title"), wire[1].keys)
    }

    @Test
    fun `notification event carries actions and ongoing`() {
        val event = NotifyEvents.notificationEvent(
            id = "k-1", pkg = "com.chat", title = "t", text = "x", when_ = 5,
            actions = NotifyEvents.selectActions(listOf(candidate(1, "Reply", reply = true))),
            ongoing = true,
        )!!
        assertEquals(true, event["ongoing"])
        @Suppress("UNCHECKED_CAST")
        val actions = event["actions"] as List<Map<String, Any?>>
        assertEquals(1, actions.single()["i"])
        assertEquals(true, actions.single()["reply"])
        // No actions, no field (an old Mac sees the same message as before).
        assertNull(NotifyEvents.notificationEvent("k-1", "com.chat", "t", "x", 5)!!["actions"])
    }

    @Test
    fun `reply text is refused on a non-reply action and over the cap`() {
        assertNull(NotifyEvents.actionTextRefusal(null, reply = false))
        assertNull(NotifyEvents.actionTextRefusal("", reply = false))
        assertNull(NotifyEvents.actionTextRefusal("hello", reply = true))
        assertEquals("not a reply action", NotifyEvents.actionTextRefusal("hello", reply = false))
        assertEquals(
            "text cap",
            NotifyEvents.actionTextRefusal("x".repeat(NotifyEvents.MAX_REPLY_CHARS + 1), reply = true),
        )
        assertNull(NotifyEvents.actionTextRefusal("x".repeat(NotifyEvents.MAX_REPLY_CHARS), reply = true))
    }

    @Test
    fun `an index that was never advertised is unknown`() {
        val advertised = NotifyEvents.selectActions(listOf(candidate(0, "A"), candidate(1, "B")))
        assertNotNull(NotifyEvents.actionAt(advertised, 1))
        assertNull(NotifyEvents.actionAt(advertised, 2))
        assertNull(NotifyEvents.actionAt(emptyList(), 0))
    }

    @Test
    fun `ongoing and no-clear notifications are not dismissed`() {
        assertTrue(NotifyEvents.canDismiss(ongoing = false, noClear = false))
        assertEquals(false, NotifyEvents.canDismiss(ongoing = true, noClear = false))
        assertEquals(false, NotifyEvents.canDismiss(ongoing = false, noClear = true))
    }

    @Test
    fun `the debug poster is the only own-package notification that leaves`() {
        assertNull(NotifyEvents.notificationEvent("k", "dev.pocketdeck", "t", "x", 1))
        assertNotNull(
            NotifyEvents.notificationEvent("k", "dev.pocketdeck", "t", "x", 1, debugPoster = true),
        )
        assertTrue(NotifyEvents.debugPoster("dev.pocketdeck", flagged = true, debugBuild = true))
        // Release builds never forward their own package, flagged or not.
        assertEquals(false, NotifyEvents.debugPoster("dev.pocketdeck", flagged = true, debugBuild = false))
        assertEquals(false, NotifyEvents.debugPoster("com.other", flagged = true, debugBuild = true))
    }
}
