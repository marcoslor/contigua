package dev.pocketdeck.server

import dev.pocketdeck.proto.FrameReader
import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList

/**
 * `phone.wake` and `state.screen` (docs/PROTOCOL.md "Phone screen"): the session
 * wakes display 0 through the power seam, logs the outcome by name, and answers
 * with the state the phone reports afterwards.
 */
class PhoneWakeSessionTest {

    private lateinit var platform: FakePlatform
    private lateinit var serverSocket: ServerSocket
    private lateinit var client: Socket
    private lateinit var reader: FrameReader
    private val logs = CopyOnWriteArrayList<String>()

    @Before
    fun setUp() {
        platform = FakePlatform()
    }

    @After
    fun tearDown() {
        runCatching { client.close() }
        runCatching { serverSocket.close() }
    }

    private fun connect() {
        serverSocket = ServerSocket(0)
        val accept = Thread {
            val socket = serverSocket.accept()
            socket.tcpNoDelay = true
            val session = Session(
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
            )
            session.run()
        }
        accept.isDaemon = true
        accept.start()
        client = Socket("127.0.0.1", serverSocket.localPort)
        client.soTimeout = 5_000
        reader = FrameReader(client.getInputStream())
    }

    private fun send(obj: Map<String, Any?>) {
        val out = client.getOutputStream()
        out.write(Frames.encodeJson(0, Json.encode(obj)))
        out.flush()
    }

    private fun readJson(): Map<String, Any?> {
        val frame = reader.readFrame() ?: error("connection closed; logs: $logs")
        return Json.parseObject(String(frame.payload))
    }

    private fun readUntil(t: String): Map<String, Any?> {
        repeat(60) {
            val message = readJson()
            if (message["t"] == t) return message
        }
        error("never received '$t'; logs: $logs")
    }

    private fun authenticate(): Map<String, Any?> {
        send(mapOf("t" to "hello", "v" to 3, "clientId" to "c1", "name" to "Mac", "pair" to true))
        send(mapOf("t" to "pair.request"))
        readUntil("pair.commit")
        send(mapOf("t" to "pair.nonce", "n" to "0".repeat(32)))
        readUntil("welcome")
        return readUntil("state")
    }

    @Test
    fun `the post-welcome state names the screen`() {
        platform.deviceState = DeviceState(true, 55, false, screen = ScreenState.ON)
        connect()
        assertEquals("on", authenticate()["screen"])
    }

    @Test
    fun `an unreadable screen is omitted from state`() {
        platform.deviceState = DeviceState(true, 55, false, screen = null)
        connect()
        assertFalse(authenticate().containsKey("screen"))
    }

    @Test
    fun `phone wake wakes display 0 once and answers with the next state`() {
        platform.deviceState = DeviceState(true, 55, false, screen = ScreenState.OFF)
        platform.wakeResult = WakeResult.OK
        platform.onWake = { platform.deviceState = platform.deviceState.copy(screen = ScreenState.ON) }
        connect()
        assertEquals("off", authenticate()["screen"])

        send(mapOf("t" to "phone.wake"))
        assertEquals("on", readUntil("state")["screen"])
        assertEquals(1, platform.wakeCalls.size)
        assertTrue(logs.any { it == "phone.wake ok" })
    }

    @Test
    fun `a fallback wake is logged as fallback`() {
        platform.deviceState = DeviceState(true, 55, false, screen = ScreenState.OFF)
        platform.wakeResult = WakeResult.FALLBACK
        platform.onWake = { platform.deviceState = platform.deviceState.copy(screen = ScreenState.ON) }
        connect()
        authenticate()

        send(mapOf("t" to "phone.wake"))
        readUntil("state")
        assertTrue(logs.any { it == "phone.wake fallback" })
    }

    @Test
    fun `a refused wake answers state and logs failed`() {
        platform.deviceState = DeviceState(true, 55, false, screen = ScreenState.OFF)
        platform.wakeResult = WakeResult.FAILED
        connect()
        authenticate()

        send(mapOf("t" to "phone.wake"))
        assertEquals("off", readUntil("state")["screen"])
        assertTrue(logs.any { it == "phone.wake failed" })
    }

    @Test
    fun `no other message wakes the phone`() {
        platform.deviceState = DeviceState(true, 55, false, screen = ScreenState.ON)
        connect()
        authenticate()
        send(mapOf("t" to "ping", "ts" to 1))
        readUntil("pong")
        assertNull(platform.wakeCalls.firstOrNull())
    }
}
