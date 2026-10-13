package dev.pocketdeck.app

import org.junit.Assert.assertEquals
import org.junit.Test

class DeviceNameTest {

    private val model = "SM-S936B"

    @Test
    fun `the user-visible name beats the model`() {
        assertEquals("Marcos's S25+", DeviceName.resolve(null, model) { "Marcos's S25+" })
    }

    @Test
    fun `no system name falls back to the model`() {
        assertEquals(model, DeviceName.resolve(null, model) { null })
        assertEquals(model, DeviceName.resolve("", model) { "  " })
    }

    @Test
    fun `a name cached from an old build that is just the model is replaced`() {
        assertEquals("Galaxy", DeviceName.resolve(model, model) { "Galaxy" })
    }

    @Test
    fun `a name the user set in PocketDeck always wins`() {
        assertEquals("Desk phone", DeviceName.resolve("Desk phone", model) { "Galaxy" })
    }
}
