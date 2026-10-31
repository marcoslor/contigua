package dev.pocketdeck.server

import dev.pocketdeck.proto.Frame
import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.Json
import dev.pocketdeck.proto.PathCodec
import dev.pocketdeck.proto.PathKind
import java.io.ByteArrayInputStream
import java.io.OutputStream
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * R-2: a blocking socket write on one path must never hold the hub's lock.
 * With the write under the lock, every reader, the ticker, `detach` and
 * teardown froze until TCP's 40 s timeout.
 */
class PathHubWriteTest {
    private val hub = PathHub()

    /** A socket whose writes park until the test releases them. */
    private class ParkedSocket(private val out: OutputStream) : Socket() {
        override fun getOutputStream(): OutputStream = out
        override fun getInputStream() = ByteArrayInputStream(ByteArray(0))
        override fun shutdownInput() = Unit
        override fun shutdownOutput() = Unit
        override fun close() = Unit
    }

    private class ParkingStream : OutputStream() {
        val entered = CountDownLatch(1)
        val written = CountDownLatch(3)
        val chunks = java.util.Collections.synchronizedList(mutableListOf<ByteArray>())
        private val lock = Object()
        private var released = false

        override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)

        override fun write(b: ByteArray, off: Int, len: Int) {
            entered.countDown()
            synchronized(lock) {
                while (!released) lock.wait()
            }
            chunks.add(b.copyOfRange(off, off + len))
            written.countDown()
        }

        fun release() = synchronized(lock) {
            released = true
            lock.notifyAll()
        }
    }

    private class CollectingStream : OutputStream() {
        val bytes = java.io.ByteArrayOutputStream()
        override fun write(b: Int) {
            synchronized(bytes) { bytes.write(b) }
        }

        override fun write(b: ByteArray, off: Int, len: Int) {
            synchronized(bytes) { bytes.write(b, off, len) }
        }
    }

    private fun transport(id: String, out: OutputStream): PathHub.Transport =
        PathHub.Transport(id, ParkedSocket(out), ParkedSocket(out), PathKind.LAN)

    private fun completesWithin(what: String, ms: Long = 1_000, block: () -> Unit) {
        val thread = Thread(block, "test-$what").apply { isDaemon = true }
        thread.start()
        thread.join(ms)
        assertFalse("$what did not finish within $ms ms", thread.isAlive)
    }

    private val parking = ParkingStream()

    @After
    fun close() {
        parking.release()
        runCatching { hub.closeAll() }
    }

    @Test
    fun controlJumpsAheadOfQueuedBulk() {
        hub.start(transport("aaaa0001", parking))
        val sender = Thread {
            hub.send(Frames.encodeJson(0, Json.encode(mapOf("t" to "window.content", "stream" to 1))))
        }.apply { isDaemon = true }
        sender.start()
        assertTrue("the write never started", parking.entered.await(2, TimeUnit.SECONDS))

        // One lossy video frame waits behind the parked write; the ping's pong
        // is control and must go first (D-2's priority lane).
        hub.send(Frames.encode(Frames.TYPE_VIDEO_FRAME, 0, byteArrayOf(1, 2, 3)))
        hub.receive(
            "aaaa0001",
            Frame(
                Frames.TYPE_JSON, 0,
                Json.encode(mapOf("t" to "path.ping", "path" to "aaaa0001", "ts" to 0)).toByteArray(),
            ),
        )
        parking.release()
        assertTrue("the three writes did not finish", parking.written.await(2, TimeUnit.SECONDS))
        assertEquals("the pong is not second", Frames.TYPE_JSON, parking.chunks[1][4].toInt() and 0xFF)
        assertEquals("the video frame is not third", Frames.TYPE_VIDEO_FRAME, parking.chunks[2][4].toInt() and 0xFF)
    }

    @Test
    fun aParkedWriteOnOnePathLeavesTheHubUsable() {        val other = CollectingStream()
        hub.start(transport("aaaa0001", parking))
        assertTrue(hub.attach(transport("bbbb0002", other)))

        // A reliable JSON frame on the current path: the hub holds its lock
        // across this write today, and the writer parks inside write().
        val sender = Thread {
            hub.send(Frames.encodeJson(0, Json.encode(mapOf("t" to "state", "locked" to true))))
        }.apply { isDaemon = true }
        sender.start()
        assertTrue("the write never started", parking.entered.await(2, TimeUnit.SECONDS))

        completesWithin("ACK on the other path") {
            val payload = ByteArray(8).also { PathCodec.putLong(it, 0, 1) }
            hub.receive("bbbb0002", Frame(PathCodec.TYPE_ACK, 0, payload))
        }
        completesWithin("pong on the other path") {
            hub.receive(
                "bbbb0002",
                Frame(
                    Frames.TYPE_JSON, 0,
                    Json.encode(mapOf("t" to "path.ping", "path" to "aaaa0001", "ts" to 0)).toByteArray(),
                ),
            )
        }
        completesWithin("detach") { hub.detach("bbbb0002") }
        completesWithin("attach") { hub.attach(transport("cccc0003", CollectingStream())) }
        completesWithin("hasPath") { assertTrue(hub.hasPath("cccc0003")) }
        completesWithin("closeAll") { hub.closeAll() }
    }
}
