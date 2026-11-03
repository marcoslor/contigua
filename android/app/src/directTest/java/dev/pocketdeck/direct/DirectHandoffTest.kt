package dev.pocketdeck.direct

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The process split's app half (docs/design/direct-link.md §4.5, transport
 * DIRECT-17): an accepted Aware socket goes to the shell as a descriptor, the
 * app closes its own copy, and a descriptor the shell cannot wrap falls back to
 * the byte bridge with one `path-bridge` line.
 */
class DirectHandoffTest {

    @Test
    fun aWrappedDescriptorIsHandedOverOnceAndTheAppsCopyClosed() {
        val handed = CopyOnWriteArrayList<Socket>()
        val bridged = CopyOnWriteArrayList<Socket>()
        val closed = CopyOnWriteArrayList<Socket>()
        val log = mutableListOf<String>()
        val handoff = DirectPathHandoff(
            handOver = { handed.add(it); true },
            bridge = { bridged.add(it); true },
            close = { closed.add(it) },
            log = { log.add(it) },
        )
        val socket = Socket()
        assertTrue(handoff.deliver(socket))
        assertEquals(listOf(socket), handed)
        assertTrue("the app's copy is closed after the fd is taken", closed.contains(socket))
        assertTrue(bridged.isEmpty())
        assertTrue(log.isEmpty())
    }

    @Test
    fun aWrapFailureChoosesTheBridgeAndLogsItOnce() {
        val bridged = CopyOnWriteArrayList<Socket>()
        val log = mutableListOf<String>()
        val handoff = DirectPathHandoff(
            handOver = { false },
            bridge = { bridged.add(it); true },
            close = {},
            log = { log.add(it) },
        )
        assertTrue(handoff.deliver(Socket()))
        assertTrue(handoff.deliver(Socket()))
        assertEquals(2, bridged.size)
        assertEquals(listOf("path-bridge"), log)
    }

    @Test
    fun anExceptionFromTheShellFallsBackToTheBridge() {
        val log = mutableListOf<String>()
        val handoff = DirectPathHandoff(
            handOver = { throw IllegalStateException("binder died") },
            bridge = { true },
            close = {},
            log = { log.add(it) },
        )
        assertTrue(handoff.deliver(Socket()))
        assertEquals(listOf("path-bridge"), log)
    }

    @Test
    fun neitherPathClosesTheSocketAndReportsFailure() {
        val closed = CopyOnWriteArrayList<Socket>()
        val handoff = DirectPathHandoff(
            handOver = { false },
            bridge = { false },
            close = { closed.add(it) },
            log = {},
        )
        val socket = Socket()
        assertFalse(handoff.deliver(socket))
        assertEquals(listOf(socket), closed)
    }
}
