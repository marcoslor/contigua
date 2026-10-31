package dev.pocketdeck.server

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
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * D-1: pings follow the power policy. One path is never pinged; two or more
 * are pinged every 2 s while the screen is on or a transfer runs, else every
 * 15 s; a joined path is pinged at once; the ticker asks for its next deadline.
 */
class PathPingTest {
    private var clock = 0L
    private val hub = PathHub(now = { clock })
    private val sockets = mutableListOf<Socket>()

    private class Path(val transport: PathHub.Transport, val reader: FrameReader, val socket: Socket)

    private fun path(id: String): Path {
        val server = ServerSocket(0)
        val client = Socket("127.0.0.1", server.localPort)
        val accepted = server.accept()
        server.close()
        client.soTimeout = 300
        sockets += client
        sockets += accepted
        return Path(PathHub.Transport(id, accepted, accepted, PathKind.LAN), FrameReader(client.getInputStream()), client)
    }

    @After
    fun close() {
        hub.closeAll()
        for (socket in sockets) runCatching { socket.close() }
    }

    /** The path id of the next ping, or null when none within the timeout. */
    private fun nextPing(reader: FrameReader): String? {
        try {
            while (true) {
                val frame = reader.readFrame() ?: return null
                if (frame.type != Frames.TYPE_JSON) continue
                val obj = Json.parseObject(String(frame.payload))
                if (obj["t"] == "path.ping") return obj["path"] as String
            }
        } catch (e: SocketTimeoutException) {
            return null
        }
    }

    private fun noPing(reader: FrameReader) = assertNull("unexpected ping", nextPing(reader))

    private fun pong(id: String) {
        hub.receive(
            id,
            dev.pocketdeck.proto.Frame(
                Frames.TYPE_JSON, 0,
                Json.encode(mapOf("t" to "path.pong", "path" to id, "ts" to clock)).toByteArray(),
            ),
        )
    }

    @Test
    fun onePathIsNeverPinged() {
        val a = path("aaaa0001")
        hub.start(a.transport)
        clock = 100_000
        hub.pingAll(active = true)
        noPing(a.reader)
        assertEquals(Long.MAX_VALUE, hub.nextDeadline(active = true))
    }

    @Test
    fun twoPathsPingEveryTwoSecondsActiveAndFifteenIdle() {
        val a = path("aaaa0001")
        val b = path("bbbb0002")
        hub.start(a.transport)
        hub.attach(b.transport)
        clock = 10_000
        hub.pingAll(active = true)
        assertEquals("aaaa0001", nextPing(a.reader))
        assertEquals("bbbb0002", nextPing(b.reader))

        clock = 11_999
        hub.pingAll(active = true)
        noPing(a.reader)
        noPing(b.reader)

        clock = 12_000
        hub.pingAll(active = true)
        assertEquals("aaaa0001", nextPing(a.reader))
        assertEquals("bbbb0002", nextPing(b.reader))

        // Screen off, nothing transferring: 15 s.
        clock = 26_999
        hub.pingAll(active = false)
        noPing(a.reader)
        noPing(b.reader)

        clock = 27_000
        hub.pingAll(active = false)
        assertEquals("aaaa0001", nextPing(a.reader))
        assertEquals("bbbb0002", nextPing(b.reader))
    }

    @Test
    fun aJoinedPathIsPingedAtOnce() {
        val a = path("aaaa0001")
        val b = path("bbbb0002")
        hub.start(a.transport)
        clock = 5_000
        hub.attach(b.transport)
        hub.pingPath("bbbb0002")
        assertEquals("bbbb0002", nextPing(b.reader))
        pong("bbbb0002")
        noPing(a.reader)
        assertEquals(7_000L, hub.nextDeadline(active = true))
    }

    @Test
    fun theNextDeadlineIsThePolicyIntervalNotAFixedPoll() {
        val a = path("aaaa0001")
        val b = path("bbbb0002")
        hub.start(a.transport)
        hub.attach(b.transport)
        clock = 10_000
        hub.pingAll(active = true)
        nextPing(a.reader)
        nextPing(b.reader)
        pong("aaaa0001")
        pong("bbbb0002")
        assertEquals(12_000L, hub.nextDeadline(active = true))
        assertEquals(25_000L, hub.nextDeadline(active = false))
        // No path timers at all: nothing to wake for.
        hub.detach("bbbb0002")
        hub.detach("aaaa0001")
        assertEquals(Long.MAX_VALUE, hub.nextDeadline(active = true))
        assertFalse(hub.pathCount > 0)
    }
}
