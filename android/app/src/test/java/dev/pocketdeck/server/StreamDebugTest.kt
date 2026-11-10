package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The still-screen rig's property is a debug build's explicit opt-in; an
 * absent property, or a release build, keeps the 500 ms heartbeat.
 */
class StreamDebugTest {

    @Test
    fun offWhenThePropertyIsAbsent() {
        assertEquals(false, StreamDebug.ignoreRepeatFrame(debug = true, property = null))
        assertEquals(false, StreamDebug.ignoreRepeatFrame(debug = true, property = ""))
        assertEquals(false, StreamDebug.ignoreRepeatFrame(debug = true, property = "0"))
        assertEquals(false, StreamDebug.ignoreRepeatFrame(debug = true, property = "true"))
    }

    @Test
    fun onOnlyForTheExactDebugOptIn() {
        assertEquals(true, StreamDebug.ignoreRepeatFrame(debug = true, property = "1"))
        assertEquals(false, StreamDebug.ignoreRepeatFrame(debug = false, property = "1"))
    }

    @Test
    fun theFreezeHookIsTheSameDebugOptIn() {
        assertEquals(true, StreamDebug.freezeDrain(debug = true, property = "1"))
        assertEquals(false, StreamDebug.freezeDrain(debug = false, property = "1"))
        assertEquals(false, StreamDebug.freezeDrain(debug = true, property = null))
    }

    @Test
    fun theRateSwitchesDefaultOnAndOnlyZeroTurnsThemOff() {
        for (property in listOf(null, "", "1", "true", "off")) {
            assertEquals(true, StreamDebug.enabled(debug = true, property = property))
        }
        assertEquals(false, StreamDebug.enabled(debug = true, property = "0"))
        assertEquals("a release build ignores the property", true,
            StreamDebug.enabled(debug = false, property = "0"))
    }
}
