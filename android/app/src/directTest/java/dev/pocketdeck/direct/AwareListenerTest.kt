package dev.pocketdeck.direct

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The Aware listener (docs/design/direct-link.md §4.2, transport DIRECT-8):
 * `bindSocket` before `bind`, the port the specifier named, one accept loop per
 * publish session, and every accepted socket handed on exactly once.
 */
class AwareListenerTest {

    private class FakeNetwork : AwareNetwork {
        @Volatile var bindCalls = 0
        @Volatile var boundBeforeBind = false

        override fun bindSocket(socket: ServerSocket) {
            bindCalls++
            boundBeforeBind = !socket.isBound
        }
    }

    private fun freePort(): Int = ServerSocket(0).use { it.localPort }

    private fun await(what: String, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 3_000
        while (System.currentTimeMillis() < deadline) {
            if (condition()) return
            Thread.sleep(10)
        }
        assertTrue(what, condition())
    }

    @Test
    fun itBindsTheAwareNetworkBeforeThePortAndAccepts() {
        val network = FakeNetwork()
        val port = freePort()
        val accepted = CopyOnWriteArrayList<Socket>()
        val listener = AwareListener(network, port, { accepted.add(it) })
        assertTrue(listener.start())
        try {
            assertEquals(1, network.bindCalls)
            assertTrue("bindSocket ran while the socket was unbound", network.boundBeforeBind)
            assertEquals(port, listener.port)

            Socket("127.0.0.1", port).use { it.getOutputStream().write(1) }
            await("one connection is handed on") { accepted.size == 1 }
        } finally {
            listener.close()
        }
    }

    @Test
    fun oneLoopAcceptsEveryConnectionOfTheSession() {
        val accepted = CopyOnWriteArrayList<Socket>()
        val port = freePort()
        val listener = AwareListener(FakeNetwork(), port, { accepted.add(it) })
        assertTrue(listener.start())
        try {
            Socket("127.0.0.1", port).use { it.getOutputStream().write(1) }
            Socket("127.0.0.1", port).use { it.getOutputStream().write(2) }
            await("both connections are handed on") { accepted.size == 2 }
        } finally {
            listener.close()
            accepted.forEach { runCatching { it.close() } }
        }
    }

    @Test
    fun startTwiceKeepsOneLoopAndOneBind() {
        val network = FakeNetwork()
        val port = freePort()
        val accepted = CopyOnWriteArrayList<Socket>()
        val listener = AwareListener(network, port, { accepted.add(it) })
        assertTrue(listener.start())
        assertTrue(listener.start())
        try {
            assertEquals(1, network.bindCalls)
            Socket("127.0.0.1", port).use { it.getOutputStream().write(1) }
            await("the one loop accepts") { accepted.size == 1 }
        } finally {
            listener.close()
            accepted.forEach { runCatching { it.close() } }
        }
    }

    @Test
    fun closeStopsTheLoopAndTheListenerPort() {
        val port = freePort()
        val accepted = CopyOnWriteArrayList<Socket>()
        val listener = AwareListener(FakeNetwork(), port, { accepted.add(it) })
        assertTrue(listener.start())
        listener.close()
        assertFalse(listener.isRunning)
        val connected = runCatching {
            Socket().use { it.connect(InetSocketAddress("127.0.0.1", port), 300) }
        }
        assertTrue("a closed listener refuses the port", connected.isFailure)
        assertEquals(0, accepted.size)
    }

    @Test
    fun aBindFailureReportsFalseAndLeavesNothingBehind() {
        val failing = object : AwareNetwork {
            override fun bindSocket(socket: ServerSocket) = throw IllegalStateException("no route")
        }
        val listener = AwareListener(failing, freePort(), {})
        assertFalse(listener.start())
        assertFalse(listener.isRunning)
    }
}
