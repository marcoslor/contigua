package dev.pocketdeck.server

import dev.pocketdeck.proto.FrameReader
import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.Json
import org.junit.After
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket

/**
 * A loopback [Session] over a recording [FakePlatform], for the multi-window
 * cases: they need real dispatch (the cap counts the session's own streams, a
 * close asks the platform), not just a pure decision. [SessionTest] keeps its
 * own wider fixture; this one stays small on purpose.
 */
abstract class SessionFixture {

    protected lateinit var platform: FakePlatform
    private lateinit var serverSocket: ServerSocket
    private lateinit var client: Socket
    private lateinit var reader: FrameReader
    protected var session: Session? = null
    private var clock = 1_000L

    protected fun connect(
        taskPresence: TaskPresence = TaskPresence { null },
        taskMove: TaskMove? = null,
        titleObserver: WindowObserver? = null,
    ) {
        platform = FakePlatform()
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
                titleObserver = titleObserver,
                taskPresence = taskPresence,
                clipboard = platform,
                packages = null,
                taskMove = taskMove,
                now = { clock++ },
                log = {},
                handshakeTimeoutMs = 3_000,
                pairDecisionTimeoutMs = 30_000,
                exitPollIntervalMs = 50,
                tlsView = TlsV2Fixture.view,
                gateProvider = { GateSettings(true, true) },
            )
            session = sess
            sess.run()
        }
        accept.isDaemon = true
        accept.start()
        platform.clients.add(PairedClient("c1", "MacBook", TlsV2Fixture.MAC_FP_HEX))
        send(mapOf("t" to "hello", "v" to 3, "clientId" to "c1", "name" to "MacBook"))
        readUntil("welcome")
    }

    @After
    fun closeFixture() {
        runCatching { client.close() }
        runCatching { serverSocket.close() }
    }

    protected fun send(obj: Map<String, Any?>) {
        val out = client.getOutputStream()
        out.write(Frames.encodeJson(0, Json.encode(obj)))
        out.flush()
    }

    protected fun readJson(): Map<String, Any?> {
        val frame = reader.readFrame() ?: error("connection closed")
        return Json.parseObject(String(frame.payload))
    }

    /** The next frame, JSON or video; null when the peer closed. */
    protected fun readFrame(): dev.pocketdeck.proto.Frame? = reader.readFrame()

    protected fun readUntil(t: String): Map<String, Any?> {
        repeat(40) {
            val m = readJson()
            if (m["t"] == t) return m
        }
        error("never received '$t'")
    }

    /** The window.open request every case uses; a 640×480 stream at dpi 160. */
    protected fun open(stream: Int, pkg: String, newInstance: Boolean = false, phone: Boolean = false) {
        val request = linkedMapOf<String, Any?>("t" to "window.open", "stream" to stream, "w" to 640, "h" to 480, "dpi" to 160)
        if (phone) request["mode"] = "phone" else request["pkg"] = pkg
        if (newInstance) request["newInstance"] = true
        send(request)
    }
}
