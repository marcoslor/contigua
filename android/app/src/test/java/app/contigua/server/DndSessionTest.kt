package app.contigua.server

import app.contigua.proto.FrameReader
import app.contigua.proto.Frames
import app.contigua.proto.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList

/**
 * `phone.dnd` and `state.dnd` (docs/PROTOCOL.md "Focus and Do Not Disturb"):
 * the session applies the mode, answers with a fresh state, and passes a
 * person's change through the existing state stream.
 */
class DndSessionTest {

    private lateinit var platform: FakePlatform
    private lateinit var serverSocket: ServerSocket
    private lateinit var client: Socket
    private lateinit var reader: FrameReader

    private lateinit var zenState: FakeZen
    private var zen: ZenControl? = null
    private val logs = CopyOnWriteArrayList<String>()

    private class FakeZen(var mode: DndMode = DndMode.OFF) : ZenSettings {
        val writes = CopyOnWriteArrayList<DndMode>()
        var observed: ((DndMode?) -> Unit)? = null

        override fun read(): DndMode? = mode

        override fun listen(onChange: (DndMode?) -> Unit): AutoCloseable? {
            observed = onChange
            return AutoCloseable { observed = null }
        }

        fun personSets(next: DndMode) {
            mode = next
            observed?.invoke(next)
        }
    }

    @Before
    fun setUp() {
        platform = FakePlatform()
        zenState = FakeZen()
        val setter = ZenSetter { mode ->
            zenState.writes.add(mode)
            zenState.mode = mode
            true
        }
        zen = ZenControl(zenState, setter, { logs.add(it) }, pollIntervalMs = 0)
    }

    @After
    fun tearDown() {
        runCatching { client.close() }
        runCatching { serverSocket.close() }
    }

    private fun connect(withZen: Boolean = true) {
        if (withZen) {
            platform.deviceState = platform.deviceState.copy(dnd = zenState.mode)
        }
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
                zen = if (withZen) zen else null,
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
        val frame = readPathFrame(reader) ?: error("connection closed; logs: $logs")
        return pathJson(frame)
    }

    private fun readUntil(t: String): Map<String, Any?> {
        repeat(60) {
            val message = readJson()
            if (message["t"] == t) return message
        }
        error("never received '$t'; logs: $logs")
    }

    private fun authenticate(): Map<String, Any?> {
        send(mapOf("t" to "hello", "v" to 4, "path" to "a1b2c3d4", "clientId" to "c1", "name" to "Mac", "pair" to true))
        send(mapOf("t" to "pair.request"))
        readUntil("pair.commit")
        send(mapOf("t" to "pair.nonce", "n" to "0".repeat(32)))
        readUntil("welcome")
        return readUntil("state")
    }

    @Test
    fun `the post-welcome state names the zen mode`() {
        connect()
        val state = authenticate()
        assertEquals("off", state["dnd"])
    }

    @Test
    fun `phone dnd sets the mode and answers with state`() {
        connect()
        authenticate()
        send(mapOf("t" to "phone.dnd", "mode" to "priority"))
        val state = readUntil("state")
        assertEquals("priority", state["dnd"])
        assertEquals(listOf(DndMode.PRIORITY), zenState.writes.toList())
    }

    @Test
    fun `off restores a mode Contigua set`() {
        connect()
        authenticate()
        send(mapOf("t" to "phone.dnd", "mode" to "alarms"))
        assertEquals("alarms", readUntil("state")["dnd"])
        send(mapOf("t" to "phone.dnd", "mode" to "off"))
        assertEquals("off", readUntil("state")["dnd"])
        assertEquals(listOf(DndMode.ALARMS, DndMode.OFF), zenState.writes.toList())
    }

    @Test
    fun `a person's change arrives as the next state`() {
        connect()
        authenticate()
        send(mapOf("t" to "phone.dnd", "mode" to "priority"))
        readUntil("state")
        zenState.personSets(DndMode.NONE)
        assertEquals("none", readUntil("state")["dnd"])
    }

    @Test
    fun `a bad mode is bad_request and changes nothing`() {
        connect()
        authenticate()
        send(mapOf("t" to "phone.dnd", "mode" to "loud"))
        val error = readUntil("error")
        assertEquals("bad_request", error["code"])
        assertFalse(zenState.writes.isNotEmpty())
        assertEquals(DndMode.OFF, zenState.mode)
    }

    @Test
    fun `an old phone sends no dnd and refuses the command`() {
        connect(withZen = false)
        val state = authenticate()
        assertNull(state["dnd"])
        send(mapOf("t" to "phone.dnd", "mode" to "priority"))
        assertEquals("unsupported", readUntil("error")["code"])
    }
}
