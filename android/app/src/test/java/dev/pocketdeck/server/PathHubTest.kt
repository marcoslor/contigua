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
