package dev.pocketdeck.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The media rules of "Media part 2" (docs/design/notify.md): which session is
 * chosen, the sessions list, the seek/volume clamps and the command parse.
 * Pure: no Android, no titles anywhere.
 */
class MediaControlTest {

    private fun info(key: String, pkg: String = "com.example.player", app: String = "Player", playing: Boolean = true) =
        MediaSessionInfo(key = key, pkg = pkg, app = app, playing = playing)

    @Test
    fun `the mac's pick wins while it is active, else the first session`() {
        assertEquals("s2", MediaControl.chooseKey(listOf("s1", "s2"), "s2"))
        assertEquals("s1", MediaControl.chooseKey(listOf("s1", "s2"), "s9"))
        assertEquals("s1", MediaControl.chooseKey(listOf("s1", "s2"), null))
        assertNull(MediaControl.chooseKey(emptyList(), "s1"))
    }

    @Test
    fun `a malformed preferred key never becomes the chosen one`() {
        assertEquals("s1", MediaControl.chooseKey(listOf("s1"), "../../etc"))
        assertEquals("s1", MediaControl.chooseKey(listOf("s1"), ""))
    }

    @Test
    fun `the sessions list keeps the system's order and drops bad entries`() {
        val wire = MediaControl.sessionsWire(
            listOf(
                info("s1", pkg = "com.one", app = "One"),
                info("s2", pkg = "com.two", app = "", playing = false),
                info("bad key!", pkg = "com.three"),
                info("s3", pkg = "com.four space"),
            ),
            chosen = "s2",
        )
        assertEquals("media.sessions", wire["t"])
        val list = wire["list"] as List<*>
        assertEquals(2, list.size)
        val first = list[0] as Map<*, *>
        assertEquals("s1", first["key"])
        assertEquals("com.one", first["pkg"])
        assertEquals("One", first["app"])
        assertEquals(true, first["playing"])
        val second = list[1] as Map<*, *>
        assertEquals("s2", second["key"])
        // An empty label falls back to the package, never to an empty string.
        assertEquals("com.two", second["app"])
        assertEquals(false, second["playing"])
        assertEquals("s2", wire["chosen"])
    }

    @Test
    fun `the sessions list is capped and never carries an app over the cap`() {
        val many = (1..40).map { info("s$it", pkg = "com.p$it", app = "a".repeat(200)) }
        val list = MediaControl.sessionsWire(many, "s1")["list"] as List<*>
        assertEquals(MediaControl.MAX_SESSIONS, list.size)
        assertEquals(MediaControl.MAX_APP, ((list[0] as Map<*, *>)["app"] as String).length)
    }

    @Test
    fun `an empty sessions list is a valid message`() {
        val wire = MediaControl.sessionsWire(emptyList(), null)
        assertEquals(emptyList<Any>(), wire["list"])
        assertFalse(wire.containsKey("chosen"))
    }

    @Test
    fun `a seek position is clamped to the track`() {
        assertEquals(30000L, MediaControl.positionClamp(45000, 30000))
        assertEquals(0L, MediaControl.positionClamp(-5, 30000))
        assertEquals(12000L, MediaControl.positionClamp(12000, 30000))
        assertEquals(45000L, MediaControl.positionClamp(45000, null))
        assertEquals(45000L, MediaControl.positionClamp(45000, 0))
    }

    @Test
    fun `a volume level is clamped to the session maximum`() {
        assertEquals(15, MediaControl.levelClamp(15, 15))
        assertEquals(15, MediaControl.levelClamp(99, 15))
        assertEquals(0, MediaControl.levelClamp(-3, 15))
        assertEquals(0, MediaControl.levelClamp(5, null))
        assertEquals(0, MediaControl.levelClamp(5, 0))
    }

    @Test
    fun `only the six actions are commands`() {
        for (action in listOf("play", "pause", "next", "prev", "seek", "volume")) {
            assertEquals(action, MediaControl.commandFromWire(mapOf("action" to action, "positionMs" to 1L, "level" to 1))?.action)
        }
        assertNull(MediaControl.commandFromWire(mapOf("action" to "rewind")))
        assertNull(MediaControl.commandFromWire(emptyMap()))
    }

    @Test
    fun `seek and volume need their value`() {
        assertNull(MediaControl.commandFromWire(mapOf("action" to "seek")))
        assertNull(MediaControl.commandFromWire(mapOf("action" to "volume")))
        val seek = MediaControl.commandFromWire(mapOf("action" to "seek", "positionMs" to 5_000L, "key" to "s2"))!!
        assertEquals(5_000L, seek.positionMs)
        assertEquals("s2", seek.key)
        val volume = MediaControl.commandFromWire(mapOf("action" to "volume", "level" to 7))!!
        assertEquals(7, volume.level)
        assertNull(volume.key)
    }

    @Test
    fun `an absurd position or level is bounded before it is used`() {
        val seek = MediaControl.commandFromWire(mapOf("action" to "seek", "positionMs" to 9_999_999_999L))!!
        assertEquals(MediaControl.MAX_POSITION_MS, seek.positionMs)
        val volume = MediaControl.commandFromWire(mapOf("action" to "volume", "level" to 10_000))!!
        assertEquals(MediaControl.MAX_LEVEL, volume.level)
    }

    @Test
    fun `a key that is not a token is dropped from a command`() {
        val command = MediaControl.commandFromWire(mapOf("action" to "play", "key" to "not a key"))!!
        assertNull(command.key)
        assertTrue(command.action == "play")
    }
}
