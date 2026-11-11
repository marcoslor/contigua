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
 * `phone.volume` and `state.volume` (docs/PROTOCOL.md "Volume"): the session
 * writes STREAM_MUSIC, answers with a fresh state, and passes a person's change
 * through the state stream. A phone that omits the fields refuses the command.
 */
class VolumeSessionTest {

    private lateinit var platform: FakePlatform
    private lateinit var serverSocket: ServerSocket
    private lateinit var client: Socket
    private lateinit var reader: FrameReader

    private lateinit var volumeState: FakeVolume
    private var volume: VolumeControl? = null
    private val logs = CopyOnWriteArrayList<String>()

    private class FakeVolume(level: Int, max: Int) : VolumeSettings {
        var level = level
        var max = max
        var refuse = false
        var observed: (() -> Unit)? = null
        val written = CopyOnWriteArrayList<Int>()

        override fun read(): Pair<Int, Int>? =
            if (max <= 0 || level < 0) null else level to max

        override fun listen(onChange: () -> Unit): AutoCloseable? {
            observed = onChange
            return AutoCloseable { observed = null }
        }

        override fun set(level: Int): Boolean {
            if (refuse) return false
            written.add(level)
            this.level = level
            return true
        }

        fun personSets(next: Int) {
            level = next
            observed?.invoke()
        }
    }

    @Before
    fun setUp() {
        platform = FakePlatform()
        volumeState = FakeVolume(6, 15)
        volume = VolumeControl(volumeState, { logs.add(it) }, pollIntervalMs = 0)
    }

    @After
    fun tearDown() {
        runCatching { client.close() }
        runCatching { serverSocket.close() }
    }

    private fun connect(withVolume: Boolean = true) {
        if (withVolume) {
            platform.deviceState = platform.deviceState.copy(volume = volumeState.level,
                                                             volumeMax = volumeState.max)
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
                volume = if (withVolume) volume else null,
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
    fun `the post-welcome state names the music volume and its maximum`() {
        connect()
        val state = authenticate()
        assertEquals(6L, state["volume"])
        assertEquals(15L, state["volumeMax"])
    }

    @Test
    fun `phone volume clamps and answers with the state it read`() {
        connect()
        authenticate()
        send(mapOf("t" to "phone.volume", "level" to 99))
        val state = readUntil("state")
        assertEquals(15L, state["volume"])
        assertEquals(15L, state["volumeMax"])
        assertEquals(listOf(15), volumeState.written)
    }

    @Test
    fun `a negative level clamps to silence`() {
        connect()
        authenticate()
        send(mapOf("t" to "phone.volume", "level" to -4))
        assertEquals(0L, readUntil("state")["volume"])
        assertEquals(listOf(0), volumeState.written)
    }

    @Test
    fun `a person's volume change arrives as the next state`() {
        connect()
        authenticate()
        var waited = 0
        while (volumeState.observed == null && waited < 2_000) {
            Thread.sleep(10)
            waited += 10
        }
        volumeState.personSets(9)
        val state = readUntil("state")
        assertEquals(9L, state["volume"])
        assertEquals(15L, state["volumeMax"])
    }

    @Test
    fun `an old phone sends no volume and refuses the command`() {
        connect(withVolume = false)
        val state = authenticate()
        assertNull(state["volume"])
        assertNull(state["volumeMax"])
        send(mapOf("t" to "phone.volume", "level" to 5))
        assertEquals("unsupported", readUntil("error")["code"])
    }

    @Test
    fun `a refused write is an error and leaves the volume alone`() {
        connect()
        authenticate()
        volumeState.refuse = true
        send(mapOf("t" to "phone.volume", "level" to 8))
        assertEquals("unavailable", readUntil("error")["code"])
        assertFalse(volumeState.written.contains(8))
    }
}
