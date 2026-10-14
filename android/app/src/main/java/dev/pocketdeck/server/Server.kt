package dev.pocketdeck.server

import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.Json
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean

/** Builds a [Session] for an accepted socket (wired up by DeckService). */
fun interface SessionFactory {
    fun create(socket: Socket): Session
}

/**
 * The TCP acceptor. Binds 0.0.0.0 on an ephemeral port and serves one session at
 * a time (a second connection is answered with `busy` and closed).
 */
class Server(
    private val factory: SessionFactory,
    private val log: (String) -> Unit = {},
) {
    private val serverSocket = ServerSocket()
    private val running = AtomicBoolean(false)

    @Volatile private var acceptThread: Thread? = null
    @Volatile private var active: Session? = null

    val port: Int get() = serverSocket.localPort

    fun start(): Int {
        if (running.get()) return port
        serverSocket.reuseAddress = true
        serverSocket.bind(InetSocketAddress(0))
        running.set(true)
        acceptThread = Thread({ acceptLoop() }, "pocketdeck-accept").also { it.start() }
        log("listening on 0.0.0.0:$port")
        return port
    }

    fun stop() {
        if (!running.compareAndSet(true, false)) return
        runCatching { serverSocket.close() }
        active?.let { runCatching { it.close() } }
        active = null
        acceptThread = null
        log("server stopped")
    }

    fun respondPairing(requestId: String, allow: Boolean) {
        active?.respondPairing(requestId, allow)
    }

    /** The one session serves shares; with none ready the share is refused, never queued. */
    fun shareText(text: String): Int =
        active?.takeIf { it.isReady }?.shareText(text) ?: ShareStatus.NO_SESSION

    fun shareFile(name: String, mime: String, input: java.io.InputStream): Int =
        active?.takeIf { it.isReady }?.shareFile(name, mime, input) ?: ShareStatus.NO_SESSION

    private fun acceptLoop() {
        while (running.get()) {
            val socket = try {
                serverSocket.accept()
            } catch (e: Throwable) {
                if (running.get()) log("accept failed: ${e.message}")
                break
            }
            runCatching { socket.tcpNoDelay = true }
            val current = active
            if (current != null && !current.isClosed) {
                rejectBusy(socket)
                continue
            }
            val session = factory.create(socket)
            active = session
            Thread({
                try {
                    session.run()
                } finally {
                    if (active === session) active = null
                }
            }, "pocketdeck-session").also { it.start() }
        }
    }

    private fun rejectBusy(socket: Socket) {
        try {
            val out = socket.getOutputStream()
            out.write(Frames.encodeJson(0, Json.encode(mapOf("t" to "error", "code" to "busy", "message" to "one session at a time"))))
            out.flush()
        } catch (_: Throwable) {
        }
        runCatching { socket.close() }
    }
}
