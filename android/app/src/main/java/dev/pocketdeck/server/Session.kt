package dev.pocketdeck.server

import dev.pocketdeck.app.NotifyEvents
import dev.pocketdeck.proto.Crypto
import dev.pocketdeck.proto.Frame
import dev.pocketdeck.proto.FrameReader
import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.Json
import dev.pocketdeck.proto.VideoConfigPayload
import dev.pocketdeck.proto.VideoFramePayload
import dev.pocketdeck.proto.AudioConfigPayload
import dev.pocketdeck.proto.AudioFramePayload
import java.io.BufferedOutputStream
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

import dev.pocketdeck.app.Prefs.PENDING_QR_TTL_MS
import dev.pocketdeck.e2ee.KeyPin
import dev.pocketdeck.e2ee.PairingCodeV2
import dev.pocketdeck.e2ee.TlsExporter
import javax.net.ssl.SSLSocket
import java.security.cert.X509Certificate
/**
 * One Mac ⇄ phone session, multiplexed over a single TCP socket.
 *
 * Everything device-specific goes through the injected platform interfaces, so
 * the whole handshake/queueing/dispatch path is testable on the JVM. The
 * implementation follows docs/PROTOCOL.md exactly; where the doc is silent the
 * choice is noted in the report.
 */
class Session(
    private val socket: Socket,
    private val display: DisplayLayer,
    private val catalog: AppCatalog,
    private val launcher: Launcher,
    private val injector: Injector,
    private val power: Power,
    private val device: DeviceSource,
    private val store: PairingStore,
    private val callback: DeckCallback,
    private val titleObserver: WindowObserver? = null,
    private val taskPresence: TaskPresence? = null,
    /** Plain-text clipboard sync; null leaves the clipboard alone. */
    private val clipboard: ClipboardPort? = null,
    /** APK installs at shell UID; null refuses them (docs/design/apk.md). */
    private val packages: PackageShell? = null,
    /** Task list + task-to-display moves for `task.continue`; null refuses them. */
    private val taskMove: TaskMove? = null,
    /** File drops into /sdcard/Download/PocketDeck (docs/design/dragdrop.md); null refuses. */
    private val dropLanding: DropReceiver.Landing? = null,
    /** Clipboard image port (read + write); null leaves images unsynced. */
    private val clipImages: ClipboardImagePort? = null,
    private val now: () -> Long = { System.nanoTime() / 1_000_000 },
    private val log: (String) -> Unit = {},
    private val handshakeTimeoutMs: Int = 15_000,
    /** How long a person has to tap Allow or Deny before the request expires. */
    private val pairDecisionTimeoutMs: Long = 120_000,
    private val exitPollIntervalMs: Long = 2_000,
    maxDeltaBytesPerStream: Int = SendQueue.DEFAULT_MAX_DELTA_BYTES,
    private val autoApprovePairing: Boolean = false,
    private val selfCertProvider: () -> String = { "" },
    /**
     * The scanned QR the app handed over (map shape as Prefs.PendingQr), or
     * null. The shell answers the Mac's probe with pair.qr when the connected
     * Mac's TLS fingerprint matches `macFp` (R2).
     */
    private val pendingQrProvider: () -> Map<String, Any?>? = { null },
    /**
     * The app's two connection gates. Null means the values were never
     * delivered; [ConnectionGate] then refuses every Mac (fail closed).
     */
    private val gateProvider: () -> GateSettings? = { null },
    /** The TLS session view: the Mac's point fingerprint and the exporter. Production
     * derives both from this session's SSLSocket; the JVM tests inject deterministic
     * values (docs/design/e2ee.md §4b: the HKDF math is pinned without an engine). */
    private val tlsView: TlsView? = null,
    private val audioCapture: AudioCaptureLayer? = null,
    private val notifyShared: () -> Boolean = { false },
    private val mediaCommand: ((String) -> Unit)? = null,
    private val notifyForward: ((Boolean) -> Unit)? = null,
    /** Asks the app for the forwarded notification's action; it answers over AIDL. */
    private val notifyOpen: ((String, Int) -> Unit)? = null,
) : VideoSink, AudioSink {

    /** What the TLS layer knows about this connection (§1/§4b). */
    class TlsView(
        val peerFingerprint: () -> ByteArray = { ByteArray(0) },
        /** The phone's own fingerprint; null falls back to [selfCertProvider]. */
        val selfFingerprint: (() -> ByteArray)? = null,
        val exporter: () -> ByteArray? = { null },
    ) {
        companion object {
            /** The real view: read both from the platform SSLSocket. */
            fun from(socket: Socket): TlsView = TlsView(
                peerFingerprint = {
                    val s = socket as? SSLSocket ?: return@TlsView ByteArray(0)
                    runCatching {
                        val cert = s.session.peerCertificates.firstOrNull() as? X509Certificate
                            ?: return@runCatching ByteArray(0)
                        val pub = cert.publicKey as? java.security.interfaces.ECPublicKey
                            ?: return@runCatching ByteArray(0)
                        KeyPin.fingerprint(pub)
                    }.getOrDefault(ByteArray(0))
                },
                exporter = {
                    val s = socket as? SSLSocket ?: return@TlsView null
                    TlsExporter.tryExportKeyingMaterial(s)
                },
            )
        }
    }

    private enum class Phase { HELLO, PAIR, READY }
    private class StreamState(val stream: Int, val displayId: Int, var size: IntSize) {
        /** Read by pocketdeck-watch; written by the reader thread. */
        @Volatile var paused = false

        /** Written before the state is published under `streams`; never reassigned. */
        var content: WindowContent? = null

        /** Written by pocketdeck-watch, read by the audio thread's capture plan. */
        @Volatile var lastTitle: TopApp? = null

        /** pocketdeck-watch only. */
        var hadTask = false
        var gestureDownTime = 0L
        var lastEventTime = 0L
        var keyDownTime = 0L
    }

    private val queue = SendQueue(maxDeltaBytesPerStream) { stream -> onDeltaDrop(stream) }
    private val closed = AtomicBoolean(false)
    private val pairLock = Object()

    @Volatile private var phase = Phase.HELLO
    @Volatile private var closeRequested = false

    private val streams = LinkedHashMap<Int, StreamState>()
    private val clipSync = ClipSync()
    private val apk = packages?.let { ApkInstaller(it, ::sendJson, log) }
    private val share = ShareSender(::sendJson, queue::enqueueBulk, log)
    private val drop = dropLanding?.let { DropReceiver(it, ::sendJson, log) }
    private val clipImageSync = ClipImageSync()
    private val clipImageSender = ClipImageSender(queue::enqueueBulk, log)
    private val clipImageReceiver = ClipImageReceiver(ClipImageLand(clipImages, log), log)
    private var clipImagePoll: Thread? = null

    private var clientId = ""
    private var clientName = "Mac"

    /** The v2 pairing room; read/written on the reader thread only. */
    private var pendingPairId: String? = null
    private var pairSettled = false
    private var pendingNp: ByteArray? = null
    private var pendingMacFp = ByteArray(32)
    private var pendingPhoneFp = ByteArray(32)
    private var currentMacName: String? = null

    private val loggedUnknown = HashSet<String>()

    /**
     * Hover moves arrive faster than the input service takes them sometimes.
     * One slot holds the newest move; a single thread drains it, so stale
     * points are replaced, never queued. Enter/exit go straight through: they
     * must keep their order with the touch DOWN that follows an exit.
     */
    private class PendingHover(val displayId: Int, val nx: Float, val ny: Float, val size: IntSize)
    private val hoverLock = Any()
    private var hoverPending: PendingHover? = null
    private var hoverDraining = false
    private val hoverExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "pocketdeck-hover").apply { isDaemon = true }
    }

    /** Notification sharing: the Mac asked for it and the phone's toggle is on. */
    @Volatile private var notifyWanted = false
    @Volatile private var notifyForwarding = false

    private var writerThread: Thread? = null
    private var stateHandle: AutoCloseable? = null
    private var watchThread: Thread? = null

    /** The protocol's `state` stream: one emission per real change. */
    private val stateTracker = DeviceStateTracker { state ->
        sendJson(mapOf("t" to "state", "locked" to state.locked, "battery" to state.battery, "charging" to state.charging))
    }

    val isClosed: Boolean get() = closed.get()

    /** Authenticated and still open: shares may go out (docs/design/sharein.md). */
    val isReady: Boolean get() = phase == Phase.READY && !closed.get() && !closeRequested

    fun shareText(text: String): Int = if (isReady) share.text(text) else ShareStatus.NO_SESSION

    fun shareFile(name: String, mime: String, input: java.io.InputStream): Int =
        if (isReady) share.file(name, mime, input) else ShareStatus.NO_SESSION

    /**
     * A gate changed in the app process. The master switch drops every live
     * session at once; the pairing switch drops only a session that has not
     * authenticated yet. Paired sessions keep running with pairings off.
     */
    fun applyGates() {
        if (closed.get() || closeRequested) return
        val settings = gateProvider()
        val decision = when {
            settings?.allowConnections != true -> GateDecision.REFUSE_CONNECTIONS_OFF
            phase == Phase.PAIR && settings?.allowPairings != true -> GateDecision.REFUSE_PAIRING_OFF
            else -> return
        }
        refuse(decision)
    }

    /**
     * Send the refusal, then let the writer drain the queue and close the
     * socket (the same write-then-close shape as the other handshake errors).
     */
    private fun refuse(decision: GateDecision) {
        val code = decision.code ?: return
        val why = if (decision == GateDecision.REFUSE_CONNECTIONS_OFF) "connections off" else "pairing off"
        log("refused: $why mac=${macIdHash(clientId)}")
        finishWithError(code, "the phone is not accepting ${if (decision == GateDecision.REFUSE_CONNECTIONS_OFF) "connections" else "new pairings"}")
    }

    /** The Mac's id hash, never the id itself (logs carry no identifiers). */
    private fun macIdHash(id: String): String = runCatching {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        Crypto.toHex(digest.digest(id.toByteArray(Charsets.UTF_8))).take(16)
    }.getOrDefault("-")

    // ------------------------------------------------------------------
    // lifecycle
    // ------------------------------------------------------------------

    /** Request teardown from another thread (e.g. server shutdown). */
    fun close() {
        closeRequested = true
        runCatching { socket.close() }
    }

    fun run() {
        writerThread = Thread({ writerLoop() }, "pocketdeck-writer").also { it.start() }
        try {
            socket.tcpNoDelay = true
            // The protocol promises at most ~250 ms of queued video per stream.
            // Without a bound the kernel (and any forwarder on the path) happily
            // buffers megabytes, the send queue never fills and the drop rule
            // never fires; 128 KB is still far above a LAN's bandwidth-delay
            // product, so throughput is unaffected.
            runCatching { socket.sendBufferSize = SEND_BUFFER_BYTES }
            socket.soTimeout = handshakeTimeoutMs
            val reader = FrameReader(socket.getInputStream())
            while (!closed.get() && !closeRequested) {
                val frame = try {
                    reader.readFrame()
                } catch (e: SocketTimeoutException) {
                    log("handshake timeout")
                    break
                }
                if (frame == null) break
                handle(frame)
            }
        } catch (e: Throwable) {
            log("reader ended: ${e.message}")
        } finally {
            shutdown()
        }
    }

    private fun shutdown() {
        if (!closed.compareAndSet(false, true)) return
        // The Mac's session ended: stop forwarding and tell the app.
        notifyWanted = false
        if (notifyForwarding) {
            notifyForwarding = false
            runCatching { notifyForward?.invoke(false) }
        }
        val abandoned = synchronized(pairLock) {
            val open = if (pairSettled) null else pendingPairId
            pairSettled = true
            pairLock.notifyAll()
            open
        }
        // The Mac went away (Cancel, network) before anyone answered: the
        // phone's prompt must not linger.
        abandoned?.let { runCatching { callback.onPairingEnded(it) } }
        stopStateWatch()
        stopClipboardSync()
        stopClipImagePoll()
        runCatching { apk?.close() }
        runCatching { drop?.close() }
        stopStreamWatch()
        hoverExecutor.shutdownNow()
        runCatching { audioCapture?.stop() }
        queue.clearAudio()
        synchronized(streams) {
            for (s in streams.values.toList()) runCatching { display.close(s.stream) }
            streams.clear()
        }
        runCatching { power.setActiveStreams(emptyList()) }
        runCatching { power.onSessionEnded() }
        queue.close()
        runCatching { writerThread?.join(1000) }
        runCatching { socket.close() }
        if (phase == Phase.READY) runCatching { callback.onSessionChanged(false, null, 0) }
    }

    private fun writerLoop() {
        try {
            val out = BufferedOutputStream(socket.getOutputStream())
            while (true) {
                val bytes = queue.poll() ?: break
                out.write(bytes)
                out.flush()
            }
            // Drained after a close request (e.g. pair_denied): wake the reader.
            runCatching { socket.close() }
        } catch (e: Throwable) {
            log("writer ended: ${e.message}")
            closeRequested = true
            runCatching { socket.close() }
        }
    }

    // ------------------------------------------------------------------
    // dispatch
    // ------------------------------------------------------------------

    private fun handle(frame: Frame) {
        if (frame.type != Frames.TYPE_JSON) {
            if (phase != Phase.READY) {
                rejectProtocol("unexpected binary frame before welcome")
            } else {
                handleInput(frame)
            }
            return
        }
        val text = String(frame.payload, Charsets.UTF_8)
        val obj = try {
            Json.parseObject(text)
        } catch (e: Exception) {
            log("bad json: ${e.message}")
            return
        }
        val t = Json.str(obj["t"])
        if (t == null) {
            log("json without t")
            return
        }
        when (phase) {
            Phase.HELLO -> if (t == "hello") onHello(obj) else rejectProtocol("expected hello, got '$t'")
            Phase.PAIR -> when (t) {
                "hello" -> onHello(obj)
                "pair.request" -> onPairRequest()
                "pair.nonce" -> onPairNonce(obj)
                "pair.ok" -> onPairingOkFromMac(obj)
                else -> rejectProtocol("expected handshake, got '$t'")
            }
            Phase.READY -> dispatch(obj, frame, t)
        }
    }

    private fun onHello(obj: Map<String, Any?>) {
        val v = Json.int(obj["v"])
        if (v != PROTOCOL_VERSION) {
            sendError("version", "unsupported protocol version $v")
            closeRequested = true
            return
        }
        clientId = Json.str(obj["clientId"]) ?: ""
        clientName = Json.str(obj["name"]) ?: "Mac"
        // The iPad named itself by a stable id on the phone's memory; the TLS
        // channel now has to prove it is still that Mac (a rotated cert means
        // the Mac reinstalled: pair again — docs/design/e2ee.md §7).
        val client = store.snapshot().firstOrNull { it.clientId == clientId }
        when (ConnectionGate.decide(gateProvider(), isPaired = client != null)) {
            GateDecision.REFUSE_CONNECTIONS_OFF ->
                return refuse(GateDecision.REFUSE_CONNECTIONS_OFF)
            GateDecision.REFUSE_PAIRING_OFF ->
                return refuse(GateDecision.REFUSE_PAIRING_OFF)
            GateDecision.ACCEPT -> Unit
        }
        if (client == null) {
            // A scanned QR changes the story: the phone proactively answers the
            // Mac's probe with pair.qr (review R2); left otherwise in PAIR for
            // the Mac's pair.request.
            if (!onHelloQrIfPending()) {
                phase = Phase.PAIR
            }
            return
        }
        val peer = tlsFacts.peerFingerprint()
        val stored = try {
            hexToBytes(client.macFpHex)
        } catch (e: Exception) {
            sendError("bad_pin", "bad stored pin")
            closeRequested = true
            return
        }
        if (peer.size != 32 || stored.size != 32 || !peer.contentEquals(stored)) {
            sendError("bad_pin", "this Mac's certificate changed; pair again")
            closeRequested = true
            return
        }
        currentMacName = client.name
        welcome()
    }

    /**
     * `pair.request`: the phone STARTS the code pairing (§4 step 1): it commits
     * to a fresh Np before the Mac releases its nonce, so a MITM can grind the
     * code only with a prompt per attempt.
     */
    private fun onPairRequest() {
        val id = Crypto.toHex(Crypto.randomBytes(8))
        synchronized(pairLock) {
            if (pendingPairId != null) {
                log("pair.request ignored: one is already open")
                return
            }
            pendingPairId = id
            pairSettled = false
        }
        val np = Crypto.randomBytes(16)
        pendingNp = np
        pendingPhoneFp = tlsView?.selfFingerprint?.invoke() ?: selfFingerprintBytes()
        pendingMacFp = tlsFacts.peerFingerprint()
        // A person decides on the phone while this thread only watches for the
        // Mac going away, so no read timeout applies.
        runCatching { socket.soTimeout = 0 }
        val commit = PairingCodeV2.commit(np, pendingPhoneFp, pendingMacFp)
        sendJson(mapOf("t" to "pair.commit", "c" to PairingCodeV2.hex(commit)))
        phase = Phase.PAIR
        Thread({ expirePairing(id) }, "pocketdeck-pair-timeout").also {
            it.isDaemon = true
            it.start()
        }
    }

    /**
     * R2 QR: on hello, a phone that scanned the Mac's QR (a fresh pending with
     * `macFp` equal to the connected TLS fingerprint) answers with `pair.qr`:
     * HMAC of its one-time secret over label‖exporter‖phoneFP. The Mac
     * verifies (it issued the secret with the QR) and pins the phone; the
     * phone's Allow prompt stays (the Mac's pair.ok arms it).
     */
    private fun onHelloQrIfPending(): Boolean {
        val qr = pendingQrProvider() ?: return false
        val fp = Json.str(qr["macFp"]) ?: return false
        val secretHex = Json.str(qr["secret"]) ?: return false
        val at = Json.long(qr["at"]) ?: 0
        // The QR expires with the Mac's sheet (5 minutes); a stale scan is dead.
        if (System.currentTimeMillis() - at !in 0..PENDING_QR_TTL_MS) return false
        if (!fp.contentEqualsHex(tlsFacts.peerFingerprint())) return false
        val id = Crypto.toHex(Crypto.randomBytes(8))
        synchronized(pairLock) {
            pendingPairId = id
            pairSettled = false
        }
        pendingPhoneFp = tlsView?.selfFingerprint?.invoke() ?: selfFingerprintBytes()
        pendingMacFp = tlsFacts.peerFingerprint()
        val exporter = tlsFacts.exporter()
        if (exporter == null) {
            log("pair.qr dropped: no exporter under TLS")
            return false
        }
        val secret = try {
            hexToBytes(secretHex)
        } catch (e: Exception) {
            return false
        }
        if (secret.size != 16) return false
        runCatching { socket.soTimeout = 0 }
        val hmac = PairingCodeV2.qrHmac(secret, exporter, pendingPhoneFp)
        sendJson(mapOf("t" to "pair.qr", "m" to PairingCodeV2.hex(hmac)))
        phase = Phase.PAIR
        return true
    }

    /** Only `pair.ok` from the Mac after a QR flow carries the Allow gate. */
    private fun onPairingOkFromMac(obj: Map<String, Any?>) {
        val id = pendingPairId ?: return onPairingMissingState()
        val macHex = Json.str(obj["macFP"]) ?: return onPairingMissingState()
        if (!macHex.contentEqualsHex(pendingMacFp)) {
            log("pair.ok macFP disagrees with the TLS peer fingerprint")
            finishWithError("pair_commit", "pairing answer does not match the session")
            return
        }
        runCatching { socket.soTimeout = 0 }
        if (autoApprovePairing) {
            synchronized(pairLock) { pairSettled = true }
            completePairing()
            return
        }
        runCatching { callback.onPairingRequest(id, clientName, "") }
    }

    private fun String.contentEqualsHex(bytes: ByteArray): Boolean {
        if (length != 64) return false
        if (any { !it.isDigit() && it !in 'a'..'f' && it !in 'A'..'F' }) return false
        return hexToBytes(this).contentEquals(bytes)
    }

    private fun onPairNonce(obj: Map<String, Any?>) {
        val id = pendingPairId ?: return onPairingMissingState()
        val nmHex = Json.str(obj["n"]) ?: return onPairingMissingState()
        val np = pendingNp ?: return onPairingMissingState()
        val nmBytes = try {
            hexToBytes(nmHex)
        } catch (e: Exception) {
            return onPairingMissingState()
        }
        if (nmBytes.size != 16) return onPairingMissingState()
        // §4 steps 3-4: reveal what we committed to; both sides derive the code.
        sendJson(mapOf("t" to "pair.reveal", "n" to PairingCodeV2.hex(np)))
        val exporter = tlsFacts.exporter() ?: ByteArray(32)
        val code = PairingCodeV2.code(exporter, pendingMacFp, pendingPhoneFp, nmBytes, np)
        val codeStr = PairingCodeV2.codeHex(code)
        log("pair code shown on the phone: $codeStr")
        if (autoApprovePairing) {
            synchronized(pairLock) { pairSettled = true }
            completePairing()
            return
        }
        runCatching { callback.onPairingRequest(id, clientName, codeStr) }
    }

    private fun onPairingMissingState() {
        finishWithError("pair_commit", "no pending pairing")
    }

    private fun expirePairing(id: String) {
        val deadline = System.currentTimeMillis() + pairDecisionTimeoutMs
        val expired = synchronized(pairLock) {
            while (!pairSettled && pendingPairId == id) {
                val left = deadline - System.currentTimeMillis()
                if (left <= 0) {
                    pairSettled = true
                    return@synchronized true
                }
                pairLock.wait(left)
            }
            false
        }
        if (!expired) return
        runCatching { callback.onPairingEnded(id) }
        finishWithError("pair_timeout", "no decision on the phone")
    }

    /**
     * Called from the app process (binder thread) when the user answers the
     * prompt. Allow completes the pairing right here: the reader thread is
     * only watching the socket.
     */
    fun respondPairing(requestId: String, allow: Boolean) {
        val mine = synchronized(pairLock) {
            if (requestId != pendingPairId || pairSettled || closed.get()) {
                false
            } else {
                pairSettled = true
                pairLock.notifyAll()
                true
            }
        }
        if (!mine) return
        if (allow) completePairing() else finishWithError("pair_denied", "pairing denied")
    }

    /** §4: `pair.ok` carries what each side pins; the phone keeps the Mac's. */
    private fun completePairing() {
        val client = PairedClient(clientId, clientName, KeyPin.toHex(pendingMacFp))
        store.add(client)
        currentMacName = clientName
        sendJson(mapOf(
            "t" to "pair.ok",
            "phoneFP" to KeyPin.toHex(pendingPhoneFp),
            "macFP" to KeyPin.toHex(pendingMacFp),
        ))
        runCatching { callback.onPaired(clientId, clientName, client.macFpHex) }
        welcome()
    }

    private fun selfFingerprintBytes(): ByteArray {
        val pem = selfCertProvider()
        if (pem.isBlank()) return ByteArray(32)
        return try {
            val cf = java.security.cert.CertificateFactory.getInstance("X.509")
            val cert = cf.generateCertificate(pem.byteInputStream()) as X509Certificate
            val pub = cert.publicKey as java.security.interfaces.ECPublicKey
            KeyPin.fingerprint(pub)
        } catch (e: Throwable) {
            ByteArray(32)
        }
    }

    private val tlsFacts: TlsView get() = tlsView ?: TlsView()
    // NB: `tlsFacts` forces the injected view; without one the production
    // default reads the SSLSocket.

    private fun hexToBytes(hex: String): ByteArray {
        val clean = hex.trim().lowercase()
        if (clean.length % 2 != 0) return ByteArray(0)
        val out = ByteArray(clean.length / 2)
        for (i in out.indices) {
            out[i] = clean.substring(i * 2, i * 2 + 2).toInt(16).toByte()
        }
        return out
    }

    /** Sends [code], lets it flush, then ends the session. */
    private fun finishWithError(code: String, message: String) {
        sendError(code, message)
        closeRequested = true
        queue.close()
    }

    private fun welcome() {
        val d = device.info()
        // Set before the welcome is queued: after a pairing the reader thread
        // may see the Mac's first request as soon as the frame is on the wire.
        phase = Phase.READY
        sendJson(
            mapOf(
                "t" to "welcome",
                "device" to mapOf(
                    "id" to d.id,
                    "name" to d.name,
                    "model" to d.model,
                    "sdk" to d.sdk,
                    "screen" to mapOf("w" to d.screenW, "h" to d.screenH, "dpi" to d.dpi),
                    "locked" to d.locked,
                ),
            ),
        )
        // The read timeout only guards the handshake; a live session may be
        // silent for long stretches (static content, no input).
        runCatching { socket.soTimeout = 0 }
        runCatching { callback.onSessionChanged(true, currentMacName ?: clientName, windowCount()) }
        startStateWatch()
        startClipboardSync()
        startClipImagePoll()
    }

    private fun dispatch(obj: Map<String, Any?>, frame: Frame, t: String) {
        when (t) {
            "ping" -> sendJson(mapOf("t" to "pong", "ts" to obj["ts"]))
            "apps.list" -> onAppsList()
            "apps.icon" -> onAppsIcon(obj)
            "window.open" -> onWindowOpen(obj, frame)
            "link.open" -> onLinkOpen(obj, frame)
            "window.resize" -> onWindowResize(obj, frame)
            "window.close" -> onWindowClose(obj, frame)
            "window.pause" -> onWindowPause(obj, frame)
            "window.resume" -> onWindowResume(obj, frame)
            "window.keyframe" -> onWindowKeyframe(obj, frame)
            "window.quality" -> onWindowQuality(obj, frame)
            "window.launch" -> onWindowLaunch(obj, frame)
            "task.continue" -> onTaskContinue(obj, frame)
            "nav" -> onNav(obj, frame)
            "text" -> onText(obj, frame)
            "clip.set" -> onClipSet(obj)
            "apk.install" -> onApkInstall(obj)
            "apk.cancel" -> (obj["id"] as? Number)?.let { apk?.cancel(it.toLong()) }
            "drop.start" -> onDropStart(obj)
            "drop.cancel" -> (obj["id"] as? Number)?.let { drop?.cancel(it.toLong()) }
            "clip.image.start" -> onClipImageStart(obj)
            "clip.image.end" -> onClipImageEnd(obj)
            "clip.image.abort" -> onClipImageAbort(obj)
            "audio.start" -> onAudioStart(obj)
            "audio.stop" -> onAudioStop()
            "notify.enable" -> onNotifyEnable(obj)
            "notify.open" -> onNotifyOpen(obj, frame)
            "media.command" -> onMediaCommand(obj)
            else -> logOnce("unknown message '$t'")
        }
    }

    private fun onAppsList() {
        val apps = catalog.list().map { mapOf("pkg" to it.pkg, "label" to it.label, "activity" to it.activity) }
        sendJson(mapOf("t" to "apps", "apps" to apps))
    }

    private fun onAppsIcon(obj: Map<String, Any?>) {
        val pkg = Json.str(obj["pkg"]) ?: return
        // The layers ride along as optional fields; a non-adaptive icon sends
        // none and an old Mac just ignores them.
        val fields = LinkedHashMap<String, Any?>()
        fields["t"] = "icon"
        fields["pkg"] = pkg
        fields["png"] = catalog.iconPng(pkg) ?: ""
        catalog.iconLayers(pkg)?.let { layers ->
            fields["fg"] = layers.fg
            fields["bg"] = layers.bg
            layers.mono?.let { fields["mono"] = it }
        }
        sendJson(fields)
    }

    private fun onWindowOpen(obj: Map<String, Any?>, frame: Frame) {
        val stream = streamOf(obj, frame)
        val content: WindowContent = if (Json.str(obj["mode"]) == "phone") {
            WindowContent.Phone
        } else {
            val pkg = Json.str(obj["pkg"]) ?: run {
                sendError("bad_request", "window.open needs pkg or mode=phone", stream)
                return
            }
            WindowContent.App(pkg, Json.str(obj["activity"]))
        }
        openStream(obj, stream, content)
    }

    private fun onLinkOpen(obj: Map<String, Any?>, frame: Frame) {
        val stream = streamOf(obj, frame)
        val url = LinkPolicy.validate(Json.str(obj["url"])) ?: run {
            sendError("bad_url", "link.open needs an http, https, geo, tel or mailto URL", stream)
            return
        }
        openStream(obj, stream, WindowContent.Link(url))
    }

    /**
     * `task.continue` (docs/ROADMAP.md #9): the Mac wants a window for the app
     * now in the foreground on the phone's own screen. The phone picks the top
     * task (ForegroundTaskPicker), opens the stream's virtual display, moves
     * the task onto it and reports how it went in the `window.opened` reply:
     * `started: "moved"` keeps the task's state, `started: "fresh"` says the
     * move was refused and the package was relaunched (its state is lost).
     * Nothing continuable is on the screen -> `nothing_to_continue`.
     */
    private fun onTaskContinue(obj: Map<String, Any?>, frame: Frame) {
        val stream = streamOf(obj, frame)
        val mover = taskMove ?: run {
            sendError("not_available", "this phone can't report its foreground app", stream)
            return
        }
        val tasks = runCatching { mover.tasks() }.getOrNull() ?: run {
            sendError("not_available", "this phone can't report its foreground app", stream)
            return
        }
        val task = ForegroundTaskPicker.pick(tasks, OWN_PACKAGE) ?: run {
            sendError("nothing_to_continue", "the phone's screen has nothing to continue", stream)
            return
        }
        val w = floor16(Json.int(obj["w"]) ?: 0)
        val h = floor16(Json.int(obj["h"]) ?: 0)
        val dpi = Json.int(obj["dpi"]) ?: 160
        if (w <= 0 || h <= 0) {
            sendError("bad_size", "task.continue needs w,h", stream)
            return
        }
        if (synchronized(streams) { streams.containsKey(stream) }) display.close(stream)
        val displayId = display.open(stream, w, h, dpi, this)
        val state = StreamState(stream, displayId, IntSize(w, h))
            .also { it.content = WindowContent.App(task.pkg, task.activity) }
        synchronized(streams) { streams[stream] = state }
        // Moving before the reply: `started` must match what actually happened.
        val moved = runCatching { mover.move(task.taskId, displayId) }.getOrDefault(false)
        if (moved) goHome() else launchOn(stream, displayId, task.pkg, task.activity)
        sendJson(
            mapOf(
                "t" to "window.opened", "stream" to stream, "displayId" to displayId,
                "w" to w, "h" to h, "started" to (if (moved) "moved" else "fresh"),
            ),
        )
        power.setActiveStreams(activeDisplayIds())
        runCatching { callback.onSessionChanged(true, currentMacName ?: clientName, windowCount()) }
        startStreamWatch()
    }

    /** After a successful move the phone's own screen shows nothing: go home. */
    private fun goHome() {
        val t = now()
        runCatching {
            injector.key(PHONE_DISPLAY_ID, Frames.ACTION_DOWN, KEYCODE_HOME, 0, t, t)
            injector.key(PHONE_DISPLAY_ID, Frames.ACTION_UP, KEYCODE_HOME, 0, t, t + 1)
        }
    }

    /** Creates the display for a `window.open` / `link.open` and starts its content. */
    private fun openStream(obj: Map<String, Any?>, stream: Int, content: WindowContent) {
        val w = floor16(Json.int(obj["w"]) ?: 0)
        val h = floor16(Json.int(obj["h"]) ?: 0)
        val dpi = Json.int(obj["dpi"]) ?: 160
        if (w <= 0 || h <= 0) {
            sendError("bad_size", "${obj["t"]} needs w,h", stream)
            return
        }
        if (synchronized(streams) { streams.containsKey(stream) }) display.close(stream)
        if (content == WindowContent.Phone) {
            val size = runCatching { display.openMirror(stream, w, h, this) }.getOrElse {
                log("phone mirror failed: ${it.message}")
                sendError("mirror_unavailable", "this phone can't mirror its screen", stream)
                return
            }
            val state = StreamState(stream, PHONE_DISPLAY, size).also { it.content = content }
            synchronized(streams) { streams[stream] = state }
            sendJson(mapOf("t" to "window.opened", "stream" to stream, "displayId" to PHONE_DISPLAY, "w" to size.w, "h" to size.h))
        } else {
            val displayId = display.open(stream, w, h, dpi, this)
            val state = StreamState(stream, displayId, IntSize(w, h)).also { it.content = content }
            synchronized(streams) { streams[stream] = state }
            sendJson(mapOf("t" to "window.opened", "stream" to stream, "displayId" to displayId, "w" to w, "h" to h))
            when (content) {
                is WindowContent.App -> launchOn(stream, displayId, content.pkg, content.activity)
                is WindowContent.Link -> viewOn(stream, displayId, content.url)
                WindowContent.Phone -> Unit
            }
        }
        power.setActiveStreams(activeDisplayIds())
        runCatching { callback.onSessionChanged(true, currentMacName ?: clientName, windowCount()) }
        startStreamWatch()
        notifyAudioWindowsChanged()
    }

    private fun onWindowResize(obj: Map<String, Any?>, frame: Frame) {
        val stream = streamOf(obj, frame)
        val state = requireState(stream) ?: return
        val w = floor16(Json.int(obj["w"]) ?: 0)
        val h = floor16(Json.int(obj["h"]) ?: 0)
        val dpi = Json.int(obj["dpi"]) ?: 160
        if (w <= 0 || h <= 0) return
        state.size = IntSize(w, h)
        display.resize(stream, w, h, dpi)
        // The new size means a redraw: make sure the group is awake for it.
        power.setActiveStreams(activeDisplayIds())
    }

    private fun onWindowClose(obj: Map<String, Any?>, frame: Frame) {
        val stream = streamOf(obj, frame)
        val state = synchronized(streams) { streams.remove(stream) }
        if (state == null) {
            sendError("no_stream", "unknown stream $stream", stream)
            return
        }
        display.close(stream)
        sendJson(mapOf("t" to "window.closed", "stream" to stream, "reason" to "requested"))
        power.setActiveStreams(activeDisplayIds())
        stopAudioIfIdle()
        notifyAudioWindowsChanged()
        runCatching { callback.onSessionChanged(true, currentMacName ?: clientName, windowCount()) }
        log("closed stream $stream (display ${state.displayId})")
    }

    private fun onWindowPause(obj: Map<String, Any?>, frame: Frame) {
        val state = requireState(streamOf(obj, frame)) ?: return
        if (!state.paused) {
            state.paused = true
            display.pause(state.stream)
            power.setActiveStreams(activeDisplayIds())
        }
    }

    private fun onWindowResume(obj: Map<String, Any?>, frame: Frame) {
        val state = requireState(streamOf(obj, frame)) ?: return
        if (state.paused) {
            state.paused = false
            display.resume(state.stream)
            power.setActiveStreams(activeDisplayIds())
        }
    }

    private fun onWindowKeyframe(obj: Map<String, Any?>, frame: Frame) {
        val state = requireState(streamOf(obj, frame)) ?: return
        display.requestKeyframe(state.stream)
    }

    /** Optional runtime quality request; a phone without the knob ignores it. */
    private fun onWindowQuality(obj: Map<String, Any?>, frame: Frame) {
        val state = requireState(streamOf(obj, frame)) ?: return
        val bitrate = Json.int(obj["bitrate"])?.takeIf { it > 0 }
        val maxFps = Json.int(obj["maxFps"])?.takeIf { it > 0 }
        if (bitrate == null && maxFps == null) return
        display.setQuality(state.stream, bitrate, maxFps)
    }

    private fun onWindowLaunch(obj: Map<String, Any?>, frame: Frame) {
        val state = requireState(streamOf(obj, frame)) ?: return
        val pkg = Json.str(obj["pkg"]) ?: return
        launchOn(state.stream, state.displayId, pkg, Json.str(obj["activity"]))
        // The shown app changes: the audio follow decision refreshes once the
        // top-app poll reports the new one (streamWatchLoop notifies).
    }

    private fun onNav(obj: Map<String, Any?>, frame: Frame) {
        val state = requireState(streamOf(obj, frame)) ?: return
        when (Json.str(obj["action"])) {
            "back" -> {
                val t = bumpTime(state)
                injector.key(state.displayId, Frames.ACTION_DOWN, KEYCODE_BACK, 0, t, t)
                injector.key(state.displayId, Frames.ACTION_UP, KEYCODE_BACK, 0, t, t + 1)
            }
            "home" -> tapKey(state, KEYCODE_HOME)
            "recents" -> tapKey(state, KEYCODE_APP_SWITCH)
            else -> logOnce("unknown nav action")
        }
    }

    /** Home and Recents only mean something on the phone's own screen. */
    private fun tapKey(state: StreamState, keycode: Int) {
        if (state.content != WindowContent.Phone) return
        val t = bumpTime(state)
        injector.key(state.displayId, Frames.ACTION_DOWN, keycode, 0, t, t)
        injector.key(state.displayId, Frames.ACTION_UP, keycode, 0, t, t + 1)
    }

    // ------------------------------------------------------------------
    // clipboard sync
    // ------------------------------------------------------------------

    /** Local changes after welcome go out as `clip.set`; the text present at welcome does not. */
    private fun startClipboardSync() {
        val port = clipboard ?: return
        port.listen { text ->
            if (clipSync.shouldSend(text)) sendJson(mapOf("t" to "clip.set", "text" to text))
        }
    }

    private fun stopClipboardSync() {
        runCatching { clipboard?.stop() }
    }

    // ------------------------------------------------------------------
    // notifications + media controls (docs/design/notify.md)
    // ------------------------------------------------------------------

    /** `notify.enable`: the Mac's per-session opt-in; the phone's toggle adds to it. */
    private fun onNotifyEnable(obj: Map<String, Any?>) {
        val on = Json.bool(obj["on"]) ?: run {
            sendError("bad_request", "notify.enable needs a boolean on", 0)
            return
        }
        notifyWanted = on
        reconcileNotify()
    }

    /** Re-evaluates the forwarding gate (also runs when the phone toggle changes). */
    fun reconcileNotify() {
        val forward = notifyWanted && notifyShared() && phase == Phase.READY && !closed.get()
        if (forward != notifyForwarding) {
            notifyForwarding = forward
            runCatching { notifyForward?.invoke(forward) }
        }
        sendJson(mapOf("t" to "notify.state", "on" to forward))
    }

    /**
     * `notify.open`: a Mac banner click (docs/design/notify.md). The Mac names
     * only the forwarded id and the target; the action itself never crosses the
     * wire. With mirroring off (or a session that is not ready) the message is
     * ignored, like every other notification message.
     */
    private fun onNotifyOpen(obj: Map<String, Any?>, frame: Frame) {
        if (!notifyForwarding) {
            logOnce("notify.open dropped (not forwarding)")
            return
        }
        val id = Json.str(obj["id"])
        if (id == null || id.isEmpty() || id.length > 64 || id.any { !it.isLetterOrDigit() && it !in "-._" }) {
            log("notify.open dropped: id")
            return
        }
        val displayId = when (Json.str(obj["target"])) {
            "phone" -> PHONE_DISPLAY
            "window" -> {
                val state = requireState(streamOf(obj, frame)) ?: return
                state.displayId
            }
            else -> {
                log("notify.open dropped: target")
                return
            }
        }
        val open = notifyOpen ?: run {
            logOnce("notify.open dropped (no consumer)")
            return
        }
        open(id, displayId)
    }

    private fun onMediaCommand(obj: Map<String, Any?>) {
        val action = Json.str(obj["action"])
        val command = action?.let { NotifyEvents.validMediaCommand(it) }
        if (command == null) {
            logOnce("media.command dropped (unknown action)")
            return
        }
        val driver = mediaCommand ?: run {
            logOnce("media.command dropped (no consumer)")
            return
        }
        driver(command)
    }

    /**
     * An event pushed by the app-process listener after both gates. Everything is
     * re-validated here: the phone side is not trusted either, and the wire must
     * never carry oversized or malformed values.
     */
    fun onDeviceEvent(t: String, obj: Map<String, Any?>) {
        if (phase != Phase.READY || !notifyForwarding) return
        when (t) {
            "notify.post" -> deviceNotifyPost(obj)
            "notify.remove" -> deviceNotifyRemove(obj)
            "media.state" -> deviceMedia(obj)
            else -> logOnce("device event '$t' ignored")
        }
    }

    private fun deviceNotifyPost(obj: Map<String, Any?>) {
        val id = validToken(Json.str(obj["id"]), 64) ?: return dropNotifyPost("id")
        // The system package (com.android.shell) or another system package
        // holding this notification is not the person's app; only real
        // application packages are forwarded.
        val pkg = validToken(Json.str(obj["pkg"]), 255) ?: return dropNotifyPost("pkg")
        val title = Json.str(obj["title"])?.takeIf { it.isNotEmpty() && it.length <= NotifyEvents.MAX_CHARS }
        val text = Json.str(obj["text"])?.takeIf { it.isNotEmpty() && it.length <= NotifyEvents.MAX_CHARS }
        if (title == null && text == null) return dropNotifyPost("empty content")
        val whenMs = Json.long(obj["when"])?.takeIf { it > 0 }
        val message = LinkedHashMap<String, Any?>()
        message["t"] = "notify.post"
        message["id"] = id
        message["pkg"] = pkg
        if (title != null) message["title"] = title
        if (text != null) message["text"] = text
        if (whenMs != null) message["when"] = whenMs
        sendJson(message)
    }

    /** Drops a notification event; the reason names a field, never the content. */
    private fun dropNotifyPost(why: String) {
        log("notify.post dropped: $why")
    }

    private fun deviceNotifyRemove(obj: Map<String, Any?>) {
        val id = validToken(Json.str(obj["id"]), 64) ?: run {
            log("notify.remove dropped: id")
            return
        }
        sendJson(mapOf("t" to "notify.remove", "id" to id))
    }

    private fun deviceMedia(obj: Map<String, Any?>) {
        val playing = Json.bool(obj["playing"]) ?: run {
            log("media.state dropped: playing")
            return
        }
        val message = LinkedHashMap<String, Any?>()
        message["t"] = "media.state"
        message["playing"] = playing
        Json.str(obj["pkg"])?.let { validToken(it, 255) }?.let { message["pkg"] = it }
        for (key in listOf("title", "artist", "album")) {
            Json.str(obj[key])?.takeIf { it.isNotEmpty() && it.length <= NotifyEvents.MAX_CHARS }?.let { message[key] = it }
        }
        Json.long(obj["durationMs"])?.takeIf { it in 1..(36L * 24 * 3600 * 1000) }?.let { message["durationMs"] = it }
        Json.long(obj["positionMs"])?.takeIf { it >= 0 }?.let { message["positionMs"] = it }
        if (playing) {
            val rate = (obj["rate"] as? Number)?.toDouble()
                ?: run { log("media.state dropped: rate"); return }
            if (rate !in 0.05..8.0) { log("media.state dropped: rate range"); return }
            message["rate"] = rate
        }
        sendJson(message)
    }

    private fun validToken(v: String?, maxLength: Int): String? {
        if (v == null || v.isEmpty() || v.length > maxLength) return null
        return if (v.all { it.isLetterOrDigit() || it in "._-" }) v else null
    }

    private fun onClipSet(obj: Map<String, Any?>) {
        val port = clipboard ?: return
        val text = Json.str(obj["text"]) ?: return
        if (!clipSync.accept(text)) {
            log("clip.set ignored (empty or over ${ClipSync.MAX_BYTES} bytes)")
            return
        }
        port.setText(text)
    }

    private fun onApkInstall(obj: Map<String, Any?>) {
        val installer = apk ?: run {
            sendJson(mapOf("t" to "apk.result", "id" to obj["id"], "ok" to false, "code" to "failed",
                "message" to "this phone can't install apps"))
            return
        }
        installer.begin(obj)
    }

    // ------------------------------------------------------------------
    // file drops (docs/design/dragdrop.md)
    // ------------------------------------------------------------------

    private fun onDropStart(obj: Map<String, Any?>) {
        val receiver = drop ?: run {
            sendJson(mapOf("t" to "drop.result", "id" to obj["id"], "ok" to false,
                "code" to "failed", "message" to "this phone can't receive files"))
            return
        }
        receiver.begin(obj)
    }

    // ------------------------------------------------------------------
    // clipboard images (docs/design/dragdrop.md)
    // ------------------------------------------------------------------

    private fun onClipImageStart(obj: Map<String, Any?>) {
        val id = (obj["id"] as? Number)?.toInt() ?: return
        val size = (obj["size"] as? Number)?.toLong() ?: -1L
        clipImageReceiver.begin(id, Json.str(obj["mime"]), size)
    }

    private fun onClipImageEnd(obj: Map<String, Any?>) {
        val id = (obj["id"] as? Number)?.toInt() ?: return
        val size = (obj["size"] as? Number)?.toLong() ?: -1L
        clipImageReceiver.end(id, size, Json.str(obj["sha256"]))
    }

    private fun onClipImageAbort(obj: Map<String, Any?>) {
        ((obj["id"] as? Number)?.toInt())?.let(clipImageReceiver::abort)
    }

    /**
     * A one-second poll of the clipboard for images: the text listener pushes text
     * changes, but an image item gives no callback at shell UID, and the phone's
     * clipboard needs no sub-second latency anyway.
     */
    private fun startClipImagePoll() {
        if (clipImagePoll != null) return
        val thread = Thread({ clipImageLoop() }, "pocketdeck-clippoll").also {
            it.isDaemon = true
            it.start()
        }
        clipImagePoll = thread
    }

    private fun stopClipImagePoll() {
        val thread = clipImagePoll ?: return
        clipImagePoll = null
        runCatching { thread.interrupt() }
    }

    private fun clipImageLoop() {
        while (!closed.get() && clipImagePoll === Thread.currentThread()) {
            val port = clipImages
            if (port != null) {
                val image = runCatching { port.readImage() }.getOrNull()
                if (image != null && clipImageSync.shouldSend(image) &&
                    !clipImageSender.send(image)) {
                    // The session died under the image; the poll ends with the thread.
                    return
                }
            }
            try {
                Thread.sleep(CLIP_IMAGE_POLL_MS)
            } catch (e: InterruptedException) {
                return
            }
        }
    }

    private fun onText(obj: Map<String, Any?>, frame: Frame) {
        val state = requireState(streamOf(obj, frame)) ?: return
        val text = Json.str(obj["text"]) ?: return
        injector.text(state.displayId, text)
    }

    private fun handleInput(frame: Frame) {
        when (frame.type) {
            Frames.TYPE_TOUCH -> {
                val p = Frames.decodeTouch(frame.payload)
                val state = requireState(frame.stream) ?: return
                val size = display.size(state.stream)
                val t = bumpTime(state)
                val downTime = if (p.action == Frames.TOUCH_DOWN) t else state.gestureDownTime
                if (p.action == Frames.TOUCH_DOWN) state.gestureDownTime = t
                injector.touch(state.displayId, p.action, p.pointerId, p.nx, p.ny, size, downTime, t)
                if (state.content != WindowContent.Phone) power.onInput(state.displayId)
            }
            Frames.TYPE_SCROLL -> {
                val p = Frames.decodeScroll(frame.payload)
                val state = requireState(frame.stream) ?: return
                injector.scroll(state.displayId, p.nx, p.ny, p.hscroll, p.vscroll, display.size(state.stream))
                if (state.content != WindowContent.Phone) power.onInput(state.displayId)
            }
            Frames.TYPE_HOVER -> {
                val p = Frames.decodeHover(frame.payload)
                val state = requireState(frame.stream) ?: return
                val size = display.size(state.stream)
                if (p.action == Frames.HOVER_MOVE) {
                    queueHoverMove(PendingHover(state.displayId, p.nx, p.ny, size))
                } else {
                    // Enter/exit run on the same thread as the moves, and the
                    // reader waits for them: an exit is injected before the
                    // TOUCH DOWN that follows it.
                    injectHoverNow(state.displayId, p.action, p.nx, p.ny, size)
                }
            }
            Frames.TYPE_APK_DATA -> apk?.data(frame.stream.toLong() and 0xFFFF_FFFFL, frame.payload)
            Frames.TYPE_DROP_DATA -> drop?.data(frame.stream.toLong() and 0xFFFF_FFFFL, frame.payload)
            Frames.TYPE_CLIP_DATA -> clipImageReceiver.data(frame.stream, frame.payload)
            Frames.TYPE_KEY -> {
                val p = Frames.decodeKey(frame.payload)
                val state = requireState(frame.stream) ?: return
                val t = bumpTime(state)
                val downTime = if (p.action == Frames.ACTION_DOWN) t else state.keyDownTime
                if (p.action == Frames.ACTION_DOWN) state.keyDownTime = t
                injector.key(state.displayId, p.action, p.keycode, p.metaState, downTime, t)
                if (state.content != WindowContent.Phone) power.onInput(state.displayId)
            }
            else -> logOnce("unknown frame type 0x${frame.type.toString(16)}")
        }
    }

    /**
     * Keeps only the newest hover move: while one is being injected, a later
     * one replaces the pending point instead of queueing behind it.
     */
    private fun queueHoverMove(move: PendingHover) {
        synchronized(hoverLock) {
            hoverPending = move
            if (hoverDraining) return
            hoverDraining = true
        }
        hoverExecutor.execute {
            while (true) {
                val next = synchronized(hoverLock) {
                    val pending = hoverPending
                    hoverPending = null
                    if (pending == null) hoverDraining = false
                    pending
                } ?: return@execute
                injector.hover(next.displayId, Frames.HOVER_MOVE, next.nx, next.ny, next.size)
            }
        }
    }

    /**
     * Enter/exit go through the hover thread too, and the reader waits for
     * them, so they cannot be overtaken by a move or by the touch that follows
     * an exit. A stale pending move is dropped first.
     */
    private fun injectHoverNow(displayId: Int, action: Int, nx: Float, ny: Float, size: IntSize) {
        synchronized(hoverLock) { hoverPending = null }
        val task = hoverExecutor.submit {
            injector.hover(displayId, action, nx, ny, size)
        }
        runCatching { task.get(100, TimeUnit.MILLISECONDS) }
    }

    /** Monotonic, strictly increasing event time; keeps a fresh downTime per gesture. */
    private fun bumpTime(state: StreamState): Long {
        val t = maxOf(now(), state.lastEventTime + 1)
        state.lastEventTime = t
        return t
    }

    // ------------------------------------------------------------------
    // video sink
    // ------------------------------------------------------------------

    override fun onConfig(stream: Int, codec: Int, w: Int, h: Int, csd: ByteArray) {
        val payload = Frames.encodeVideoConfig(VideoConfigPayload(codec, w, h, csd))
        queue.enqueueControl(stream, Frames.encode(Frames.TYPE_VIDEO_CONFIG, stream, payload))
    }

    override fun onFrame(stream: Int, ptsUs: Long, key: Boolean, data: ByteArray) {
        val payload = Frames.encodeVideoFrame(VideoFramePayload(ptsUs, key, data))
        val bytes = Frames.encode(Frames.TYPE_VIDEO_FRAME, stream, payload)
        if (key) queue.enqueueControl(stream, bytes) else queue.enqueueDelta(stream, ptsUs, bytes)
    }

    // ------------------------------------------------------------------
    // audio sink (device-wide, stream 0)
    // ------------------------------------------------------------------

    override fun onAudioConfig(codec: Int, sampleRate: Int, channels: Int, frameMs: Int, setup: ByteArray) {
        val payload = Frames.encodeAudioConfig(AudioConfigPayload(codec, sampleRate, channels, frameMs, setup))
        queue.enqueueControl(0, Frames.encode(Frames.TYPE_AUDIO_CONFIG, 0, payload))
        sendJson(mapOf("t" to "audio.state", "on" to true, "codec" to codec))
    }

    override fun onAudioFrame(ptsUs: Long, data: ByteArray) {
        val payload = Frames.encodeAudioFrame(AudioFramePayload(ptsUs, data))
        queue.enqueueAudio(Frames.encode(Frames.TYPE_AUDIO_FRAME, 0, payload))
    }

    private fun onAudioStart(obj: Map<String, Any?>) {
        val capture = audioCapture ?: return
        if (capture.isRunning) return
        if (windowCount() == 0) {
            log("audio.start with no windows: ignoring")
            return
        }
        val codecs = (obj["codecs"] as? List<*>)?.mapNotNull {
            when (it) {
                is Number -> it.toInt()
                is String -> it.toIntOrNull()
                else -> null
            }
        }?.filter { it == Frames.CODEC_OPUS || it == Frames.CODEC_AAC } ?: emptyList()
        runCatching {
            capture.start(
                sink = this,
                preferredCodecs = codecs.ifEmpty { listOf(Frames.CODEC_OPUS, Frames.CODEC_AAC) },
                windows = ::captureWindows,
            )
        }.onFailure { log("audio start failed: ${it.message}") }
    }

    private fun onAudioStop() {
        runCatching { audioCapture?.stop() }
        queue.clearAudio()
        sendJson(mapOf("t" to "audio.state", "on" to false, "codec" to 0))
    }

    /** Power rule: no windows left means no audio capture. */
    private fun stopAudioIfIdle() {
        if (windowCount() == 0 && (audioCapture?.isRunning == true)) {
            runCatching { audioCapture?.stop() }
            queue.clearAudio()
        }
    }

    // ------------------------------------------------------------------
    // audio follows the windows (docs/design/audio.md)
    // ------------------------------------------------------------------

    /**
     * One [CaptureWindow] per open window, the input to the follow decision:
     * phone-mode windows mean all audio, links fall back until Android picked
     * their app, our own launcher on top of a window is [CaptureWindow.Silent].
     */
    internal fun captureWindows(): List<CaptureWindow> = synchronized(streams) {
        streams.values.map { s ->
            when (val content = s.content) {
                WindowContent.Phone -> CaptureWindow.Phone
                is WindowContent.App -> attribute(s, content.pkg)
                is WindowContent.Link -> attribute(s, s.lastTitle?.pkg ?: "")
                else -> CaptureWindow.Silent
            }
        }
    }

    private fun attribute(s: StreamState, contentPkg: String): CaptureWindow {
        // A window the user re-launched (window.launch) shows the top app once
        // the polygon arrives; the content package is the launch default.
        val pkg = when {
            contentPkg.isNotEmpty() && s.lastTitle?.pkg == null -> contentPkg
            s.lastTitle?.pkg?.isNotEmpty() == true -> s.lastTitle!!.pkg
            else -> contentPkg
        }
        if (pkg == OWN_PACKAGE || pkg.isEmpty()) {
            return if (s.content is WindowContent.Link && pkg.isEmpty()) {
                CaptureWindow.Unresolved("link app not selected yet")
            } else {
                CaptureWindow.Silent
            }
        }
        return CaptureWindow.App(pkg)
    }

    /** Notifies the capture that the open windows changed (uid set / mode). */
    private fun notifyAudioWindowsChanged() {
        audioCapture?.let { runCatching { it.onWindowsChanged(this) } }
    }

    private fun onDeltaDrop(stream: Int) {
        log("stream $stream backpressure: dropping deltas, requesting keyframe")
        runCatching { display.requestKeyframe(stream) }
        runCatching { display.onBackpressure(stream) }
    }

    // ------------------------------------------------------------------
    // outbound helpers
    // ------------------------------------------------------------------

    private fun sendJson(obj: Map<String, Any?>) {
        queue.enqueueJson(Frames.encodeJson(0, Json.encode(obj)))
    }

    private fun sendError(code: String, message: String, stream: Int = 0) {
        sendJson(mapOf("t" to "error", "code" to code, "message" to message, "stream" to stream))
    }

    private fun rejectProtocol(why: String) {
        log("protocol error: $why")
        sendError("protocol", why)
        closeRequested = true
    }

    // ------------------------------------------------------------------
    // state watch
    // ------------------------------------------------------------------

    private fun startStateWatch() {
        if (stateHandle != null) return
        val handle = runCatching { device.subscribeState { stateTracker.update(it) } }.getOrNull()
        if (handle == null) {
            // No push source on this platform: the protocol still wants one
            // state right after welcome, but there are no updates to poll for.
            runCatching { device.state() }.getOrNull()?.let(stateTracker::update)
            return
        }
        stateHandle = handle
    }

    private fun stopStateWatch() {
        val handle = stateHandle ?: return
        stateHandle = null
        runCatching { handle.close() }
    }

    // ------------------------------------------------------------------
    // titles + app-exit watch
    // ------------------------------------------------------------------

    private fun startStreamWatch() {
        if (titleObserver == null && taskPresence == null) return
        if (watchThread != null) return
        watchThread = Thread({ streamWatchLoop() }, "pocketdeck-watch").also { it.start() }
    }

    /**
     * Polls the top app on each display (phone-mode `window.title`) and, at most
     * every [exitPollIntervalMs], whether an app window's display still has a
     * task. It performs no query at all while there are no streams (the task list
     * is only polled while ≥1 stream is open and unpaused).
     */
    private fun streamWatchLoop() {
        var lastExitCheck = 0L
        while (!closed.get()) {
            val snapshot = synchronized(streams) { streams.values.toList() }
            if (snapshot.isNotEmpty()) {
                val unpaused = snapshot.filter { !it.paused }

                titleObserver?.let { observer ->
                    var titlesChanged = false
                    for (s in unpaused) {
                        val top = runCatching { observer.topApp(s.displayId) }.getOrNull() ?: continue
                        if (top != s.lastTitle) {
                            s.lastTitle = top
                            titlesChanged = true
                            sendJson(mapOf("t" to "window.title", "stream" to s.stream, "label" to top.label, "pkg" to top.pkg))
                        }
                    }
                    // A window's top app changed: the audio follow plan does
                    // too (e.g. a link's app just resolved, or window.launch
                    // switched the shown app).
                    if (titlesChanged) notifyAudioWindowsChanged()
                }

                if (taskPresence != null && unpaused.isNotEmpty()) {
                    val nowMs = System.currentTimeMillis()
                    if (nowMs - lastExitCheck >= exitPollIntervalMs) {
                        lastExitCheck = nowMs
                        checkAppExit(unpaused)
                    }
                }
            }

            synchronized(pairLock) { if (!closed.get()) runCatching { pairLock.wait(1_000) } }
        }
    }

    private fun checkAppExit(candidates: List<StreamState>) {
        val presence = taskPresence ?: return
        val previous = HashMap<Int, Boolean>()
        val current = HashMap<Int, Boolean>()
        for (s in candidates) {
            // The phone mirror shows display 0 and never auto-closes.
            if (s.content == null || s.content == WindowContent.Phone) continue
            val hasTask = runCatching { presence.hasTask(s.displayId) }.getOrNull() ?: continue
            previous[s.stream] = s.hadTask
            current[s.stream] = hasTask
            s.hadTask = hasTask
        }
        for (stream in AppExit.exited(previous, current)) closeAppExited(stream)
    }

    private fun closeAppExited(stream: Int) {
        val state = synchronized(streams) { streams.remove(stream) } ?: return
        display.close(stream)
        sendJson(mapOf("t" to "window.closed", "stream" to stream, "reason" to "app_exited"))
        power.setActiveStreams(activeDisplayIds())
        stopAudioIfIdle()
        notifyAudioWindowsChanged()
        runCatching { callback.onSessionChanged(true, currentMacName ?: clientName, windowCount()) }
        log("closed stream $stream: app exited (display ${state.displayId})")
    }

    private fun stopStreamWatch() {
        synchronized(pairLock) { pairLock.notifyAll() }
        runCatching { watchThread?.interrupt() }
        watchThread = null
    }

    // ------------------------------------------------------------------
    // small helpers
    // ------------------------------------------------------------------

    /** Reports `no_stream` (without closing) when the stream id is unknown. */
    private fun requireState(stream: Int): StreamState? {
        val s = synchronized(streams) { streams[stream] }
        if (s == null) sendError("no_stream", "unknown stream $stream", stream)
        return s
    }

    private fun windowCount(): Int = synchronized(streams) { streams.size }

    /** Displays the keep-alive owns. Never display 0: the mirror leaves the phone's power alone. */
    private fun activeDisplayIds(): List<Int> = synchronized(streams) {
        streams.values.filter { !it.paused && it.content != WindowContent.Phone }.map { it.displayId }
    }

    private fun streamOf(obj: Map<String, Any?>, frame: Frame): Int =
        Json.int(obj["stream"]) ?: frame.stream

    private fun launchOn(stream: Int, displayId: Int, pkg: String, activity: String?) {
        if (displayId < 0) return
        val ok = runCatching { launcher.launch(displayId, pkg, activity) }.getOrDefault(false)
        if (!ok) {
            sendError("launch_failed", "could not launch $pkg", stream)
            log("launch $pkg failed on display $displayId")
        }
    }

    private fun viewOn(stream: Int, displayId: Int, url: String) {
        if (displayId < 0) return
        val ok = runCatching { launcher.view(displayId, url) }.getOrDefault(false)
        if (!ok) {
            sendError("launch_failed", "no app opens this link", stream)
            log("view link failed on display $displayId")
        }
    }

    private fun logOnce(message: String) {
        if (loggedUnknown.add(message)) log(message)
    }

    companion object {
        const val PROTOCOL_VERSION = 2
        const val OWN_PACKAGE = "dev.pocketdeck"
        const val PHONE_DISPLAY = 0
        const val KEYCODE_BACK = 4
        const val KEYCODE_HOME = 3
        const val KEYCODE_APP_SWITCH = 187

        /** The phone's own screen: where "Continue on Mac" looks. */
        const val PHONE_DISPLAY_ID = 0

        /** The clipboard-image poll: images are user-paced, not sub-second. */
        const val CLIP_IMAGE_POLL_MS = 1_000L

        /** Bounds the kernel's video backlog so the delta-drop rule can fire. */
        const val SEND_BUFFER_BYTES = 128 * 1024

        /** Virtual displays and encoders need dimensions that are multiples of 16. */
        fun floor16(v: Int): Int = if (v <= 0) 0 else (v / 16) * 16
    }
}
