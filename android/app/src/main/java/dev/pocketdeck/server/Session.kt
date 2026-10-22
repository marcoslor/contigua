package dev.pocketdeck.server

import dev.pocketdeck.app.MediaArtRules
import dev.pocketdeck.app.MediaControl
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
import java.io.File
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
    /** Shared-storage root for read-only phone files (docs/design/files.md); null refuses fs.*. */
    private val filesRoot: File? = null,
    /** Metadata source for fs.*; the tests hand in a deterministic one. */
    private val fsStats: FsStats = FsStats.Default,
    /** Rename/scan seam for writes (docs/design/files.md §2); tests fake it. */
    private val fsPlatform: FsPlatform = FsPlatform.None,
    /** Change source for `fs.watch` (docs/design/files.md §5); tests fake it. */
    private val fsWatch: FsWatchSource = FsWatchSource.None,
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
    /** Process-wide quiet window after a denied/timed-out prompt (review M-1). */
    private val pairCooldown: PairCooldown = PairCooldown(),
    private val selfCertProvider: () -> String = { "" },
    /**
     * The scanned QR the app handed over (map shape as Prefs.PendingQr), or
     * null. The shell answers the Mac's probe with pair.qr when the connected
     * Mac's TLS fingerprint matches `macFp` (R2).
     */
    private val pendingQrProvider: () -> Map<String, Any?>? = { null },
    /** Drops the shell's copy of the QR once it was served (review L-3). */
    private val pendingQrConsumer: () -> Unit = {},
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
    /** `media.command`: the validated command as JSON, for the app process. */
    private val mediaCommand: ((String) -> Unit)? = null,
    /** `media.choose`: which phone session Now Playing follows. */
    private val mediaChoose: ((String) -> Unit)? = null,
    private val notifyForward: ((Boolean) -> Unit)? = null,
    /** Asks the app for the forwarded notification's action; it answers over AIDL. */
    private val notifyOpen: ((String, Int) -> Unit)? = null,
    /** `notify.action`: press an advertised action (id, index, reply text). */
    private val notifyAction: ((String, Int, String?) -> Unit)? = null,
    /** `notify.dismiss`: clear the forwarded notification on the phone. */
    private val notifyDismiss: ((String) -> Unit)? = null,
    /** `phone.ring` (docs/PROTOCOL.md "Ring"); null refuses it. */
    private val ringer: Ringer? = null,
    /** The phone's DND, shared by the service (docs/design/focus.md); null refuses `phone.dnd`. */
    private val zen: ZenControl? = null,
    /** The phone's ringer mode (docs/design/controls.md); null refuses `phone.ringer`. */
    private val ringerMode: RingerControl? = null,
    /** STREAM_MUSIC's level (docs/PROTOCOL.md "Volume"); null refuses `phone.volume`. */
    private val volume: VolumeControl? = null,
    /**
     * Display 0's secure-surface state (`state.secure`, docs/PROTOCOL.md "Secure
     * screens"); null never reports it (tests, or a phone that cannot read it).
     */
    private val secureProbe: SecureProbe? = null,
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
    /** Read-only phone files; absent on a platform without shared storage. */
    private val files = filesRoot?.let { root ->
        runCatching { FsView(FsPaths(root, fsStats)) }.getOrElse {
            // A storage root that cannot be resolved must not cost the session:
            // fs.* then answers fs_denied, everything else works.
            log("fs: the shared-storage root is unavailable (${it.javaClass.simpleName})")
            null
        }
    }
    private val fsReader = files?.let { FsReader(it.paths, queue::enqueueBulk, ::sendJson, log) }
    private val fsWriter = files?.let { FsWriter(it.paths, fsPlatform, ::sendJson, log) }
    private val fsOps = files?.let { FsMutations(it.paths, fsPlatform, log) }
    private val fsWatcher = files?.let {
        FsWatcher(it.paths, fsWatch, ::sendJson, log = log)
    }
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

    /** `state.panel` is the phone's hold (PanelHold.kt), never a local guess. */

    private var writerThread: Thread? = null
    private var stateHandle: AutoCloseable? = null
    private var dndHandle: AutoCloseable? = null
    private var ringerHandle: AutoCloseable? = null
    private var volumeHandle: AutoCloseable? = null
    private var watchThread: Thread? = null

    /** The protocol's `state` stream: one emission per real change. */
    private val stateTracker = DeviceStateTracker { state -> sendState(state) }

    private fun sendState(state: DeviceState) {
        val message = linkedMapOf<String, Any?>(
            "t" to "state",
            "locked" to state.locked,
            "battery" to state.battery,
            "charging" to state.charging,
        )
        // Absent (not null) for a phone that cannot read its zen mode / ringer / screen.
        state.dnd?.let { message["dnd"] = it.wire }
        state.ringer?.let { message["ringer"] = it.wire }
        state.screen?.let { message["screen"] = it.wire }
        state.secure?.let { message["secure"] = it }
        // Both or neither: an old phone omits the pair, and the Mac then
        // disables its slider with a reason instead of guessing a level.
        if (state.volume != null && state.volumeMax != null) {
            message["volume"] = state.volume
            message["volumeMax"] = state.volumeMax
        }
        // The phone's panel, when the person's Mac holds it off for the mirror.
        message["panel"] = if (power.panelHeldOff) "off" else "on"
        sendJson(message)
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
        // The hold decides `state.panel` on its own (the person's power
        // button, a paused window, the session ending): tell the Mac at once.
        power.onPanelChanged = { _ ->
            val state = stateTracker.current ?: device.state()
            if (!stateTracker.update(state)) sendState(state)
        }
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
        runCatching { fsReader?.close() }
        runCatching { fsWriter?.close() }
        runCatching { fsWatcher?.close() }
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
        runCatching { power.onPanelChanged = null }
        queue.close()
        runCatching { writerThread?.join(1000) }
        runCatching { socket.close() }
        if (phase == Phase.READY) runCatching { callback.onSessionChanged(false, clientId.ifEmpty { null }, null, 0) }
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
        // M-1: the last prompt was denied or timed out. Refuse this attempt
        // with the protocol's existing denial code instead of prompting again.
        if (pairCooldown.active()) {
            log("pair.request refused: cooling down after a denied prompt")
            finishWithError("pair_denied", "pairing denied")
            return
        }
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
        // One-time: a second hello with the same QR secret must not be answered
        // (review L-3). The app's stored copy expires with its TTL.
        runCatching { pendingQrConsumer() }
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
        // The code itself never reaches a log (rule: hashes/lengths only).
        log("pair code shown on the phone: ${codeStr.length} digits")
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
        // M-1: nobody answered; keep the phone quiet for a moment so a peer
        // cannot retry the prompt in a tight loop.
        pairCooldown.start()
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
        if (allow) {
            completePairing()
        } else {
            // M-1: a Deny is a decision about this Mac; hold off new prompts.
            pairCooldown.start()
            finishWithError("pair_denied", "pairing denied")
        }
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
        runCatching { callback.onSessionChanged(true, clientId, currentMacName ?: clientName, windowCount()) }
        startStateWatch()
        startClipboardSync()
        startClipImagePoll()
    }

    /**
     * The READY-phase router. A handler failure is a failed message, not a
     * failed session: one unsupported or vendor-broken request must not close
     * every window. The handshake phases keep their fail-closed behaviour.
     */
    private fun dispatch(obj: Map<String, Any?>, frame: Frame, t: String) {
        try {
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
                "fs.list" -> onFsList(obj)
                "fs.stat" -> onFsStat(obj)
                "fs.read" -> onFsRead(obj)
                "fs.write" -> fsWriter?.begin(obj)
                "fs.move" -> onFsMove(obj)
                "fs.delete" -> onFsDelete(obj)
                "fs.mkdir" -> onFsMkdir(obj)
                "fs.setAttrs" -> onFsSetAttrs(obj)
                "fs.watch" -> onFsWatch(obj, on = true)
                "fs.unwatch" -> onFsWatch(obj, on = false)
                "fs.cancel" -> (obj["id"] as? Number)?.toLong()?.let {
                    fsReader?.cancel(it)
                    fsWriter?.cancel(it)
                }
                "clip.image.start" -> onClipImageStart(obj)
                "clip.image.end" -> onClipImageEnd(obj)
                "clip.image.abort" -> onClipImageAbort(obj)
                "audio.start" -> onAudioStart(obj)
                "audio.stop" -> onAudioStop()
                "notify.enable" -> onNotifyEnable(obj)
                "notify.open" -> onNotifyOpen(obj, frame)
                "notify.action" -> onNotifyAction(obj)
                "notify.dismiss" -> onNotifyDismiss(obj)
                "media.command" -> onMediaCommand(obj)
                "media.choose" -> onMediaChoose(obj)
                "phone.ring" -> onPhoneRing(obj)
                "phone.ring.stop" -> onPhoneRingStop()
                "phone.dnd" -> onPhoneDnd(obj)
                "phone.ringer" -> onPhoneRinger(obj)
                "phone.volume" -> onPhoneVolume(obj)
                "phone.wake" -> onPhoneWake()
                "phone.panel" -> onPhonePanel(obj)
                else -> logOnce("unknown message '$t'")
            }
        } catch (e: Throwable) {
            // A broken VM is not a message failure; let run() end the session.
            if (e is VirtualMachineError) throw e
            // Type and exception only: payloads (clipboard text, URLs,
            // notification text) never reach the log.
            log("handler $t failed: ${e.javaClass.simpleName}: ${e.message}")
            sendError("internal", "$t failed", streamOf(obj, frame))
        }
    }

    private fun onAppsList() {
        val apps = catalog.list().map { mapOf("pkg" to it.pkg, "label" to it.label, "activity" to it.activity) }
        sendJson(mapOf("t" to "apps", "apps" to apps))
    }

    private fun onAppsIcon(obj: Map<String, Any?>) {
        val pkg = Json.str(obj["pkg"]) ?: return
        // `px` is optional (docs/PROTOCOL.md): the Mac asks for the size it will
        // draw; an old Mac asks for none and gets the historical 96/216 px.
        val px = Json.int(obj["px"])
        // The layers ride along as optional fields; a non-adaptive icon sends
        // none and an old Mac just ignores them.
        val fields = LinkedHashMap<String, Any?>()
        fields["t"] = "icon"
        fields["pkg"] = pkg
        fields["png"] = catalog.iconPng(pkg, px) ?: ""
        catalog.iconLayers(pkg, px)?.let { layers ->
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
        updatePower()
        runCatching { callback.onSessionChanged(true, clientId, currentMacName ?: clientName, windowCount()) }
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
        updatePower()
        runCatching { callback.onSessionChanged(true, clientId, currentMacName ?: clientName, windowCount()) }
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
        updatePower()
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
        updatePower()
        stopAudioIfIdle()
        notifyAudioWindowsChanged()
        runCatching { callback.onSessionChanged(true, clientId, currentMacName ?: clientName, windowCount()) }
        log("closed stream $stream (display ${state.displayId})")
    }

    private fun onWindowPause(obj: Map<String, Any?>, frame: Frame) {
        val state = requireState(streamOf(obj, frame)) ?: return
        if (!state.paused) {
            state.paused = true
            display.pause(state.stream)
            updatePower(paused = true)
        }
    }

    private fun onWindowResume(obj: Map<String, Any?>, frame: Frame) {
        val state = requireState(streamOf(obj, frame)) ?: return
        if (state.paused) {
            state.paused = false
            display.resume(state.stream)
            updatePower()
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

    /**
     * `notify.action`: press one of the actions the phone advertised in
     * `notify.post`. The shell validates the id, the index and the text cap; the
     * app process is the one that knows whether the index is a reply action and
     * logs `notify.action unknown` without the text (docs/design/notify.md).
     */
    private fun onNotifyAction(obj: Map<String, Any?>) {
        if (!notifyForwarding) {
            logOnce("notify.action dropped (not forwarding)")
            return
        }
        val id = validToken(Json.str(obj["id"]), 64) ?: run {
            log("notify.action dropped: id")
            return
        }
        val index = Json.long(obj["i"])?.toInt() ?: run {
            log("notify.action dropped: i")
            return
        }
        if (index < 0 || index > MAX_ACTION_INDEX) {
            log("notify.action dropped: i")
            return
        }
        val text = Json.str(obj["text"])?.takeIf { it.isNotEmpty() }
        if (text != null && text.length > NotifyEvents.MAX_REPLY_CHARS) {
            log("notify.action refused: text cap")
            return
        }
        val action = notifyAction ?: run {
            logOnce("notify.action dropped (no consumer)")
            return
        }
        action(id, index, text)
        log("notify.action id=$id i=$index textLen=${text?.length ?: 0}")
    }

    /** `notify.dismiss`: clear the forwarded notification on the phone. */
    private fun onNotifyDismiss(obj: Map<String, Any?>) {
        if (!notifyForwarding) {
            logOnce("notify.dismiss dropped (not forwarding)")
            return
        }
        val id = validToken(Json.str(obj["id"]), 64) ?: run {
            log("notify.dismiss dropped: id")
            return
        }
        val dismiss = notifyDismiss ?: run {
            logOnce("notify.dismiss dropped (no consumer)")
            return
        }
        dismiss(id)
        log("notify.dismiss id=$id")
    }

    /**
     * `media.command` (docs/design/notify.md, "Media part 2"): a transport
     * control, a seek or a volume level, optionally for one session key. The
     * shell validates what the wire can carry; the app process clamps the
     * position to the track and the level to the session's own maximum and
     * logs the value it used. A command without a key acts on the chosen
     * session, exactly as an older Mac's does.
     */
    private fun onMediaCommand(obj: Map<String, Any?>) {
        val action = Json.str(obj["action"])
        if (action == null || NotifyEvents.validMediaCommand(action) == null) {
            logOnce("media.command dropped (unknown action)")
            return
        }
        val command = LinkedHashMap<String, Any?>()
        command["action"] = action
        validToken(Json.str(obj["key"]), MediaControl.MAX_KEY)?.let { command["key"] = it }
        when (action) {
            "seek" -> {
                val position = Json.long(obj["positionMs"])?.takeIf { it in 0..MediaControl.MAX_POSITION_MS }
                    ?: run {
                        log("media.command dropped: positionMs")
                        return
                    }
                command["positionMs"] = position
            }
            "volume" -> {
                val level = (obj["level"] as? Number)?.toInt()?.takeIf { it in 0..MediaControl.MAX_LEVEL }
                    ?: run {
                        log("media.command dropped: level")
                        return
                    }
                command["level"] = level
            }
        }
        val driver = mediaCommand ?: run {
            logOnce("media.command dropped (no consumer)")
            return
        }
        driver(Json.encode(command))
        log("media.command ${command["action"]} key=${command["key"] ?: "-"}")
    }

    /** `media.choose`: pick the session Now Playing follows; the phone confirms. */
    private fun onMediaChoose(obj: Map<String, Any?>) {
        val key = validToken(Json.str(obj["key"]), MediaControl.MAX_KEY) ?: run {
            log("media.choose dropped: key")
            return
        }
        val choose = mediaChoose ?: run {
            logOnce("media.choose dropped (no consumer)")
            return
        }
        choose(key)
        log("media.choose key=$key")
    }

    /**
     * `phone.ring` (docs/PROTOCOL.md "Ring"): the app process rings for `seconds`
     * (1..30, default 30). The shell never rings itself — it has no UI or audio.
     */
    private fun onPhoneRing(obj: Map<String, Any?>) {
        val ringer = ringer ?: run {
            sendError("unsupported", "phone.ring needs the app process", 0)
            return
        }
        val seconds = ((Json.long(obj["seconds"]) ?: 30L).toInt()).coerceIn(1, 30)
        ringer.start(seconds)
        sendJson(mapOf("t" to "ring.state", "ringing" to true))
    }

    private fun onPhoneRingStop() {
        ringer?.stop() ?: run {
            sendError("unsupported", "phone.ring needs the app process", 0)
            return
        }
        sendJson(mapOf("t" to "ring.state", "ringing" to false))
    }

    /**
     * `phone.dnd` (docs/PROTOCOL.md "Focus and Do Not Disturb"): the one write
     * path is the shell's `cmd notification set_dnd`. The session answers with
     * a fresh `state`, which carries the mode the phone actually reports.
     */
    private fun onPhoneDnd(obj: Map<String, Any?>) {
        val control = zen ?: run {
            sendError("unsupported", "phone.dnd needs the shell service", 0)
            return
        }
        val mode = DndMode.fromWire(Json.str(obj["mode"])) ?: run {
            sendError("bad_request", "phone.dnd needs mode priority, alarms, none or off", 0)
            return
        }
        control.apply(mode)
        // The design's answer is a new `state` even when the mode did not move
        // (the person's own DND is left alone but the Mac still gets the truth).
        val state = (stateTracker.current ?: device.state()).copy(dnd = control.current())
        if (!stateTracker.update(state)) sendState(state)
    }

    /**
     * `phone.ringer` (docs/design/controls.md): one ringer mode, written with
     * the shell's `cmd audio set-ringer-mode`. The answer is a fresh `state`
     * carrying the mode the phone actually reports; nothing else is touched.
     */
    private fun onPhoneRinger(obj: Map<String, Any?>) {
        val control = ringerMode ?: run {
            sendError("unsupported", "phone.ringer needs the shell service", 0)
            return
        }
        val mode = RingerMode.fromWire(Json.str(obj["mode"])) ?: run {
            sendError("bad_request", "phone.ringer needs mode normal, vibrate or silent", 0)
            return
        }
        when (control.apply(mode)) {
            RingerControl.Result.SET, RingerControl.Result.SAME -> {
                val state = (stateTracker.current ?: device.state()).copy(ringer = control.current())
                if (!stateTracker.update(state)) sendState(state)
            }
            RingerControl.Result.REFUSED_DND ->
                sendError("dnd_on", "phone.ringer needs Do Not Disturb off", 0)
            RingerControl.Result.REFUSED ->
                sendError("unavailable", "the phone refused the ringer mode", 0)
            RingerControl.Result.UNREADABLE ->
                sendError("unsupported", "phone.ringer cannot read the ringer mode", 0)
        }
    }

    /**
     * `phone.volume` (docs/PROTOCOL.md "Volume"): clamp the level to the
     * stream's maximum, write STREAM_MUSIC with no UI flag, and answer with the
     * state the phone reports afterwards.
     */
    private fun onPhoneVolume(obj: Map<String, Any?>) {
        val control = volume ?: run {
            sendError("unsupported", "phone.volume needs the shell service", 0)
            return
        }
        val level = Json.int(obj["level"]) ?: run {
            sendError("bad_request", "phone.volume needs level", 0)
            return
        }
        if (!control.apply(level)) {
            sendError("unavailable", "the phone refused the volume level", 0)
            return
        }
        val state = (stateTracker.current ?: device.state())
            .copy(volume = control.current(), volumeMax = control.max())
        if (!stateTracker.update(state)) sendState(state)
    }

    /**
     * `phone.wake` (docs/PROTOCOL.md "Phone screen"): wake display 0 once, never
     * unlocking it. The outcome is logged by name; the answer is the state the
     * phone reports afterwards, which carries the `screen` the panel is in.
     */
    private fun onPhoneWake() {
        val result = power.wakeScreen()
        log("phone.wake ${result.wire}")
        // The display changes a moment after the wake; the listener sends the
        // real transition. This answer is the state as it is now.
        val fresh = device.state()
        val state = (stateTracker.current ?: fresh).copy(screen = fresh.screen)
        if (!stateTracker.update(state)) sendState(state)
    }

    /**
     * `phone.panel` (docs/PROTOCOL.md "Phone screen"): the person's Mac asked
     * for the mirrored panel to stay off while the phone window keeps
     * rendering, or for it to come back. It only means something with a phone
     * window open, and the person's power button on the phone always wins.
     */
    private fun onPhonePanel(obj: Map<String, Any?>) {
        val off = obj["off"] as? Boolean ?: run {
            sendError("bad_request", "phone.panel needs off: true|false")
            return
        }
        val ignorePower = obj["ignorePower"] as? Boolean ?: false
        if (!hasPhoneWindow()) {
            sendError("bad_request", "phone.panel needs an open phone window")
            return
        }
        if (!power.setMirrorPanelOff(off, ignorePower)) {
            sendError("unavailable", "this phone can't control its panel")
            return
        }
        log(if (off) "phone.panel off" else "phone.panel on")
        // The hold reports `state.panel` itself, here and whenever it changes
        // on its own; a request that changes nothing sends nothing.
    }

    /** True while a phone window stream is open (paused or not). */
    private fun hasPhoneWindow(): Boolean =
        synchronized(streams) { streams.values.any { it.content == WindowContent.Phone } }

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
            "media.sessions" -> deviceMediaSessions(obj)
            "media.art" -> deviceMediaArt(obj)
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
        val ongoing = Json.bool(obj["ongoing"]) == true
        val actions = validActions(obj["actions"])
        val message = LinkedHashMap<String, Any?>()
        message["t"] = "notify.post"
        message["id"] = id
        message["pkg"] = pkg
        if (title != null) message["title"] = title
        if (text != null) message["text"] = text
        if (whenMs != null) message["when"] = whenMs
        if (ongoing) message["ongoing"] = true
        if (actions.isNotEmpty()) message["actions"] = actions
        sendJson(message)
    }

    /**
     * Re-validates the `actions` the app process built: an index in the phone's
     * array, a non-empty capped title, at most three, and `reply` only when true.
     * A malformed entry is dropped; the rest still go out.
     */
    private fun validActions(raw: Any?): List<Map<String, Any?>> {
        val list = raw as? List<*> ?: return emptyList()
        val kept = ArrayList<Map<String, Any?>>(NotifyEvents.MAX_ACTIONS)
        for (entry in list) {
            if (kept.size == NotifyEvents.MAX_ACTIONS) break
            val map = entry as? Map<*, *> ?: continue
            val index = (map["i"] as? Number)?.toInt() ?: continue
            if (index < 0 || index > MAX_ACTION_INDEX) continue
            val title = Json.str(map["title"])?.trim()?.take(NotifyEvents.MAX_ACTION_TITLE) ?: continue
            if (title.isEmpty()) continue
            val action = LinkedHashMap<String, Any?>()
            action["i"] = index
            action["title"] = title
            if (Json.bool(map["reply"]) == true) action["reply"] = true
            kept += action
        }
        return kept
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
        validToken(Json.str(obj["key"]), MediaControl.MAX_KEY)?.let { message["key"] = it }
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
        // "Media part 2" fields: an older Mac ignores them, an older phone
        // never sends them.
        if (Json.bool(obj["canSeek"]) == true) message["canSeek"] = true
        val volumeMax = (obj["volumeMax"] as? Number)?.toInt()?.takeIf { it in 1..MediaControl.MAX_LEVEL }
        if (volumeMax != null) {
            message["volumeMax"] = volumeMax
            (obj["volume"] as? Number)?.toInt()?.coerceIn(0, volumeMax)?.let { message["volume"] = it }
        }
        sendJson(message)
    }

    /**
     * `media.sessions`: the active sessions in the system's order and the chosen
     * key. Keys, packages, app labels and playing flags only — never a title.
     */
    private fun deviceMediaSessions(obj: Map<String, Any?>) {
        val raw = obj["list"] as? List<*> ?: run {
            log("media.sessions dropped: list")
            return
        }
        val list = ArrayList<Map<String, Any?>>(minOf(raw.size, MediaControl.MAX_SESSIONS))
        for (entry in raw) {
            if (list.size == MediaControl.MAX_SESSIONS) break
            val map = entry as? Map<*, *> ?: continue
            val key = validToken(Json.str(map["key"]), MediaControl.MAX_KEY) ?: continue
            val pkg = validToken(Json.str(map["pkg"]), 255) ?: continue
            val app = Json.str(map["app"])?.trim()?.take(MediaControl.MAX_APP)?.takeIf { it.isNotEmpty() } ?: pkg
            val item = LinkedHashMap<String, Any?>()
            item["key"] = key
            item["pkg"] = pkg
            item["app"] = app
            item["playing"] = Json.bool(map["playing"]) == true
            list += item
        }
        val message = LinkedHashMap<String, Any?>()
        message["t"] = "media.sessions"
        message["list"] = list
        validToken(Json.str(obj["chosen"]), MediaControl.MAX_KEY)?.let { message["chosen"] = it }
        sendJson(message)
        log("media.sessions n=${list.size} chosen=${message["chosen"] ?: "-"}")
    }

    /**
     * `media.art`: the chosen session's picture for one key. The Mac takes JPEG
     * up to 512 px and 256 KiB and shows nothing else. No data clears it.
     */
    private fun deviceMediaArt(obj: Map<String, Any?>) {
        val key = validToken(Json.str(obj["key"]), MediaControl.MAX_KEY) ?: run {
            log("media.art dropped: key")
            return
        }
        val message = LinkedHashMap<String, Any?>()
        message["t"] = "media.art"
        message["key"] = key
        val data = Json.str(obj["data"])
        if (!data.isNullOrEmpty()) {
            if (Json.str(obj["mime"]) != "image/jpeg") return dropMediaArt("mime")
            val width = (obj["w"] as? Number)?.toInt() ?: return dropMediaArt("w")
            val height = (obj["h"] as? Number)?.toInt() ?: return dropMediaArt("h")
            if (width !in 1..MediaArtRules.MAX_SIDE || height !in 1..MediaArtRules.MAX_SIDE) {
                return dropMediaArt("size")
            }
            val bytes = runCatching { android.util.Base64.decode(data, android.util.Base64.DEFAULT) }
                .getOrNull() ?: return dropMediaArt("data")
            if (bytes.isEmpty() || bytes.size > MediaArtRules.MAX_BYTES) return dropMediaArt("bytes")
            message["mime"] = "image/jpeg"
            message["w"] = width
            message["h"] = height
            message["data"] = data
        }
        sendJson(message)
        log("media.art key=$key bytes=${data?.length ?: 0}")
    }

    private fun dropMediaArt(why: String) {
        log("media.art dropped: $why")
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
    // read-only phone files (docs/design/files.md)
    // ------------------------------------------------------------------

    /** A request id: u32, never 0; anything else is ignored (no reply to match). */
    private fun fsId(obj: Map<String, Any?>): Long? {
        val id = (obj["id"] as? Number)?.toLong() ?: return null
        return if (id in 1..0xFFFF_FFFFL) id else null
    }

    /** An fs failure: the ordinary `error` frame, carrying the request id. */
    private fun fsError(id: Long, failure: FsFailure) {
        log("fs: id=$id ${failure.code}")
        sendJson(mapOf("t" to "error", "code" to failure.code,
            "message" to (failure.message ?: ""), "id" to id))
    }

    private fun onFsList(obj: Map<String, Any?>) {
        val id = fsId(obj) ?: return
        val view = files ?: return fsError(id, FsPaths.denied("files are not served"))
        try {
            val page = view.list(Json.str(obj["path"]), Json.str(obj["page"]))
            sendJson(mapOf(
                "t" to "fs.items",
                "id" to id,
                "page" to page.next,
                "items" to page.items.map { it.toJson() },
            ))
            log("fs: list id=$id ${page.items.size} items, next=${page.next != null}")
        } catch (e: FsFailure) {
            fsError(id, e)
        } catch (e: Exception) {
            // A reply always carries its id, even when the filesystem throws
            // something the path rules do not name.
            log("fs: list id=$id failed: ${e.javaClass.simpleName}")
            fsError(id, FsFailure("internal", "the listing failed"))
        }
    }

    private fun onFsRead(obj: Map<String, Any?>) {
        val reader = fsReader
        if (reader == null) {
            fsId(obj)?.let { fsError(it, FsPaths.denied("files are not served")) }
            return
        }
        reader.begin(obj)
    }

    private fun onFsStat(obj: Map<String, Any?>) {
        val id = fsId(obj) ?: return
        val view = files ?: return fsError(id, FsPaths.denied("files are not served"))
        try {
            sendJson(mapOf("t" to "fs.item", "id" to id, "item" to view.stat(Json.str(obj["path"])).toJson()))
            log("fs: stat id=$id")
        } catch (e: FsFailure) {
            fsError(id, e)
        } catch (e: Exception) {
            log("fs: stat id=$id failed: ${e.javaClass.simpleName}")
            fsError(id, FsFailure("internal", "the stat failed"))
        }
    }

    /** A write-op refusal or result: `fs.result`, always carrying its id. */
    private fun fsResult(id: Long, item: FsItem?, failure: FsFailure? = null) {
        if (failure != null) {
            log("fs: id=$id ${failure.code}")
            sendJson(mapOf("t" to "fs.result", "id" to id, "ok" to false,
                "code" to failure.code, "message" to (failure.message ?: "")))
            return
        }
        sendJson(mapOf("t" to "fs.result", "id" to id, "ok" to true,
            "item" to item?.toJson(), "etag" to item?.etag))
    }

    /** The common shape of move/delete/mkdir/setAttrs: one op, one result. */
    private fun fsMutation(obj: Map<String, Any?>, op: (FsMutations) -> FsItem?) {
        val id = FsMutations.id(obj) ?: return
        val ops = fsOps ?: return fsResult(id, null, FsPaths.denied("files are not served"))
        try {
            fsResult(id, op(ops))
        } catch (e: FsFailure) {
            fsResult(id, null, e)
        } catch (e: Exception) {
            log("fs: mutation $id failed: ${e.javaClass.simpleName}")
            fsResult(id, null, FsFailure("internal", "the operation failed"))
        }
    }

    private fun onFsMove(obj: Map<String, Any?>) = fsMutation(obj) { ops ->
        ops.move(Json.str(obj["from"]), Json.str(obj["to"]), Json.str(obj["etag"]))
    }

    private fun onFsDelete(obj: Map<String, Any?>) = fsMutation(obj) { ops ->
        ops.delete(Json.str(obj["path"]), Json.bool(obj["recursive"]) ?: false,
            Json.str(obj["etag"]))
        null
    }

    private fun onFsMkdir(obj: Map<String, Any?>) = fsMutation(obj) { ops ->
        ops.mkdir(Json.str(obj["path"]))
    }

    private fun onFsSetAttrs(obj: Map<String, Any?>) = fsMutation(obj) { ops ->
        ops.setAttrs(Json.str(obj["path"]), FsMutations.mtime(obj))
    }

    /**
     * `fs.watch` / `fs.unwatch` (docs/design/files.md §5): the Mac's open
     * folders, nothing more. The reply is the usual `fs.result`; the paths are
     * never logged.
     */
    private fun onFsWatch(obj: Map<String, Any?>, on: Boolean) {
        val id = fsId(obj) ?: return
        val watcher = fsWatcher
            ?: return fsResult(id, null, FsPaths.denied("files are not served"))
        val list = obj["paths"] as? List<*>
            ?: return fsResult(id, null, FsPaths.denied("bad paths"))
        val requested = list.map { it as? String }
        try {
            if (on) watcher.watch(requested) else watcher.unwatch(requested)
            log("fs: watch ${if (on) "on" else "off"} ${list.size} folders")
            fsResult(id, null)
        } catch (e: FsFailure) {
            fsResult(id, null, e)
        } catch (e: Exception) {
            log("fs: watch failed: ${e.javaClass.simpleName}")
            fsResult(id, null, FsFailure("internal", "the watch failed"))
        }
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
            Frames.TYPE_FS_DATA -> fsWriter?.data(frame.stream.toLong() and 0xFFFF_FFFFL, frame.payload)
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

    override fun onConfig(stream: Int, codec: Int, w: Int, h: Int, csd: ByteArray, content: IntRect) {
        // The picture's rect goes ahead of the config on the same lane: the Mac
        // crops each frame of this config to it.
        queue.enqueueControl(stream, Frames.encodeJson(stream,
            """{"t":"window.content","stream":$stream,"x":${content.x},"y":${content.y},"w":${content.w},"h":${content.h}}"""))
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
        // A mode the person changes on the phone reaches the Mac through the
        // same state stream. The observer (or poll) lives while the session is up.
        dndHandle = runCatching {
            zen?.start { mode ->
                val current = stateTracker.current
                if (current != null) stateTracker.update(current.copy(dnd = mode))
            }
        }.getOrNull()
        ringerHandle = runCatching {
            ringerMode?.start { mode ->
                val current = stateTracker.current
                if (current != null) stateTracker.update(current.copy(ringer = mode))
            }
        }.getOrNull()
        volumeHandle = runCatching {
            volume?.start { level, max ->
                val current = stateTracker.current
                if (current != null) {
                    stateTracker.update(current.copy(volume = level, volumeMax = max))
                }
            }
        }.getOrNull()
    }

    private fun stopStateWatch() {
        dndHandle?.let { runCatching { it.close() } }
        dndHandle = null
        ringerHandle?.let { runCatching { it.close() } }
        ringerHandle = null
        volumeHandle?.let { runCatching { it.close() } }
        volumeHandle = null
        val handle = stateHandle ?: return
        stateHandle = null
        runCatching { handle.close() }
    }

    // ------------------------------------------------------------------
    // titles + app-exit watch
    // ------------------------------------------------------------------

    private fun startStreamWatch() {
        if (titleObserver == null && taskPresence == null && secureProbe == null) return
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
        var lastSecureCheck = 0L
        while (!closed.get()) {
            val snapshot = synchronized(streams) { streams.values.toList() }
            // The mirror's secure surface is only worth reading while a phone
            // window can show it, and at most once a second (the protocol says
            // state is sent on change, not on a poll tick).
            if (secureProbe != null && snapshot.none { it.content == WindowContent.Phone }) {
                if (stateTracker.current?.secure == true) stateTracker.onSecureChanged(false)
            }
            if (snapshot.isNotEmpty()) {
                val unpaused = snapshot.filter { !it.paused }
                if (secureProbe != null && snapshot.any { it.content == WindowContent.Phone }) {
                    val nowMs = System.currentTimeMillis()
                    if (nowMs - lastSecureCheck >= SECURE_POLL_MS) {
                        lastSecureCheck = nowMs
                        pollSecure()
                    }
                }

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
        updatePower()
        stopAudioIfIdle()
        notifyAudioWindowsChanged()
        runCatching { callback.onSessionChanged(true, clientId, currentMacName ?: clientName, windowCount()) }
        log("closed stream $stream: app exited (display ${state.displayId})")
    }

    /** One `state.secure` probe; a read failure leaves the last value alone. */
    private fun pollSecure() {
        val probe = secureProbe ?: return
        val secure = runCatching { probe.read() }.getOrNull() ?: return
        val state = (stateTracker.current ?: device.state()).copy(secure = secure)
        stateTracker.update(state)
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

    /**
     * Tells the power policy what the session holds now. [paused] marks a
     * `window.pause` as the cause of an empty set: every stream covered at once
     * keeps the panel state for a grace period instead of handing the phone
     * back and taking it again on the next unpause. A close or the session end
     * passes false and hands back at once.
     */
    private fun updatePower(paused: Boolean = false) {
        val ids: List<Int>
        val allPaused: Boolean
        val mirroring: Boolean
        var phoneOpen = false
        synchronized(streams) {
            val open = streams.values.toList()
            ids = open.filter { !it.paused && it.content != WindowContent.Phone }.map { it.displayId }
            allPaused = paused && open.isNotEmpty() && open.all { it.paused }
            mirroring = open.any { it.content == WindowContent.Phone && !it.paused }
            phoneOpen = open.any { it.content == WindowContent.Phone }
        }
        // The hold owns `state.panel` (paused, resumed, closed) and reports a
        // change through `onPanelChanged`; the session only says what it sees.
        power.setActiveStreams(ids, allPaused = allPaused, mirroring = mirroring, phoneWindowOpen = phoneOpen)
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
        const val PROTOCOL_VERSION = 3
        const val OWN_PACKAGE = "dev.pocketdeck"
        const val PHONE_DISPLAY = 0
        const val KEYCODE_BACK = 4
        const val KEYCODE_HOME = 3
        const val KEYCODE_APP_SWITCH = 187

        /** The phone's own screen: where "Continue on Mac" looks. */
        const val PHONE_DISPLAY_ID = 0

        /** A sanity bound on `notify.action`'s index (the app checks the real set). */
        const val MAX_ACTION_INDEX = 64

        /** The clipboard-image poll: images are user-paced, not sub-second. */
        const val CLIP_IMAGE_POLL_MS = 1_000L

        /** `state.secure` is polled at most this often, and only for a phone window. */
        const val SECURE_POLL_MS = 1_000L

        /** Bounds the kernel's video backlog so the delta-drop rule can fire. */
        const val SEND_BUFFER_BYTES = 128 * 1024

        /** Virtual displays and encoders need dimensions that are multiples of 16. */
        fun floor16(v: Int): Int = if (v <= 0) 0 else (v / 16) * 16
    }
}
