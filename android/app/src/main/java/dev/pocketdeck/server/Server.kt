package dev.pocketdeck.server

import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.Json
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import javax.net.ssl.SSLContext
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
    private val selfCertProvider: () -> String = { "" },
    private val selfKeyProvider: () -> String = { "" },
    /** The app's connection gates; null refuses every Mac (fail closed). */
    private val gateProvider: () -> GateSettings? = { null },
) {
    private val serverSocket = ServerSocket()
    private val running = AtomicBoolean(false)
    @Volatile private var acceptThread: Thread? = null
    @Volatile private var active: Session? = null
    /** The TLS context built from the current pushed identity; rebuilt only
     * when the PEMs change (setPairedClients may run at any time). */
    private var cachedContext: String = ""
    private var cachedTlsContext: SSLContext? = null
    private val contextLock = Object()

    private fun tlsContext(): SSLContext? {
        val cert = selfCertProvider()
        val key = selfKeyProvider()
        val identity = "$cert\n\u0000$key"
        synchronized(contextLock) {
            if (identity != cachedContext || cachedTlsContext == null) {
                val built = try {
                    ShellTls.serverContext(cert, key, null)
                } catch (t: Throwable) {
                    null
                }
                cachedTlsContext = built
                cachedContext = identity
            }
            return cachedTlsContext
        }
    }

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

    /** The phone's per-phone notify toggle changed: sessions re-answer the gate. */
    fun recomputeNotify() {
        active?.takeIf { !it.isClosed }?.reconcileNotify()
    }

    /** One listener event push (app process → shell service → session). */
    fun onDeviceEvent(t: String, obj: Map<String, Any?>) {
        active?.takeIf { it.isReady }?.onDeviceEvent(t, obj)
    }

    private fun acceptLoop() {
        while (running.get()) {
            val rawSocket = try {
                serverSocket.accept()
            } catch (e: Throwable) {
                if (running.get()) log("accept failed: ${e.message}")
                break
            }
            runCatching { rawSocket.tcpNoDelay = true }
            // TLS 1.3 only (docs/design/e2ee.md §2, fixed decision): every
            // connection is wrapped before any byte of the session protocol is
            // exchanged. A failed wrap is closed, never downgraded to plaintext.
            val socket: Socket? = try {
                val ctx = tlsContext()
                if (ctx == null) {
                    log("tls identity missing: closing connection")
                    runCatching { rawSocket.close() }
                    null
                } else {
                    val ssl = ShellTls.wrapAccepted(rawSocket, ctx)
                    val handshake = runCatching { ssl.startHandshake() }
                    if (handshake.isFailure) {
                        // A client that connects and hangs up without a byte
                        // (the Mac's Bonjour resolve does exactly that once
                        // per connect: review R4-b) is no event at all: no
                        // log, no session, nothing counted.
                        val error = handshake.exceptionOrNull()
                        if (error == null || !isEmptyConnection(error)) {
                            log("tls handshake failed: ${error?.message}")
                        }
                        runCatching { ssl.close() }
                        null
                    } else {
                        ssl
                    }
                }
            } catch (e: Throwable) {
                log("tls wrap failed: ${e.message}")
                runCatching { rawSocket.close() }
                null
            }
            if (socket == null) continue
            // The master gate is checked before any session state exists: a
            // Mac gets the refusal even if the app never pushed a setting.
            if (gateProvider()?.allowConnections != true) {
                log("refused: connections off")
                reject(socket, "connections_off", "the phone is not accepting connections")
                continue
            }
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

    internal companion object {
        /** True when the peer closed before completing a ClientHello: an
         *  EOF/reset anywhere in the cause chain (JDK: "Remote host terminated
         *  the handshake"; Conscrypt: "Connection closed by peer"). */
        fun isEmptyConnection(error: Throwable): Boolean {
            var cause: Throwable? = error
            while (cause != null) {
                if (cause is java.io.EOFException) return true
                val message = cause.message?.lowercase().orEmpty()
                if ("terminated the handshake" in message || "closed by peer" in message ||
                    "connection reset" in message) return true
                cause = cause.cause.takeIf { it !== cause }
            }
            return false
        }
    }

    /** Live gate change: the app switched a gate while a session is up. */
    fun applyGates() {
        active?.takeIf { !it.isClosed }?.applyGates()
    }

    private fun rejectBusy(socket: Socket) =
        reject(socket, "busy", "one session at a time")

    private fun reject(socket: Socket, code: String, message: String) {
        try {
            val out = socket.getOutputStream()
            out.write(Frames.encodeJson(0, Json.encode(mapOf("t" to "error", "code" to code, "message" to message))))
            out.flush()
        } catch (_: Throwable) {
        }
        runCatching { socket.close() }
    }
}
