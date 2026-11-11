package app.contigua.app

import org.junit.Assert.assertEquals
import org.junit.Test

class DeviceNameTest {

    private val model = "SM-S936B"

    @Test
    fun `the user-visible name beats the model`() {
        assertEquals("Test Phone", DeviceName.resolve(null, model) { "Test Phone" })
    }

    @Test
    fun `no system name falls back to the model`() {
        assertEquals(model, DeviceName.resolve(null, model) { null })
        assertEquals(model, DeviceName.resolve("", model) { "  " })
    }

    @Test
    fun `a stored name that equals the model is still the stored name`() {
        assertEquals(model, DeviceName.resolve(model, model) { "Galaxy" })
    }

    @Test
    fun `a name the user set in Contigua always wins`() {
        assertEquals("Desk phone", DeviceName.resolve("Desk phone", model) { "Galaxy" })
    }
}
