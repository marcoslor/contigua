package dev.pocketdeck.server

import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * The clipboard port's stop contract (ISS-13): stopping with nothing listening,
 * or stopping more than once, is safe. The shared port has one live listener,
 * and only the session that installed it may stop it.
 */
class ClipboardOwnerTest {

    @Test
    fun `stopping with no listener and stopping twice are safe`() {
        val port = FakePlatform()
        port.stop() // no listener at all

        port.listen { }
        port.stop()
        port.stop() // the second stop has nothing left to stop

        assertFalse("the listener survived its stop", port.clipListening)
    }
}
