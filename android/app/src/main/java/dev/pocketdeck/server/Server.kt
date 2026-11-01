package dev.pocketdeck.server

import dev.pocketdeck.proto.Crypto
import dev.pocketdeck.proto.FrameReader
import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.Json
import dev.pocketdeck.proto.PathVersion
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Builds a [Session] for an accepted socket (wired up by DeckService). */
fun interface SessionFactory {
    /**
     * [socket] is the TLS session socket; [plain] is the accepted TCP socket
     * under it, which a drop shuts down first (docs/specs/pairing.md PAIR-20).
     */
    fun create(socket: Socket, plain: Socket, hello: Map<String, Any?>?): Session
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
    /**
     * The stored macOS pins (hex). With "Allow connections" off only a peer
     * whose certificate matches one of them hears `connections_off`; any other
     * peer is closed without a word (review M-3).
     */
    private val pinnedPeerFpsProvider: () -> List<String> = { emptyList() },
    /**
     * The live session and the daemon that ends it: a drop hands the close over
     * instead of running it on the caller's thread (PAIR-20). Injected so a
     * test can hold a session whose close blocks.
     */
    private val sessions: SessionDropper = SessionDropper(log),
    /**
     * Builds the TLS context from the pushed identity. Null (production) uses
     * [ShellTls]; the JVM harness substitutes Conscrypt to match Android.
     */
    private val tlsContextBuilder: ((String, String) -> SSLContext?)? = null,
    /** R-8/D-4: the app shows the version sentence; null = the hello had no v. */
    private val onVersionRefused: (Int?) -> Unit = {},
) {
    private val serverSocket = ServerSocket()
    private val running = AtomicBoolean(false)
    @Volatile private var acceptThread: Thread? = null
    /**
     * Bounded handshake pool (review H-1): the accept loop hands every socket to
     * one of two workers and immediately accepts again, so a peer that never
     * sends its ClientHello can never block later connections. A third socket
     * while both slots are busy is closed at once (no queue).
     */
    private val handshakes = ThreadPoolExecutor(
        MAX_HANDSHAKES, MAX_HANDSHAKES, 30L, TimeUnit.SECONDS, SynchronousQueue(),
        { r -> Thread(r, "pocketdeck-handshake").apply { isDaemon = true } },
    ).apply { allowCoreThreadTimeOut(true) }
    /** True once the current saturation burst was logged; cleared when a slot frees. */
    private val handshakeBusyLogged = AtomicBoolean(false)
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
                    if (tlsContextBuilder != null) {
                        tlsContextBuilder.invoke(cert, key)
                    } else {
                        ShellTls.serverContext(cert, key, null)
                    }
                } catch (t: Throwable) {
                    // Class and message only: never the key or certificate bytes.
                    // This separates "identity missing" from "identity broken".
                    log("tls context build failed: ${t.javaClass.simpleName}: ${t.message}")
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
        handshakes.shutdownNow()
        sessions.drop()
        acceptThread = null
        log("server stopped")
    }

    fun respondPairing(requestId: String, allow: Boolean) {
        sessions.current()?.respondPairing(requestId, allow)
    }

    /**
     * The app's vouching changed or ended (docs/design/e2ee.md §10): end the
     * live session now, not at the Mac's next reconnect. The listener keeps
     * its port; without a linked identity every later handshake is refused
     * before TLS completes.
     *
     * The close is handed to [SessionDropper]: this runs on a binder thread
     * serving the app's push, and the app's UI thread may be the one waiting
     * for the reply (PAIR-20).
     */
    fun dropSessions() {
        if (sessions.drop()) log("app link changed: live session dropped")
    }

    /** The cached TLS material was built from an identity the app no longer holds. */
    fun forgetCachedIdentity() {
        synchronized(contextLock) {
            cachedContext = ""
            cachedTlsContext = null
        }
    }

    /** The one session serves shares; with none ready the share is refused, never queued. */
    fun shareText(text: String): Int =
        sessions.current()?.takeIf { it.isReady }?.shareText(text) ?: ShareStatus.NO_SESSION

    fun shareFile(name: String, mime: String, input: java.io.InputStream): Int =
        sessions.current()?.takeIf { it.isReady }?.shareFile(name, mime, input) ?: ShareStatus.NO_SESSION

    /** The phone's notification-listener grant changed: sessions re-answer the gate. */
    fun listenerAccess(granted: Boolean) {
        sessions.current()?.takeIf { it.isReady }?.listenerAccessChanged(granted)
    }

    /** One listener event push (app process → shell service → session). */
    fun onDeviceEvent(t: String, obj: Map<String, Any?>) {
        sessions.current()?.takeIf { it.isReady }?.onDeviceEvent(t, obj)
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
            // A peer that connects and sends nothing must not hold this loop:
            // the handshake worker owns a 10 s read timeout (review H-1).
            runCatching { rawSocket.soTimeout = ACCEPT_TIMEOUT_MS }
            try {
                handshakes.execute { serve(rawSocket) }
            } catch (_: RejectedExecutionException) {
                // Both handshake slots are busy: refuse at once (never queue
                // behind a silent peer). One line per saturation burst.
                if (handshakeBusyLogged.compareAndSet(false, true)) {
                    log("handshake slots busy: closing extra connections")
                }
                runCatching { rawSocket.close() }
            }
        }
    }

    /**
     * A handshake worker: TLS first, then the master gate, then the single
     * session. Runs on the bounded pool, never on the accept thread.
     */
    private fun serve(rawSocket: Socket) {
        try {
            // TLS 1.3 only (docs/design/e2ee.md §2, fixed decision): every
            // connection is wrapped before any byte of the session protocol is
            // exchanged. A failed wrap is closed, never downgraded to plaintext.
            val socket = completeHandshake(rawSocket) ?: return
            // The master gate is checked before any session state exists: a
            // known Mac gets the refusal even if the app never pushed a setting.
            if (gateProvider()?.allowConnections != true) {
                refuseConnectionsOff(socket)
                return
            }
            // PAIR-22: the kernel ends a peer that vanished without a FIN, so the
            // slot frees in seconds instead of at the retransmit give-up. A
            // failure never fails the session.
            val keepalive = TcpKeepalive.apply(rawSocket)
            log(if (keepalive == 0) "keepalive on" else "keepalive failed errno=$keepalive")
            val peerMac = peerMacHex(socket)
            val pinned = isPinned(peerMac)
            // The hello decides a join (PATH-3): TLS is the only authentication,
            // and the slot is the only record of who owns the phone. The frame
            // reader reads exactly one frame, so the session's reader sees the
            // next byte untouched. The accept timeout bounds a silent peer.
            runCatching { socket.soTimeout = ACCEPT_TIMEOUT_MS }
            val first = try {
                FrameReader(socket.getInputStream()).readFrame()
            } catch (e: Throwable) {
                reject(socket, "protocol", "unreadable hello")
                return
            }
            if (first == null) {
                runCatching { socket.close() }
                return
            }
            val hello = if (first.type == Frames.TYPE_JSON) {
                runCatching { Json.parseObject(String(first.payload)) }.getOrNull()
            } else null
            if (hello == null || hello["t"] != "hello") {
                reject(socket, "protocol", "expected hello")
                return
            }
            val v = Json.int(hello["v"])
            if (PathVersion.refused(v)) {
                log("version: ${PathVersion.phoneSentence(v)}")
                // RR-13: only a Mac the phone pins, and only while no live
                // session owns the slot, may put the sentence on the card. A
                // stray peer, or another Mac's old app, must not replace a
                // connected session's card.
                if (pinned && sessions.current() == null) runCatching { onVersionRefused(v) }
                reject(socket, "version", "this phone speaks protocol ${PathVersion.CURRENT}",
                    mapOf("v" to PathVersion.CURRENT))
                return
            }
            val pathId = Json.str(hello["path"])
            if (pathId == null || !isHex(pathId, 8)) {
                reject(socket, "protocol", "bad path id")
                return
            }
            val join = Json.str(hello["join"])
            if (join != null) {
                if (!isHex(join, 32)) {
                    reject(socket, "protocol", "bad session id")
                    return
                }
                when (sessions.attach(peerMac, pinned, join, pathId, socket, rawSocket)) {
                    AttachResult.ATTACHED -> return
                    AttachResult.NO_SESSION -> {
                        reject(socket, "no_session", "no such session")
                        return
                    }
                    AttachResult.TOO_MANY -> {
                        reject(socket, "too_many_paths", "at most three paths")
                        return
                    }
                    AttachResult.BUSY -> {
                        rejectBusy(socket)
                        return
                    }
                }
            }
            val session = sessions.adopt(peerMac, pinned) { factory.create(socket, rawSocket, hello) }
            if (session == null) {
                rejectBusy(socket)
                return
            }
            Thread({
                try {
                    session.run()
                } finally {
                    sessions.finished(session)
                }
            }, "pocketdeck-session").also { it.start() }
        } finally {
            // A slot is free again: the next saturated burst logs once more.
            handshakeBusyLogged.set(false)
        }
    }

    /** Wrap + handshake with the accept-time read timeout; null on any failure. */
    private fun completeHandshake(rawSocket: Socket): Socket? {
        val ctx = tlsContext()
        if (ctx == null) {
            log("tls identity missing: closing connection")
            runCatching { rawSocket.close() }
            return null
        }
        val ssl: SSLSocket = try {
            ShellTls.wrapAccepted(rawSocket, ctx)
        } catch (e: Throwable) {
            log("tls wrap failed: ${e.message}")
            runCatching { rawSocket.close() }
            return null
        }
        val handshake = runCatching { ssl.startHandshake() }
        if (handshake.isFailure) {
            // A client that connects and hangs up without a byte (the Mac's
            // Bonjour resolve does exactly that once per connect: review R4-b)
            // is no event at all: no log, no session, nothing counted.
            val error = handshake.exceptionOrNull()
            if (error == null || !isEmptyConnection(error)) {
                log("tls handshake failed: ${error?.message}")
            }
            runCatching { ssl.close() }
            return null
        }
        // The first frame is the hello: keep the accept timeout until it is
        // read, then the session sets its own (PATH-3, review H-1).
        runCatching { ssl.soTimeout = ACCEPT_TIMEOUT_MS }
        return ssl
    }

    /**
     * M-3: with connections off, only a peer whose certificate is one of the
     * stored pins gets the protocol refusal (the Mac's UI depends on it). Any
     * other peer is closed without a reply, so a port scan learns nothing.
     */
    private fun refuseConnectionsOff(socket: Socket) {
        val peer = runCatching { Session.TlsView.from(socket).peerFingerprint() }
            .getOrDefault(ByteArray(0))
        val peerHex = if (peer.size == 32) Crypto.toHex(peer) else ""
        val pinned = peerHex.isNotEmpty() && pinnedPeerFpsProvider().any {
            it.length == 64 && it.equals(peerHex, ignoreCase = true)
        }
        if (pinned) {
            log("refused: connections off")
            reject(socket, "connections_off", "the phone is not accepting connections")
        } else {
            log("refused: connections off (unpinned peer)")
            runCatching { socket.close() }
        }
    }

    internal companion object {
        /** The pre-handshake read timeout (review H-1): 10 s covers a LAN trip. */
        const val ACCEPT_TIMEOUT_MS = 10_000

        /** Handshake workers; a third concurrent socket is closed at once. */
        const val MAX_HANDSHAKES = 2

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
        sessions.current()?.takeIf { !it.isClosed }?.applyGates()
    }

    private fun rejectBusy(socket: Socket) =
        reject(socket, "busy", "one session at a time")

    /** The peer's TLS fingerprint hex, or null when the socket reports none (PAIR-21). */
    private fun peerMacHex(socket: Socket): String? {
        val peer = runCatching { Session.TlsView.from(socket).peerFingerprint() }.getOrNull()
        return if (peer != null && peer.size == 32) Crypto.toHex(peer) else null
    }

    /** True when the app vouches for this fingerprint as one of its stored pins. */
    private fun isPinned(hex: String?): Boolean =
        hex != null && pinnedPeerFpsProvider().any { it.length == 64 && it.equals(hex, ignoreCase = true) }

    private fun reject(socket: Socket, code: String, message: String, extra: Map<String, Any?> = emptyMap()) {
        try {
            val fields = linkedMapOf<String, Any?>("t" to "error", "code" to code, "message" to message)
            fields.putAll(extra)
            val out = socket.getOutputStream()
            out.write(Frames.encodeJson(0, Json.encode(fields)))
            out.flush()
        } catch (_: Throwable) {
        }
        runCatching { socket.close() }
    }

    /** 8 or 32 lowercase hex, as the contract names ids. */
    private fun isHex(text: String, length: Int): Boolean =
        text.length == length && text.all { it in '0'..'9' || it in 'a'..'f' }
}
