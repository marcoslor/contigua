package dev.pocketdeck.server

import dev.pocketdeck.proto.Frame
import dev.pocketdeck.proto.FrameReader
import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.Json
import dev.pocketdeck.proto.PathCodec
import dev.pocketdeck.proto.PathKind
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * R-15: a coalesced ACK has a 10 ms timer, not only a next-frame trigger.
 * The last frames of a burst used to stay unacked until the 15 s ping.
 */
class PathAckTest {
    private var clock = 10_000L
    private val hub = PathHub(now = { clock })
    private val sockets = mutableListOf<Socket>()

    private fun path(id: String): Pair<PathHub.Transport, FrameReader> {
        val server = ServerSocket(0)
        val client = Socket("127.0.0.1", server.localPort)
        val accepted = server.accept()
        server.close()
        client.soTimeout = 300
        sockets += client
        sockets += accepted
        return PathHub.Transport(id, accepted, accepted, PathKind.LAN) to FrameReader(client.getInputStream())
    }

    private fun reliable(seq: Long): Frame {
        val inner = Frame(Frames.TYPE_JSON, 0, Json.encode(mapOf("t" to "ping", "ts" to seq)).toByteArray())
        val wrapped = PathCodec.encodeReliable(seq, inner)
        return Frame(PathCodec.TYPE_RELIABLE, 0, wrapped.copyOfRange(9, wrapped.size))
    }

    /** The next ACK value, or null when none arrives within the timeout. */
    private fun nextAck(reader: FrameReader): Long? = try {
        val frame = reader.readFrame() ?: null
        if (frame != null && frame.type == PathCodec.TYPE_ACK) PathCodec.decodeAck(frame) else null
    } catch (e: SocketTimeoutException) {
        null
    }

    @After
    fun close() {
        hub.closeAll()
        for (socket in sockets) runCatching { socket.close() }
    }

    @Test
    fun aBurstsLastFramesAreAckedAfterTenMilliseconds() {
        val (transport, reader) = path("aaaa0001")
        hub.start(transport)
        hub.receive("aaaa0001", reliable(1))
        hub.ackHandled("aaaa0001")
        assertEquals(2L, nextAck(reader))

        // One more frame within the same 10 ms window: coalesced, not sent.
        hub.receive("aaaa0001", reliable(2))
        hub.ackHandled("aaaa0001")
        assertNull("the ack should wait for the timer", nextAck(reader))

        clock += PathHub.ACK_MS
        hub.flushAck()
        assertEquals(3L, nextAck(reader))
    }
}
