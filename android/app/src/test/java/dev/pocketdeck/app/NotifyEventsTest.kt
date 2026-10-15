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
}
