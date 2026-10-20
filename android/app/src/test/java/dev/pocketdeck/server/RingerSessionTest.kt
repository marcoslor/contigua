package dev.pocketdeck.server

import dev.pocketdeck.proto.FrameReader
import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList

/**
 * `phone.ringer` and `state.ringer` (docs/PROTOCOL.md "Ringer"): the session
 * writes the mode, answers with a fresh state, passes a person's change through
 * the state stream, and refuses while DND is on.
 */
class RingerSessionTest {

    private lateinit var platform: FakePlatform
    private lateinit var serverSocket: ServerSocket
    private lateinit var client: Socket
    private lateinit var reader: FrameReader

    private lateinit var ringerState: FakeRinger
    private var ringer: RingerControl? = null
    private var dnd: DndMode = DndMode.OFF
    private val logs = CopyOnWriteArrayList<String>()

    private class FakeRinger(var mode: RingerMode = RingerMode.NORMAL) : RingerSettings {
        var observed: ((RingerMode?) -> Unit)? = null
        override fun read(): RingerMode? = mode
        override fun listen(onChange: (RingerMode?) -> Unit): AutoCloseable? {
            observed = onChange
            return AutoCloseable { observed = null }
        }

        fun personSets(next: RingerMode) {
            mode = next
            observed?.invoke(next)
        }
    }

    @Before
    fun setUp() {
        platform = FakePlatform()
        ringerState = FakeRinger()
        ringer = RingerControl(
            ringerState,
            RingerSetter { mode -> ringerState.mode = mode; true },
            { dnd },
            { logs.add(it) },
            pollIntervalMs = 0,
        )
    }

    @After
    fun tearDown() {
        runCatching { client.close() }
        runCatching { serverSocket.close() }
    }

    private fun connect(withRinger: Boolean = true) {
        if (withRinger) platform.deviceState = platform.deviceState.copy(ringer = ringerState.mode)
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
                ringerMode = if (withRinger) ringer else null,
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
        send(mapOf("t" to "hello", "v" to 2, "clientId" to "c1", "name" to "Mac"))
        send(mapOf("t" to "pair.request"))
        readUntil("pair.commit")
        send(mapOf("t" to "pair.nonce", "n" to "0".repeat(32)))
        readUntil("welcome")
        return readUntil("state")
    }

    @Test
    fun `the post-welcome state names the ringer mode`() {
        connect()
        assertEquals("normal", authenticate()["ringer"])
    }

    @Test
    fun `phone ringer sets the mode and answers with state`() {
        connect()
        authenticate()
        send(mapOf("t" to "phone.ringer", "mode" to "silent"))
        assertEquals("silent", readUntil("state")["ringer"])
        assertEquals(RingerMode.SILENT, ringerState.mode)
    }

    @Test
    fun `a person's ringer change arrives as the next state`() {
        connect()
        authenticate()
        // The session registers the ringer listener right after its first
        // state; wait for it rather than race the accept thread.
        var waited = 0
        while (ringerState.observed == null && waited < 2_000) {
            Thread.sleep(10)
            waited += 10
        }
        ringerState.personSets(RingerMode.VIBRATE)
        assertEquals("vibrate", readUntil("state")["ringer"])
    }

    @Test
    fun `a bad mode is bad_request and changes nothing`() {
        connect()
        authenticate()
        send(mapOf("t" to "phone.ringer", "mode" to "loud"))
        val error = readUntil("error")
        assertEquals("bad_request", error["code"])
        assertEquals(RingerMode.NORMAL, ringerState.mode)
    }

    @Test
    fun `a ringer write while DND is on is refused`() {
        connect()
        authenticate()
        dnd = DndMode.PRIORITY
        send(mapOf("t" to "phone.ringer", "mode" to "silent"))
        val error = readUntil("error")
        assertEquals("dnd_on", error["code"])
        assertEquals(RingerMode.NORMAL, ringerState.mode)
    }

    @Test
    fun `an old phone sends no ringer and refuses the command`() {
        connect(withRinger = false)
        assertNull(authenticate()["ringer"])
        send(mapOf("t" to "phone.ringer", "mode" to "silent"))
        assertEquals("unsupported", readUntil("error")["code"])
    }
}
