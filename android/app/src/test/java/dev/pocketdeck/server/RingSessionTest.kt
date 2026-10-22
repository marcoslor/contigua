package dev.pocketdeck.server

import dev.pocketdeck.proto.FrameReader
import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Before
import org.junit.Test
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList

/**
 * `phone.ring` / `phone.ring.stop` (docs/PROTOCOL.md "Ring"): the wire clamps the
 * duration and the app process — never the shell — gets the ring.
 */
class RingSessionTest {

    private lateinit var platform: FakePlatform
    private lateinit var serverSocket: ServerSocket
    private lateinit var client: Socket
    private lateinit var reader: FrameReader

    private val rings = CopyOnWriteArrayList<Int>()
    private var stops = 0
    private var clock = 1_000L
    private val logs = CopyOnWriteArrayList<String>()

    private val ringer = object : Ringer {
        override fun start(seconds: Int) {
            rings.add(seconds)
        }

        override fun stop() {
            stops += 1
        }
    }

    @Before
    fun setUp() {
        platform = FakePlatform()
    }

    @After
    fun tearDown() {
        runCatching { client.close() }
        runCatching { serverSocket.close() }
    }

    private fun connect(withRinger: Boolean = true) {
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
                now = { clock++ },
                log = { message -> logs.add(message) },
                handshakeTimeoutMs = 3_000,
                pairDecisionTimeoutMs = 30_000,
                autoApprovePairing = true,
                tlsView = TlsV2Fixture.view,
                gateProvider = { GateSettings(true, true) },
                ringer = if (withRinger) ringer else null,
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
        repeat(40) {
            val message = readJson()
            if (message["t"] == t) return message
        }
        error("never received '$t'; logs: $logs")
    }

    private fun authenticate() {
        send(mapOf("t" to "hello", "v" to 3, "clientId" to "c1", "name" to "Mac"))
        send(mapOf("t" to "pair.request"))
        readUntil("pair.commit")
        send(mapOf("t" to "pair.nonce", "n" to "0".repeat(32)))
        readUntil("welcome")
    }

    @Test
    fun `phone ring starts the app ring and answers ringing`() {
        connect()
        authenticate()
        send(mapOf("t" to "phone.ring", "seconds" to 90))
        val state = readUntil("ring.state")
        assertEquals(true, state["ringing"])
        assertEquals(listOf(30), rings.toList())
    }

    @Test
    fun `phone ring defaults to 30 s and refuses zero`() {
        connect()
        authenticate()
        send(mapOf("t" to "phone.ring"))
        assertEquals(true, readUntil("ring.state")["ringing"])
        send(mapOf("t" to "phone.ring", "seconds" to 0))
        assertEquals(true, readUntil("ring.state")["ringing"])
        assertEquals(listOf(30, 1), rings.toList())
    }

    @Test
    fun `phone ring stop stops the ring`() {
        connect()
        authenticate()
        send(mapOf("t" to "phone.ring", "seconds" to 5))
        readUntil("ring.state")
        send(mapOf("t" to "phone.ring.stop"))
        assertEquals(false, readUntil("ring.state")["ringing"])
        assertEquals(1, stops)
    }

    @Test
    fun `ring without the app process is refused`() {
        connect(withRinger = false)
        authenticate()
        send(mapOf("t" to "phone.ring", "seconds" to 10))
        val error = readUntil("error")
        assertEquals("unsupported", error["code"])
        assertFalse("nothing rang", rings.isNotEmpty())
    }
}
