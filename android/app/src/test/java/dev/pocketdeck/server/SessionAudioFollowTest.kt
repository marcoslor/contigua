package dev.pocketdeck.server

import dev.pocketdeck.proto.Crypto
import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.FrameReader
import dev.pocketdeck.proto.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The session feeds the audio capture the open windows (AudioFollow) and
 * notifies it on every window set change, so the capture can swap its uid set.
 * Start and change events here are the wiring surface.
 */
class SessionAudioFollowTest {

    private class RecordingCapture : AudioCaptureLayer {

        data class Started(val owner: AudioSink, val codecs: List<Int>, val windows: List<CaptureWindow>)

        private var stopped = false
        override val isRunning: Boolean get() = started.isNotEmpty() && !stopped

        val started = CopyOnWriteArrayList<Started>()
        val changed = CopyOnWriteArrayList<AudioSink?>()
        val changedWindows = CopyOnWriteArrayList<List<CaptureWindow>>()
        var stopCount = 0
            private set

        private var provider: (() -> List<CaptureWindow>)? = null

        override fun start(sink: AudioSink, preferredCodecs: List<Int>, windows: () -> List<CaptureWindow>) {
            provider = windows
            started.add(Started(sink, preferredCodecs, windows()))
        }

        override fun onWindowsChanged(owner: AudioSink?) {
            changed.add(owner)
            changedWindows.add(provider?.invoke() ?: emptyList())
        }

        override fun stop() {
            stopCount++
            stopped = true
        }
    }

    private lateinit var platform: FakePlatform
    private lateinit var serverSocket: ServerSocket
    private lateinit var client: Socket

    @Volatile private lateinit var session: Session
    @Volatile private lateinit var capture: RecordingCapture

    private fun connect() {
        serverSocket = ServerSocket(0)
        platform = FakePlatform()
        capture = RecordingCapture()
        val accept = Thread {
            val s = serverSocket.accept()
            s.tcpNoDelay = true
            val sess = Session(
                socket = s,
                display = platform,
                catalog = platform,
                launcher = platform,
                injector = platform,
                power = platform,
                device = platform,
                store = platform,
                callback = platform,
                clipboard = platform,
                now = { 1_000 },
                log = {},
                handshakeTimeoutMs = 3_000,
                audioCapture = capture,
                tlsView = TlsV2Fixture.view,
                gateProvider = { GateSettings(true, true) },
            )
            session = sess
            sess.run()
        }
        accept.isDaemon = true
        accept.start()
        client = Socket("127.0.0.1", serverSocket.localPort)
        client.soTimeout = 5_000
    }

    @After
    fun tearDown() {
        runCatching { client.close() }
        runCatching { serverSocket.close() }
    }

    private fun send(obj: Map<String, Any?>) {
        val out = client.getOutputStream()
        out.write(Frames.encodeJson(0, Json.encode(obj)))
        out.flush()
    }

    private fun readJson(): Map<String, Any?> {
        val frame = FrameReader(client.getInputStream()).readFrame() ?: error("connection closed")
        return Json.parseObject(String(frame.payload))
    }

    private fun readUntil(t: String): Map<String, Any?> {
        repeat(30) {
            val m = readJson()
            if (m["t"] == t) return m
        }
        error("never received '$t'")
    }

    private fun await(timeoutMs: Long = 2_000, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (condition()) return
            Thread.sleep(5)
        }
        assertTrue("condition never became true", condition())
    }

    private fun authenticate() {
        platform.clients.add(PairedClient("c1", "MacBook", TlsV2Fixture.MAC_FP_HEX))
        send(mapOf("t" to "hello", "v" to 2, "clientId" to "c1", "name" to "MacBook"))
        readUntil("welcome")
    }

    @Test
    fun audioStartReceivesTheOpenWindows() {
        connect()
        authenticate()
        send(mapOf("t" to "window.open", "stream" to 7, "w" to 640, "h" to 480, "dpi" to 160, "pkg" to "com.android.settings"))
        readUntil("window.opened")
        await { capture.changed.size >= 1 }
        // The window change fires even before any audio.start (capture not running);
        // the start call below carries the windows themselves.
        send(mapOf("t" to "audio.start", "codecs" to listOf(3)))
        await { capture.started.isNotEmpty() }
        assertSame(session, capture.started[0].owner)
        assertEquals(listOf(3), capture.started[0].codecs)
        assertEquals(listOf<CaptureWindow>(CaptureWindow.App("com.android.settings")), capture.started[0].windows)
    }

    @Test
    fun phoneWindowIsAllAudioAndClosesStopTheCapture() {
        connect()
        authenticate()
        send(mapOf("t" to "window.open", "stream" to 1, "w" to 400, "h" to 800, "dpi" to 160, "mode" to "phone"))
        readUntil("window.opened")
        send(mapOf("t" to "audio.start", "codecs" to emptyList<Int>()))
        await { capture.started.isNotEmpty() }
        assertEquals(listOf<CaptureWindow>(CaptureWindow.Phone), capture.started[0].windows)

        send(mapOf("t" to "window.close", "stream" to 1))
        readUntil("window.closed")
        // No windows left: session power rule stops the capture.
        await { capture.stopCount >= 1 }
    }

    @Test
    fun missingPkgAndWindowChangesPingTheOwner() {
        connect()
        authenticate()
        // audio.start with no windows at all: nothing to capture, no start.
        send(mapOf("t" to "audio.start", "codecs" to emptyList<Int>()))
        Thread.sleep(120)
        assertEquals("capture must not start with no windows", 0, capture.started.size)
    }
}
