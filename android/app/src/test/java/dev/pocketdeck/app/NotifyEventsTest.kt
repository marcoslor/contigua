package dev.pocketdeck.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
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
            alert = true,
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
        assertNull(NotifyEvents.notificationEvent("a", "com.a", "", "", 0, alert = true))
        // over the cap: null (nothing partial goes out)
        assertNull(
            NotifyEvents.notificationEvent("a", "com.a", "x".repeat(NotifyEvents.MAX_CHARS + 1), null, 5, alert = true),
        )
        // title only, no text: still valid
        assertNotNull(NotifyEvents.notificationEvent("a", "com.a", "title only", null, 5, alert = true))
    }

    @Test
    fun `our own package and malformed ids are skipped`() {
        assertNull(NotifyEvents.notificationEvent("a", "dev.pocketdeck", "t", "x", 1, alert = true))
        assertNull(NotifyEvents.notificationEvent("a", "bad pkg!", "t", "x", 1, alert = true))
        assertNull(NotifyEvents.notificationEvent("", "com.a", "t", "x", 1, alert = true))
        assertNull(NotifyEvents.notificationEvent("a".repeat(65), "com.a", "t", "x", 1, alert = true))
        assertNull(NotifyEvents.notificationEvent("has|space", "com.a", "t", "x", 1, alert = true))
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
        for (action in listOf("play", "pause", "next", "prev", "seek", "volume")) {
            assertEquals(action, NotifyEvents.validMediaCommand(action))
        }
        assertNull(NotifyEvents.validMediaCommand("rewind"))
        assertNull(NotifyEvents.validMediaCommand(""))
    }

    @Test
    fun `media state carries the part 2 fields only when they mean something`() {
        val rich = NotifyEvents.mediaState(
            playing = true, pkg = "org.fossify.musicplayer", title = "tone440", artist = null,
            album = null, durationMs = 30_000, positionMs = 2_111, rate = 1.0,
            key = "s2", canSeek = true, volume = 7, volumeMax = 15,
        )
        assertEquals("s2", rich["key"])
        assertEquals(true, rich["canSeek"])
        assertEquals(7, rich["volume"])
        assertEquals(15, rich["volumeMax"])

        // An older phone sends none of them; a plain state must stay as small.
        val plain = NotifyEvents.mediaState(
            playing = false, pkg = "p", title = "t", artist = null, album = null,
            durationMs = null, positionMs = null, rate = 0.0,
        )
        assertEquals(0, plain.keys.count { it in setOf("key", "canSeek", "volume", "volumeMax") })

        // A bad key or a bogus maximum is dropped rather than sent.
        val odd = NotifyEvents.mediaState(
            playing = false, pkg = "p", title = "t", artist = null, album = null,
            durationMs = null, positionMs = null, rate = 0.0,
            key = "bad key", volume = 3, volumeMax = 0,
        )
        assertEquals(0, odd.keys.count { it in setOf("key", "volume", "volumeMax") })
        // The level is clamped to the maximum the session reports.
        val clamped = NotifyEvents.mediaState(
            playing = false, pkg = "p", title = "t", artist = null, album = null,
            durationMs = null, positionMs = null, rate = 0.0, volume = 99, volumeMax = 15,
        )
        assertEquals(15, clamped["volume"])
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
            alert = true,
            actions = NotifyEvents.selectActions(listOf(candidate(1, "Reply", reply = true))),
            ongoing = true,
        )!!
        assertEquals(true, event["ongoing"])
        @Suppress("UNCHECKED_CAST")
        val actions = event["actions"] as List<Map<String, Any?>>
        assertEquals(1, actions.single()["i"])
        assertEquals(true, actions.single()["reply"])
        // No actions, no field (an old Mac sees the same message as before).
        assertNull(NotifyEvents.notificationEvent("k-1", "com.chat", "t", "x", 5, alert = true)!!["actions"])
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
        assertNull(NotifyEvents.notificationEvent("k", "dev.pocketdeck", "t", "x", 1, alert = true))
        assertNotNull(
            NotifyEvents.notificationEvent("k", "dev.pocketdeck", "t", "x", 1, alert = true, debugPoster = true),
        )
        assertTrue(NotifyEvents.debugPoster("dev.pocketdeck", flagged = true, debugBuild = true))
        // Release builds never forward their own package, flagged or not.
        assertEquals(false, NotifyEvents.debugPoster("dev.pocketdeck", flagged = true, debugBuild = false))
        assertEquals(false, NotifyEvents.debugPoster("com.other", flagged = true, debugBuild = true))
    }

    @Test
    fun `alert follows Android's own rule`() {
        // The first post of a key always alerts, whatever the app asked for.
        assertTrue(NotifyEvents.alerts(true, onlyAlertOnce = false, contentChanged = true, progressOnly = false))
        assertTrue(NotifyEvents.alerts(true, onlyAlertOnce = true, contentChanged = false, progressOnly = true))
        // An update the app asked to alert once does not.
        assertEquals(false, NotifyEvents.alerts(false, onlyAlertOnce = true, contentChanged = true, progressOnly = false))
        assertEquals(false, NotifyEvents.alerts(false, onlyAlertOnce = true, contentChanged = false, progressOnly = false))
        // An update whose title and text did not change says nothing new.
        assertEquals(false, NotifyEvents.alerts(false, onlyAlertOnce = false, contentChanged = false, progressOnly = false))
        // A changed update alerts.
        assertTrue(NotifyEvents.alerts(false, onlyAlertOnce = false, contentChanged = true, progressOnly = false))
    }

    @Test
    fun `a bar that only moves is not news`() {
        // Row 6: both posts carry a bar and the title stayed -> quiet, even
        // with a text that moves ("12 MB of 50 MB" -> "13 MB of 50 MB").
        assertTrue(NotifyEvents.progressOnly(previousHadBar = true, hadBar = true,
                                             previousTitleHash = "t1", titleHash = "t1"))
        assertEquals(false, NotifyEvents.alerts(false, onlyAlertOnce = false, contentChanged = true, progressOnly = true))
        // The post that drops the bar has no bar: it is not progress-only.
        assertEquals(false, NotifyEvents.progressOnly(previousHadBar = true, hadBar = false,
                                                      previousTitleHash = "t1", titleHash = "t1"))
        assertTrue(NotifyEvents.alerts(false, onlyAlertOnce = false, contentChanged = true, progressOnly = false))
        // A first post with a bar still alerts, and a new title alerts.
        assertTrue(NotifyEvents.alerts(true, onlyAlertOnce = false, contentChanged = true, progressOnly = true))
        assertEquals(false, NotifyEvents.progressOnly(previousHadBar = true, hadBar = true,
                                                      previousTitleHash = "t1", titleHash = "t2"))
        assertTrue(NotifyEvents.alerts(false, onlyAlertOnce = false, contentChanged = true, progressOnly = false))
        // No previous post, no bar: nothing to compare.
        assertEquals(false, NotifyEvents.progressOnly(previousHadBar = false, hadBar = true,
                                                      previousTitleHash = null, titleHash = "t1"))
    }

    @Test
    fun `a children-only group keeps its lone summary quiet`() {
        assertEquals(false, NotifyEvents.summaryAlerts(NotifyEvents.GROUP_ALERT_CHILDREN))
        assertTrue(NotifyEvents.summaryAlerts(NotifyEvents.GROUP_ALERT_SUMMARY))
        assertTrue(NotifyEvents.summaryAlerts(NotifyEvents.GROUP_ALERT_ALL))
    }

    @Test
    fun `importance can only make a post quieter`() {
        assertTrue(NotifyEvents.quietByImportance(NotifyEvents.IMPORTANCE_MIN))
        assertTrue(NotifyEvents.quietByImportance(NotifyEvents.IMPORTANCE_LOW))
        assertEquals(false, NotifyEvents.quietByImportance(NotifyEvents.IMPORTANCE_DEFAULT))
        assertEquals(false, NotifyEvents.quietByImportance(NotifyEvents.IMPORTANCE_HIGH))
        assertEquals(false, NotifyEvents.quietByImportance(null))
    }

    @Test
    fun `the title hash is stable, short and carries no text`() {
        val hash = NotifyEvents.titleHash("Download")
        assertEquals(hash, NotifyEvents.titleHash("Download"))
        assertEquals(16, hash.length)
        assertTrue(hash.all { it in "0123456789abcdef" })
        assertNotEquals(hash, NotifyEvents.titleHash("Download failed"))
        assertNotEquals(hash, NotifyEvents.titleHash(null))
        assertEquals(NotifyEvents.titleHash(null), NotifyEvents.titleHash(""))
        assertEquals(false, hash.contains("Download"))
    }

    @Test
    fun `content hashes compare posts without keeping their text`() {
        val hash = NotifyEvents.contentHash("Design review", "Deck at 4")
        assertEquals(hash, NotifyEvents.contentHash("Design review", "Deck at 4"))
        assertEquals(16, hash.length)
        assertTrue(hash.all { it in "0123456789abcdef" })
        assertNotEquals(hash, NotifyEvents.contentHash("Design review", "Deck at 5"))
        assertNotEquals(hash, NotifyEvents.contentHash("Design review 2", "Deck at 4"))
        // A missing title and an empty one are the same content.
        assertEquals(NotifyEvents.contentHash(null, "x"), NotifyEvents.contentHash("", "x"))
        assertEquals(false, hash.contains("Deck"))
    }

    @Test
    fun `group hashes are 64 bits over the package and the key`() {
        val hash = NotifyEvents.groupHash("com.whatsapp", "Family chat")
        assertEquals(hash, NotifyEvents.groupHash("com.whatsapp", "Family chat"))
        assertEquals(16, hash.length)
        assertTrue(hash.all { it in "0123456789abcdef" })
        assertNotEquals(hash, NotifyEvents.groupHash("com.whatsapp", "Work chat"))
        assertNotEquals(hash, NotifyEvents.groupHash("com.slack", "Family chat"))
        // The separator keeps a split across the two strings apart.
        assertNotEquals(NotifyEvents.groupHash("a", "bc"), NotifyEvents.groupHash("ab", "c"))
        assertEquals(false, hash.contains("Family"))
    }

    @Test
    fun `every post carries alert and only a grouped one carries group`() {
        val plain = NotifyEvents.notificationEvent("k", "com.a", "t", "x", 1, alert = true)!!
        assertEquals(true, plain["alert"])
        assertEquals(false, plain.containsKey("group"))
        val quiet = NotifyEvents.notificationEvent(
            "k", "com.a", "t", "x", 1, alert = false, group = "0123456789abcdef",
        )!!
        assertEquals(false, quiet["alert"])
        assertEquals("0123456789abcdef", quiet["group"])
    }
}
