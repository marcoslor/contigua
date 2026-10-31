package dev.pocketdeck.server

import dev.pocketdeck.proto.Frame
import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.Json
import dev.pocketdeck.proto.PathCodec
import dev.pocketdeck.proto.PathKind
import java.net.ServerSocket
import java.net.Socket
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** docs/PROTOCOL.md "Paths": the marker travels reliable, so the hub must
 * recognise the inner path.switch instead of handing it to the session. */
class PathHubTest {
    private val sockets = mutableListOf<Socket>()
    private val hub = PathHub()

    private fun pair(): Socket {
        val server = ServerSocket(0)
        val client = Socket("127.0.0.1", server.localPort)
        val accepted = server.accept()
        server.close()
        sockets += client
        sockets += accepted
        return accepted
    }

    private fun transport(id: String): PathHub.Transport {
        val socket = pair()
        return PathHub.Transport(id, socket, socket, PathKind.LAN)
    }

    @After
    fun close() {
        hub.closeAll()
        for (socket in sockets) runCatching { socket.close() }
    }

    @Test
    fun aPongLossWhileThePathStillReceivesIsOnlyASample() {
        var clock = 3_000L
        val hub = PathHub(now = { clock })
        hub.start(transport("aaaa0001"))
        assertTrue(hub.attach(transport("bbbb0002")))
        hub.pingAll(active = true)
        // A is still delivering a frame 1.5 s after its ping; B is silent.
        clock = 4_000
        hub.receive("aaaa0001", Frame(PathCodec.TYPE_ACK, 0, ByteArray(8)))
        clock = 4_600
        val losses = hub.pongLosses().associateBy { it.path }
        assertTrue("A delivered bytes: its lost pong is a sample", losses.getValue("aaaa0001").alive)
        assertFalse("B delivered nothing: its lost pong fails it", losses.getValue("bbbb0002").alive)
    }

    @Test
    fun detachClosesTheSocketAndForgetsThePath() {
        val t = transport("aaaa0001")
        hub.start(t)
        assertTrue(hub.detach("aaaa0001"))
        assertTrue(t.closed)
        assertFalse(hub.hasPath("aaaa0001"))
    }

    @Test
    fun aWrappedSwitchMarkerIsThePeersSwitch() {
        hub.start(transport("aaaa0001"))
        assertTrue(hub.attach(transport("bbbb0002")))
        val inner = Frame(
            Frames.TYPE_JSON, 0,
            Json.encode(mapOf("t" to "path.switch", "path" to "bbbb0002", "seq" to 4))
                .toByteArray(),
        )
        val wrapped = PathCodec.encodeReliable(1, inner)
        val events = hub.receive("aaaa0001", Frame(PathCodec.TYPE_RELIABLE, 0, wrapped.copyOfRange(9, wrapped.size)))
        assertEquals(1, events.size)
        val event = events[0]
        assertTrue("expected PeerSwitch, got $event", event is PathHub.Event.PeerSwitch)
        event as PathHub.Event.PeerSwitch
        assertEquals("bbbb0002", event.path)
        assertEquals(4L, event.seq)
        assertEquals("aaaa0001", event.arrivedOn)
    }
}
