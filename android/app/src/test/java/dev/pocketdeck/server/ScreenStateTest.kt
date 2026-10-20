package dev.pocketdeck.server

import android.view.Display
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * `state.screen` (docs/PROTOCOL.md "Phone screen"): display 0's power state.
 * Doze and doze-suspend count as off — an Always-On Display is not a live
 * picture — and an unknown display state falls back to the interactive flag.
 */
class ScreenStateTest {

    @Test
    fun `an on display is on`() {
        assertEquals(ScreenState.ON, ScreenState.of(Display.STATE_ON, interactive = true))
    }

    @Test
    fun `an off display is off`() {
        assertEquals(ScreenState.OFF, ScreenState.of(Display.STATE_OFF, interactive = false))
    }

    @Test
    fun `doze and doze suspend are off`() {
        for (state in listOf(Display.STATE_DOZE, Display.STATE_DOZE_SUSPEND, Display.STATE_ON_SUSPEND)) {
            assertEquals("display state $state", ScreenState.OFF, ScreenState.of(state, interactive = false))
        }
    }

    @Test
    fun `an unknown display state follows the interactive flag`() {
        assertEquals(ScreenState.ON, ScreenState.of(Display.STATE_UNKNOWN, interactive = true))
        assertEquals(ScreenState.OFF, ScreenState.of(Display.STATE_UNKNOWN, interactive = false))
    }

    @Test
    fun `the wire names are on and off`() {
        assertEquals("on", ScreenState.ON.wire)
        assertEquals("off", ScreenState.OFF.wire)
    }
}
