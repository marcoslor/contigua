package dev.pocketdeck.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The debug camera-setting receiver's argument on the JVM (K1): the rig sends
 * `on`/`off`, and nothing else may flip a privacy setting. Pinning this here
 * keeps a typo from costing an emulator boot.
 */
class CameraDebugArgsTest {

    @Test
    fun `on and off parse`() {
        assertEquals(true, CameraDebugArgs.parse("on"))
        assertEquals(false, CameraDebugArgs.parse("off"))
    }

    @Test
    fun `case and surrounding whitespace are tolerated`() {
        assertEquals(true, CameraDebugArgs.parse(" ON "))
        assertEquals(false, CameraDebugArgs.parse("\tOff\n"))
    }

    @Test
    fun `missing or unknown values are refused`() {
        assertNull(CameraDebugArgs.parse(null))
        assertNull(CameraDebugArgs.parse(""))
        assertNull(CameraDebugArgs.parse("  "))
        assertNull(CameraDebugArgs.parse("true"))
        assertNull(CameraDebugArgs.parse("1"))
        assertNull(CameraDebugArgs.parse("on off"))
        assertNull(CameraDebugArgs.parse("o"))
    }
}
