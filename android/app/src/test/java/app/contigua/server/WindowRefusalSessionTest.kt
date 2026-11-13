package app.contigua.server

import app.contigua.proto.FrameReader
import app.contigua.proto.Frames
import app.contigua.proto.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList

/**
 * WIN-74: a window display that landed in the panel's display group is
 * refused before anything launches. The stream answers `windows_unsupported`
 * and the session goes on; the Phone Mirror is not an app window and still
 * opens.
 */
class WindowRefusalSessionTest {

    private lateinit var platform: FakePlatform
    private lateinit var serverSocket: ServerSocket
    private lateinit var client: Socket
    private lateinit var reader: FrameReader
    private val logs = CopyOnWriteArrayList<String>()

    @Before
    fun setUp() {
        platform = FakePlatform().also { it.openRefused = true }
        serverSocket = ServerSocket(0)
        val accept = Thread {
            val socket = serverSocket.accept()
            socket.tcpNoDelay = true
            Session(
                socket = socket,
                display = platform,
                catalog = platform,
                launcher = platform,
                injector = platform,
                power = platform,
                device = platform,
                store = platform,
                callback = platform,
                clipboard = platform,
                now = { 1_000L },
                log = { message -> logs.add(message) },
                handshakeTimeoutMs = 3_000,
                pairDecisionTimeoutMs = 30_000,
                autoApprovePairing = true,
                tlsView = TlsV2Fixture.view,
                gateProvider = { GateSettings(true, true) },
            ).run()
        }
        accept.isDaemon = true
        accept.start()
        client = Socket("127.0.0.1", serverSocket.localPort)
        client.soTimeout = 5_000
        reader = FrameReader(client.getInputStream())
        send(mapOf("t" to "hello", "v" to 4, "path" to "a1b2c3d4", "clientId" to "c1", "name" to "Mac", "pair" to true))
        send(mapOf("t" to "pair.request"))
        readUntil("pair.commit")
        send(mapOf("t" to "pair.nonce", "n" to "0".repeat(32)))
        readUntil("welcome")
        readUntil("state")
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

    private fun readUntil(t: String): Map<String, Any?> {
        repeat(60) {
            val frame = readPathFrame(reader) ?: error("connection closed; logs: $logs")
            val message = pathJson(frame)
            if (message["t"] == t) return message
        }
        error("never received '$t'; logs: $logs")
    }

    @Test
    fun `WIN-74 an app window in the panel's group answers windows_unsupported and launches nothing`() {
        send(mapOf("t" to "window.open", "stream" to 3, "pkg" to "com.example.calc", "w" to 800, "h" to 600, "dpi" to 320))
        val error = readUntil("error")
        assertEquals("windows_unsupported", error["code"])
        assertEquals(3, Json.int(error["stream"]))
        assertTrue("nothing may launch on a refused display", platform.launches.isEmpty())
        assertTrue(logs.any { it == "stream 3 refused: windows_unsupported route=device group=0" })
        // The session is still up: the next request is answered.
        send(mapOf("t" to "ping", "ts" to 7))
        assertEquals(7, Json.int(readUntil("pong")["ts"]))
    }

    @Test
    fun `WIN-74 a link window is refused the same way`() {
        send(mapOf("t" to "link.open", "stream" to 4, "url" to "https://example.com/", "w" to 800, "h" to 600))
        val error = readUntil("error")
        assertEquals("windows_unsupported", error["code"])
        assertEquals(4, Json.int(error["stream"]))
        assertTrue(platform.views.isEmpty())
    }

    @Test
    fun `WIN-74 the Phone Mirror is not an app window and still opens`() {
        send(mapOf("t" to "window.open", "stream" to 5, "mode" to "phone", "w" to 400, "h" to 800))
        val opened = readUntil("window.opened")
        assertEquals(5, Json.int(opened["stream"]))
    }
}
