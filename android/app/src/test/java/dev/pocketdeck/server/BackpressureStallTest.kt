package dev.pocketdeck.server

import dev.pocketdeck.proto.FrameReader
import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * B2: one window opening must not stop every other stream.
 *
 * The reported shape: a backpressured drop calls into the display
 * (`requestKeyframe` / `onBackpressure`) while another window's `open` is still
 * running (encoder + VD + probe, seconds on a real phone). The old code made
 * that call with the send queue's lock held, so the writer thread could not
 * take anything off the queue: every stream and every JSON reply stopped until
 * the open finished (the field log: 21 s of X frozen, resuming 90 ms before
 * WhatsApp's first frame).
 *
 * The fake display blocks its `open` on a latch and its keyframe request waits
 * for the same open to finish, exactly the contention the real display had.
 */
class BackpressureStallTest {

    private lateinit var platform: FakePlatform
    private lateinit var serverSocket: ServerSocket
    private lateinit var client: Socket
    private lateinit var reader: FrameReader

    @Volatile private var session: Session? = null
    private var clock = 1_000L

    @Before
    fun setUp() {
        platform = FakePlatform()
        connect()
    }

    @After
    fun tearDown() {
        runCatching { session?.close() }
        runCatching { client.close() }
        runCatching { serverSocket.close() }
    }

    private fun connect() {
        serverSocket = ServerSocket(0, 8, InetAddress.getLoopbackAddress())
        client = Socket(InetAddress.getLoopbackAddress(), serverSocket.localPort)
        client.soTimeout = 5_000
        reader = FrameReader(client.getInputStream())
        val accept = Thread {
            val socket = serverSocket.accept()
            socket.tcpNoDelay = true
            val sess = Session(
                socket = socket,
                display = platform,
                catalog = platform,
                launcher = platform,
                injector = platform,
                power = platform,
                device = platform,
                store = platform,
                callback = platform,
                titleObserver = { null },
                taskPresence = { false },
                clipboard = platform,
                packages = null,
                now = { clock++ },
                log = {},
                handshakeTimeoutMs = 3_000,
                pairDecisionTimeoutMs = 5_000,
                exitPollIntervalMs = 50,
                // Three small frames reach the cap: the third is a drop.
                maxDeltaBytesPerStream = 32,
                tlsView = TlsV2Fixture.view,
                gateProvider = { GateSettings(true, true) },
            )
            session = sess
            sess.run()
        }
        accept.isDaemon = true
        accept.start()
    }

    private fun send(obj: Map<String, Any?>) {
        val out = client.getOutputStream()
        out.write(Frames.encodeJson(0, Json.encode(obj)))
        out.flush()
    }

    /** Reads until the message type arrives (the handshake sends a few first). */
    private fun readUntil(t: String, timeoutMs: Int = 3_000): Map<String, Any?> {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            val frame = readPathFrame(reader) ?: error("connection closed while waiting for '$t'")
            val msg = pathJson(frame)
            if (msg["t"] == t) return msg
        }
        error("never received '$t'")
    }

    private fun authenticate() {
        platform.clients.add(PairedClient("c1", "MacBook", TlsV2Fixture.MAC_FP_HEX))
        send(mapOf("t" to "hello", "v" to 4, "path" to "a1b2c3d4", "clientId" to "c1", "name" to "MacBook"))
        readUntil("welcome", timeoutMs = 5_000)
        assertTrue("the session is ready", session!!.isReady)
    }

    @Test
    fun aSlowWindowOpenDoesNotStopTheSessionsOtherOutput() {
        authenticate()
        val openEntered = CountDownLatch(1)
        val openRelease = CountDownLatch(1)
        val keyframeWaiting = CountDownLatch(1)
        // Stream 1's open is the slow one (the WhatsApp window in the field
        // log); stream 2's display call waits for it.
        platform.onOpen = { stream ->
            if (stream == 1) {
                openEntered.countDown()
                openRelease.await(10, TimeUnit.SECONDS)
            }
        }
        platform.onKeyframeRequest = { stream ->
            if (stream == 2) {
                keyframeWaiting.countDown()
                openRelease.await(10, TimeUnit.SECONDS)
            }
        }

        // The Mac opens window 1: the reader thread is now inside the display.
        send(mapOf("t" to "window.open", "stream" to 1, "w" to 640, "h" to 360,
                   "dpi" to 160, "pkg" to "com.example"))
        assertTrue("the slow open started", openEntered.await(2, TimeUnit.SECONDS))

        // Stream 2's encoder fills its delta budget: the drop callback runs and
        // waits for the display, which is busy with window 1.
        val encoder = Thread {
            session!!.onFrame(2, 0L, false, ByteArray(16))
            session!!.onFrame(2, 16_000L, false, ByteArray(16))
            session!!.onFrame(2, 32_000L, false, ByteArray(16))
        }
        encoder.isDaemon = true
        encoder.start()
        assertTrue("the drop callback reached the busy display",
                   keyframeWaiting.await(2, TimeUnit.SECONDS))

        // The session must still answer: a share is one JSON message.
        val share = Thread { session!!.shareText("still here") }
        share.isDaemon = true
        share.start()
        val msg = try {
            readUntil("share.text", timeoutMs = 2_000)
        } finally {
            openRelease.countDown()
            runCatching { encoder.join(2_000) }
            runCatching { share.join(2_000) }
        }
        assertEquals("still here", msg["text"])
    }
}
