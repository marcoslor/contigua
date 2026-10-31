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

    private fun reliable(seq: Long): Frame {
        val inner = Frame(Frames.TYPE_JSON, 0, Json.encode(mapOf("t" to "ping", "ts" to seq)).toByteArray())
        val wrapped = PathCodec.encodeReliable(seq, inner)
        return Frame(PathCodec.TYPE_RELIABLE, 0, wrapped.copyOfRange(9, wrapped.size))
    }

    @Test
    fun aFullWindowWithTheGapOnTheSamePathNeverStopsThatReader() {
        hub.start(transport("aaaa0001"))
        for (seq in 2L..65L) {
            val events = hub.receive("aaaa0001", reliable(seq))
            assertTrue("seq $seq should buffer, got $events", events.isEmpty())
        }
        val pressure = hub.receive("aaaa0001", reliable(66)).filterIsInstance<PathHub.Event.Backpressure>()
        assertEquals(1, pressure.size)
        assertFalse("the gap is this path's own stream: never pause it", pressure[0].stop)
        assertEquals("aaaa0001", pressure[0].path)

        // The gap arrives later on the same path: it fills and the held frame
        // can be retried, so the read never deadlocks.
        val delivered = hub.receive("aaaa0001", reliable(1)).filterIsInstance<PathHub.Event.Deliver>()
        assertEquals(65, delivered.size)
        val retried = hub.receive("aaaa0001", reliable(66)).filterIsInstance<PathHub.Event.Deliver>()
        assertEquals(1, retried.size)
    }

    @Test
    fun aFullWindowAheadOfAnotherPathsGapStopsTheAheadPath() {
        hub.start(transport("aaaa0001"))
        assertTrue(hub.attach(transport("bbbb0002")))
        assertTrue(hub.receive("aaaa0001", reliable(1)).any { it is PathHub.Event.Deliver })
        // The gap is seq 2 (still on A); B runs 3..66, one window ahead.
        for (seq in 3L..66L) hub.receive("bbbb0002", reliable(seq))
        val pressure = hub.receive("bbbb0002", reliable(67)).filterIsInstance<PathHub.Event.Backpressure>()
        assertEquals(1, pressure.size)
        assertTrue("another path holds the gap: pause the ahead reader", pressure[0].stop)
        assertEquals("bbbb0002", pressure[0].path)
        // The other path fills the gap and every buffered frame comes out.
        val delivered = hub.receive("aaaa0001", reliable(2)).filterIsInstance<PathHub.Event.Deliver>()
        assertEquals(65, delivered.size)
    }

    @Test
    fun aReliableFrameWhoseOuterStreamDiffersIsAProtocolError() {
        hub.start(transport("aaaa0001"))
        val inner = Frame(Frames.TYPE_JSON, 0, Json.encode(mapOf("t" to "ping", "ts" to 1)).toByteArray())
        val wrapped = PathCodec.encodeReliable(1, inner)
        // The outer header names stream 9; the wrapper's own stream is 0.
        val outer = Frame(PathCodec.TYPE_RELIABLE, 9, wrapped.copyOfRange(9, wrapped.size))
        assertEquals(listOf(PathHub.Event.ProtocolError), hub.receive("aaaa0001", outer))
    }

    /**
     * E-6/RR-6: a failover wedged when the replay was full: the marker waited
     * for credit only the replay could earn, and the replay ran after it. The
     * replay goes first and the marker bypasses credit on the priority lane.
     */
    @Test
    fun aSwitchMarkerAndTheReplayGoOutWithFullCredit() {
        hub.start(transport("aaaa0001"))
        // The new path's socket, so what its writer puts out can be read back.
        val server = ServerSocket(0)
        val client = Socket("127.0.0.1", server.localPort)
        val accepted = server.accept()
        server.close()
        client.soTimeout = 3_000
        sockets += client
        sockets += accepted
        assertTrue(hub.attach(PathHub.Transport("bbbb0002", accepted, accepted, PathKind.LAN)))

        // Fill the replay to its 16 MiB cap; the peer ACKs nothing.
        val fill = Frames.encodeJson(0, Json.encode(mapOf("t" to "state", "pad" to "x".repeat(60_000))))
        while (hub.canAdmit(fill.size + PathCodec.WRAPPER_BYTES, bulk = false)) hub.send(fill)
        // Top it off so not even a small control frame fits.
        val tiny = Frames.encodeJson(0, "{}")
        while (hub.canAdmit(tiny.size + PathCodec.WRAPPER_BYTES, bulk = false)) hub.send(tiny)
        assertFalse(
            "the replay should be full",
            hub.canAdmit(128, bulk = false),
        )

        val done = java.util.concurrent.atomic.AtomicBoolean(false)
        val thread = Thread {
            hub.followSwitch("bbbb0002", "bbbb0002")
            done.set(true)
        }.apply { isDaemon = true }
        thread.start()
        thread.join(2_000)
        assertTrue("the marker waited for credit on a full replay", done.get())

        val reader = dev.pocketdeck.proto.FrameReader(client.getInputStream())
        var marker = false
        var replayed = 0
        val deadline = System.currentTimeMillis() + 5_000
        while (System.currentTimeMillis() < deadline && !(marker && replayed > 0)) {
            val frame = runCatching { reader.readFrame() }.getOrNull() ?: break
            if (frame.type != PathCodec.TYPE_RELIABLE) continue
            if (pathJson(frame)["t"] == "path.switch") marker = true else replayed++
        }
        assertTrue("the marker never went out", marker)
        assertTrue("the replay never went out", replayed > 0)
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
