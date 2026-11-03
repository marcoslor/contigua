package dev.pocketdeck.server

import dev.pocketdeck.app.MediaArtRules
import dev.pocketdeck.app.MediaControl
import dev.pocketdeck.app.NotifyEvents
import dev.pocketdeck.app.NotifyImageRules
import dev.pocketdeck.proto.Crypto
import dev.pocketdeck.proto.Frame
import dev.pocketdeck.proto.FrameReader
import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.Json
import dev.pocketdeck.proto.PathCodec
import dev.pocketdeck.proto.PathIds
import dev.pocketdeck.proto.PathKind
import dev.pocketdeck.proto.ReorderWindow
import dev.pocketdeck.proto.VideoConfigPayload
import dev.pocketdeck.proto.VideoFramePayload
import dev.pocketdeck.proto.AudioConfigPayload
import dev.pocketdeck.proto.AudioFramePayload
import java.io.BufferedOutputStream
import java.io.File
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.ArrayDeque
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

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
    /**
     * The plain socket under the TLS one, when the caller has it. A drop shuts
     * this down first: the platform TLS socket's own close waits for a reader
     * blocked in `SSL_read`, which is the whole of PAIR-20's 29 s. Defaults to
     * [socket] for the plain-socket sessions the JVM tests hand in.
     */
    private val plainSocket: Socket = socket,
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
    /** The phone's notification-listener grant, as the app last reported it. */
    private val notifyAccess: () -> Boolean = { false },
    /**
     * Try `cmd notification allow_listener` at shell UID (docs/design/notify.md).
     * Returns whether the listener is granted afterwards.
     */
    private val notifyGrant: () -> Boolean = { false },
    /** `media.command`: the validated command as JSON, for the app process. */
    private val mediaCommand: ((String) -> Unit)? = null,
    /** `media.choose`: which phone session Now Playing follows. */
    private val mediaChoose: ((String) -> Unit)? = null,
    /** The gate's answer for the app: forwarding, and `no_access` when asked but ungranted. */
    private val notifyState: ((Boolean, String?) -> Unit)? = null,
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
    /** The hello the server already read to decide a join (PATH-3); null = read it here. */
    private val preReadHello: Map<String, Any?>? = null,
    /** This path's provider class (the public build's is LAN). */
    private val pathKind: PathKind = PathKind.LAN,
    /** Test seam: every [startPathReader] call, by path id. */
    private val onPathReaderStart: (String) -> Unit = {},
    /** Test seam: a new path writer's first wake, by path id. */
    private val onPathWriterStart: (String) -> Unit = {},
) : VideoSink, AudioSink, LiveSession {

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

        /** The display's top task id (`window.opened`, `window.close`); 0 when unknown. */
        @Volatile var taskId = 0

        /** Written before the state is published under `streams`; never reassigned. */
        var content: WindowContent? = null

        /** Written by pocketdeck-watch, read by the audio thread's capture plan. */
        @Volatile var lastTitle: TopTask? = null

        /** pocketdeck-watch only: an app stream's `window.title` throttle (WIN-28). */
        var title = TaskLabelThrottle.State()

        /** pocketdeck-watch only. */
        var hadTask = false
        var gestureDownTime = 0L
        var lastEventTime = 0L
        var keyDownTime = 0L
    }

    private val queue = SendQueue(maxDeltaBytesPerStream) { stream -> onDeltaDrop(stream) }
    private val pairLock = Object()

    @Volatile private var phase = Phase.HELLO
    /** This session's teardown; [SessionTeardown.State.LIVE] while it serves. */
    private val teardown = AtomicReference(SessionTeardown.State.LIVE)
    /** The thread that owns the socket before `welcome`; set at [run]'s start. */
    @Volatile private var readerThread: Thread? = null

    private val streams = LinkedHashMap<Int, StreamState>()
    /**
     * `window.opened` before any video (PROTOCOL "Video rules"), while the opener
     * waits for the task id it carries.
     */
    private val gate = OpenGate(
        sendJson = { stream, json -> queue.enqueueControl(stream, Frames.encodeJson(stream, json)) },
        sendControl = { stream, bytes -> queue.enqueueControl(stream, bytes) },
        sendDelta = { stream, ptsUs, bytes -> queue.enqueueDelta(stream, ptsUs, bytes) },
    )
    private val clipSync = ClipSync()
    /** How many sensitive clips were kept on the phone this session (a count, never text). */
    @Volatile private var sensitiveClipsSkipped = 0
    /** The Mac's clipboard gate for this session; Off until it says otherwise. */
    @Volatile private var clipGateState = ClipGate.OFF

    /** Whether the Mac's clipboard gate is on; the tests order a copy after it. */
    internal val clipboardGateOn: Boolean get() = clipGateState == ClipGate.ON
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

    // ---- paths (docs/design/paths.md §3) ------------------------------
    private val hub = PathHub(
        log = log,
        now = now,
        wake = ::wakeTicker,
        // E-10/PATH-9: one removal point reports every detach route — a socket
        // error, EOF, a Mac close, the phone's own ClosePath — to the machine.
        onDetached = { id -> inbound.put(Inbound.Down(id)) },
        onWriterStart = onPathWriterStart,
    )
    private val pathMachine = PathSessionMachine()
    private val pathRanking = PathRanking()
    private var sessionId = ""
    @Volatile private var liveSessionId: String? = null
    override val pathSessionId: String? get() = liveSessionId
    private var firstPathId = ""
    private var firstTransport: PathHub.Transport? = null
    private class InboundQueue(private val maxBytes: Int) {
        private val lock = Object()
        private val items = ArrayDeque<Inbound>()
        private var bytes = 0
        private var closed = false

        private fun cost(item: Inbound): Int =
            if (item is Inbound.Deliver) item.frame.payload.size + PATH_FRAME_OVERHEAD else 0

        /** Blocks the reader until the session has room: never drops an event. */
        fun put(item: Inbound) {
            val cost = cost(item)
            synchronized(lock) {
                while (!closed && items.isNotEmpty() && bytes + cost > maxBytes) lock.wait()
                if (closed) return
                items.addLast(item)
                bytes += cost
                lock.notifyAll()
            }
        }

        fun poll(timeoutMs: Long): Inbound? {
            synchronized(lock) {
                if (items.isEmpty() && !closed) lock.wait(timeoutMs)
                if (items.isEmpty()) return null
                val item = items.removeFirst()
                bytes -= cost(item)
                lock.notifyAll()
                return item
            }
        }

        fun close() {
            synchronized(lock) {
                closed = true
                items.clear()
                bytes = 0
                lock.notifyAll()
            }
        }
    }

    private val inbound = InboundQueue(INBOX_MAX_BYTES)
    private var pathTicker: Thread? = null
    private val tickSignal = Object()
    // Joined from the server thread and read from the session thread.
    private val pathReaders = CopyOnWriteArrayList<Thread>()
    /** The last AUDIO_CONFIG: repeated after a switch (docs/design/paths.md §5.6). */
    @Volatile private var lastAudioConfig: ByteArray? = null

    private sealed interface Inbound {
        class Deliver(val frame: Frame) : Inbound
        class Down(val path: String) : Inbound
        class Up(val path: String, val joined: Boolean) : Inbound
        class PeerSwitch(val path: String, val seq: Long, val arrivedOn: String) : Inbound
        class Pong(val path: String, val rttMs: Double) : Inbound
        class PingLost(val path: String) : Inbound
        data object Tick : Inbound
        data object AckAboveSent : Inbound
        data object ProtocolError : Inbound
    }

    /** The v2 pairing room; read by the reader thread. The work queue is the
     * one hand-off from another thread, and [pairLock] guards both. */
    private var pendingPairId: String? = null
    private var pairSettled = false
    private var pendingNp: ByteArray? = null
    private var pendingMacFp = ByteArray(32)
    private var pendingPhoneFp = ByteArray(32)
    private var currentMacName: String? = null

    /**
     * Pre-welcome work another thread recorded for the reader: the reader is
     * the only thread that may write before `welcome` (PATH-2). Android's TLS
     * socket refused the binder thread's `pair.ok` write while the reader was
     * in its 250 ms poll (boot 5), so the answer is a queue, not a callback.
     */
    private sealed interface ReaderWork {
        data object PairAllowed : ReaderWork
        data object PairDenied : ReaderWork
        data object PairExpired : ReaderWork
        data class Refuse(val code: String, val message: String) : ReaderWork
    }

    /** Queued under [pairLock], drained by the reader only. */
    private val readerWork = ArrayDeque<ReaderWork>()

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

    /**
     * A closed window's task removal (WIN-31): it re-reads the task list and
     * waits for the system to settle, so it must not run on the reader thread,
     * which is the one that answers every other window meanwhile. One thread
     * for the session, and its answer never blocks the close itself.
     */
    private val closeTasks = Executors.newSingleThreadExecutor { r ->
        Thread(r, "pocketdeck-close").apply { isDaemon = true }
    }

    /** The Mac asked for notifications; forwarding also needs the listener grant. */
    @Volatile private var notifyWanted = false
    @Volatile private var notifyGranted = false
    @Volatile private var notifyForwarding = false
    @Volatile private var notifyGateState = NotifyGate.OFF

    /** `state.panel` is the phone's hold (PanelHold.kt), never a local guess. */

    private var writerThread: Thread? = null
    private var stateHandle: AutoCloseable? = null
    private var dndHandle: AutoCloseable? = null
    private var ringerHandle: AutoCloseable? = null
    private var volumeHandle: AutoCloseable? = null
    private var watchThread: Thread? = null

    /** The protocol's `state` stream: one emission per real change. */
    private val stateTracker = DeviceStateTracker { state -> sendState(state) }

    /** The person's own use of the phone, for the wake machine's edges (CTRL-7). */
    private val personUse = PersonUseTracker()

    private fun sendState(state: DeviceState) {
        for (use in personUse.note(state)) when (use) {
            PersonUse.UNLOCKED -> power.onPersonUnlocked()
            PersonUse.SCREEN_ON -> power.onPersonScreen(true)
            PersonUse.SCREEN_OFF -> power.onPersonScreen(false)
        }
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
        // WIN-32: the most app windows this phone runs at once.
        message["maxWindows"] = WindowCap.MAX_WINDOWS
        sendJson(message)
    }

    /**
     * Gone: dropped or finished. A dropped session has its transport cut, so no
     * byte can be served from it again even while its reader cleans up.
     */
    override val isClosed: Boolean
        get() = when (teardown.get()) {
            SessionTeardown.State.LIVE, SessionTeardown.State.ENDING -> false
            SessionTeardown.State.DROPPED, SessionTeardown.State.FINISHED -> true
        }

    /** Authenticated and still open: shares may go out (docs/design/sharein.md). */
    override val isReady: Boolean
        get() = phase == Phase.READY && teardown.get() == SessionTeardown.State.LIVE

    override fun shareText(text: String): Int = if (isReady) share.text(text) else ShareStatus.NO_SESSION

    override fun shareFile(name: String, mime: String, input: java.io.InputStream): Int =
        if (isReady) share.file(name, mime, input) else ShareStatus.NO_SESSION

    /**
     * A gate changed in the app process. The master switch drops every live
     * session at once; the pairing switch drops only a session that has not
     * authenticated yet. Paired sessions keep running with pairings off.
     */
    override fun applyGates() {
        if (teardown.get() != SessionTeardown.State.LIVE) return
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

    /**
     * Request teardown from another thread (the server's drop, a gate change,
     * the service shutting down). Never waits for the peer: the plain socket
     * goes first, the TLS socket's own close — which takes the reader's read
     * lock — finishes on the one daemon (docs/specs/pairing.md PAIR-20).
     */
    override fun close() = apply(SessionTeardown.Event.Drop)

    /**
     * True from the moment this session starts closing. A reader must not ack
     * a frame after a refusal/bye was queued: that ACK would land behind the
     * last frame on the wire. Derived from the teardown machine, not a parallel
     * flag (AGENTS.md).
     */
    private val closing: Boolean
        get() = when (teardown.get()) {
            SessionTeardown.State.ENDING, SessionTeardown.State.DROPPED -> true
            SessionTeardown.State.LIVE, SessionTeardown.State.FINISHED -> false
        }

    /**
     * Runs one step of the teardown machine and its returned actions. The state
     * is the compare-and-set, so a drop racing the reader's own end runs one
     * transition, not two.
     */
    private fun apply(event: SessionTeardown.Event) {
        while (true) {
            val before = teardown.get()
            val step = SessionTeardown.transition(before, event)
            if (!teardown.compareAndSet(before, step.to)) continue
            if (step.to != before) {
                log(
                    "session teardown: ${SessionTeardown.describe(before)} " +
                        "--${SessionTeardown.describe(event)}--> ${SessionTeardown.describe(step.to)}",
                )
            }
            for (action in step.actions) {
                when (action) {
                    SessionTeardown.Action.ABORT -> abortTransport()
                }
            }
            return
        }
    }

    /**
     * Cuts the connection now without waiting for the peer. The plain socket
     * under TLS goes first: that is what ends a reader stuck in `SSL_read`, and
     * the platform TLS close waits for exactly that reader.
     */
    private fun abortTransport() {
        runCatching { plainSocket.shutdownInput() }
        runCatching { plainSocket.shutdownOutput() }
        runCatching { plainSocket.close() }
        closeTlsSocketLater()
    }

    /** Closes the transport at the end of a session's own cleanup. */
    private fun closeTransport() {
        runCatching { plainSocket.close() }
        closeTlsSocketLater()
    }

    /**
     * The TLS socket's close, off every other thread: it can wait on a peer that
     * went quiet, and a plain session socket is already closed.
     */
    private fun closeTlsSocketLater() {
        if (plainSocket === socket) return
        tlsCloser.execute { runCatching { socket.close() } }
    }

    fun run() {
        readerThread = Thread.currentThread()
        // The hold decides `state.panel` on its own (the person's power
        // button, a paused window, the session ending): tell the Mac at once —
        // but only once it has authenticated (nothing but the pairing machine
        // goes out before `welcome`).
        power.onPanelChanged = { _ ->
            if (phase == Phase.READY) {
                val state = stateTracker.current ?: device.state()
                if (!stateTracker.update(state)) sendState(state)
            }
        }
        // The person's power press with our streams up: the phone took the
        // panel over and the VD group is being re-lit, so the Mac holds the
        // last frame for a short grace instead of calling it a stall.
        power.onPowerLocked = {
            log("power.locked: telling the Mac the screen went off")
            sendJson(mapOf("t" to "power.locked"))
        }
        writerThread = Thread({ writerLoop() }, "pocketdeck-writer").also { it.start() }
        try {
            socket.tcpNoDelay = true
            // E-1/RRR-2: the send buffer is sized once, in Server.serve, for
            // the founder and every join (the raw socket under this one), so
            // the protocol's ~250 ms of queued video holds on every path.
            socket.soTimeout = handshakeTimeoutMs
            // A provisional name so a refusal before the hello still reaches the
            // peer; the hello's own `path` renames it (PATH-1).
            if (firstTransport == null) {
                firstPathId = PathIds.pathId(emptySet())
                firstTransport = PathHub.Transport(firstPathId, socket, plainSocket, pathKind)
                hub.start(firstTransport!!)
            }
            val reader = FrameReader(socket.getInputStream())
            if (preReadHello != null) {
                onHello(preReadHello)
                runCatching { socket.soTimeout = 0 }
            }
            // A pairing may take minutes (a person reads two screens), so that
            // phase polls instead of blocking forever: this thread checks the
            // decision queue after every timeout (PATH-3).
            if (phase == Phase.PAIR) runCatching { socket.soTimeout = PAIR_POLL_MS }
            var pending: Frame? = null
            while (teardown.get() == SessionTeardown.State.LIVE && phase != Phase.READY) {
                // Another thread records the pairing answer; this thread writes
                // it. Android's TLS socket throws for a write from the binder
                // thread while this one polls the read (boot 5, PATH-2).
                drainReaderWork()
                if (phase == Phase.READY) break
                val frame = try {
                    reader.readFrame()
                } catch (e: SocketTimeoutException) {
                    if (phase == Phase.PAIR) continue
                    log("handshake timeout")
                    break
                }
                if (frame == null) break
                // The session became ready while this read was in flight: the
                // frame belongs to the path layer, not the handshake router.
                if (phase == Phase.READY) {
                    pending = frame
                    break
                }
                handle(frame)
            }
            // A gate push can record a refusal while `welcome` is going out.
            drainReaderWork()
            if (phase == Phase.READY && teardown.get() == SessionTeardown.State.LIVE) {
                startPathReader(firstTransport!!, reader, pending)
                startPathTicker()
                while (teardown.get() == SessionTeardown.State.LIVE) {
                    // A refusal recorded as `welcome` went out still wins.
                    drainReaderWork()
                    if (teardown.get() != SessionTeardown.State.LIVE) break
                    val item = try {
                        inbound.poll(500)
                    } catch (e: InterruptedException) {
                        break
                    } ?: continue
                    consume(item)
                }
            }
        } catch (e: Throwable) {
            log("reader ended: ${e.message}")
        } finally {
            shutdown()
            readerThread = null
        }
    }

    /** The session thread consumes every path event here, serially. */
    private fun consume(item: Inbound) {
        when (item) {
            is Inbound.Deliver -> handle(item.frame)
            is Inbound.Down -> {
                // E-10/PATH-9: the hub is the one removal point and it already
                // reported this detach; every route is a PathDown, whichever
                // path the phone happens to be sending on. A CurrentFailed for
                // an id that was not the machine's current used to be ignored
                // without removing it from `live` (boot 14).
                handlePathEvent(PathSessionEvent.PathDown(item.path))
            }
            is Inbound.Up -> {
                hub.transport(item.path)?.let { startPathReader(it) }
                handlePathEvent(PathSessionEvent.PathUp(item.path, item.joined))
            }
            is Inbound.PeerSwitch -> followSwitch(item)
            is Inbound.Pong -> {
                val at = now() / 1000.0
                pathRanking.addSample(item.path, item.rttMs, at)
                pathMachine.scores[item.path] = pathRanking.score(item.path, at) ?: -1
            }
            is Inbound.PingLost -> {
                val at = now() / 1000.0
                pathRanking.addSample(item.path, null, at)
                if (item.path == hub.currentPath) {
                    handlePathEvent(PathSessionEvent.CurrentFailed(item.path))
                }
            }
            Inbound.Tick -> tickPaths()
            Inbound.AckAboveSent -> {
                log("paths: ack above what was sent")
                apply(SessionTeardown.Event.Stop)
            }
            Inbound.ProtocolError -> {
                log("paths: protocol error")
                apply(SessionTeardown.Event.Stop)
            }
        }
    }

    private fun handlePathEvent(event: PathSessionEvent) {
        val at = now() / 1000.0
        val before = pathMachine.state
        for (id in pathMachine.live) {
            pathMachine.scores[id] = pathRanking.score(id, at) ?: -1
        }
        val actions = pathMachine.handle(event, at)
        val after = pathMachine.state
        if (after != before) log(PathSessionLog.line(before, event, after))
        for (action in actions) {
            when (action) {
                is PathSessionAction.StartPing, is PathSessionAction.StopPing -> Unit
                is PathSessionAction.Ranking -> pathRanking.handle(action.event, at)
                is PathSessionAction.ClosePath -> hub.detach(action.path)
                // PATH-8: only the Mac decides. The phone moves its sending
                // path in followSwitch, when the Mac's marker names it.
                is PathSessionAction.SwitchTo -> Unit
                PathSessionAction.ReplayFromLastAck -> hub.replayOnCurrent()
                PathSessionAction.RequestKeyframes -> Unit
                PathSessionAction.MarkReconnecting -> log("paths: reconnecting")
                is PathSessionAction.End -> {
                    log("paths: ended ${action.reason}")
                    apply(SessionTeardown.Event.Stop)
                }
                PathSessionAction.Ignore -> Unit
            }
        }
        // A transition changes the grace/drain/ping deadlines: recompute.
        wakeTicker()
    }

    /** The Mac named the path: follow it, and answer with our own marker (PATH-9). */
    private fun followSwitch(item: Inbound.PeerSwitch) {
        val plannedFrom = if (item.arrivedOn != item.path && hub.hasPath(item.arrivedOn)) item.arrivedOn else null
        val from = hub.currentPath
        // E-3: the old path stays attached as a standby (still read, still
        // answering pings); the Mac decides when it goes. E-6: the replay goes
        // out before the marker, which never waits for credit.
        hub.followSwitch(item.path, plannedFrom ?: item.path)
        if (from != null && from != item.path) {
            // The sending path moved on the Mac's marker: from, to and whether
            // the Mac planned it (path.switch on the old path) or fled a fault.
            log("paths: sending $from -> ${item.path} (${if (plannedFrom != null) "planned" else "failure"})")
        }
        // A lost AUDIO_CONFIG costs one frame, not the rest of the audio (§5.6).
        lastAudioConfig?.let { queue.enqueueControl(0, it) }
        handlePathEvent(PathSessionEvent.PeerSwitch(item.path, item.seq, item.path))
    }

    private fun tickPaths() {
        hub.flushAck()
        hub.pingAll(transferRunning())
        // During a switch the phone's sending path is still the old one until
        // the Mac's marker arrives; the path the session is moving to is the
        // current one for the pong rule (PATH-7), or a lost pong on it would
        // never reach the machine.
        val current = pongWatchPath(pathMachine.state, hub.currentPath)
        for (loss in hub.pongLosses()) {
            val at = now() / 1000.0
            pathRanking.addSample(loss.path, null, at)
            pongFailure(loss, current)?.let { handlePathEvent(it) }
        }
        for (stale in hub.joinedTimeouts()) {
            // The detach reports its own PathDown (E-10).
            hub.detach(stale)
            log("path joined without a pong: dropped")
        }
        // E-10/PATH-21: the migrating state carries the orphan's deadline.
        if (pathMachine.state.graceDeadline() != null) {
            handlePathEvent(PathSessionEvent.GraceExpired)
        }
        val at = now() / 1000.0
        pathRanking.handle(PathRankingEvent.Tick(at), at)
    }

    private fun startPathTicker() {
        if (pathTicker != null) return
        pathTicker = Thread({
            while (teardown.get() == SessionTeardown.State.LIVE) {
                val at = now()
                val wait = nextTickDelay(at)
                if (wait > 0) {
                    var interrupted = false
                    synchronized(tickSignal) {
                        try {
                            tickSignal.wait(wait)
                        } catch (e: InterruptedException) {
                            interrupted = true
                        }
                    }
                    if (interrupted) break
                    // Woken for a new (earlier) deadline: recompute instead of
                    // ticking early.
                    if (now() < at + wait) continue
                }
                if (teardown.get() != SessionTeardown.State.LIVE) break
                inbound.put(Inbound.Tick)
            }
        }, "pocketdeck-paths").also { it.start() }
    }

    /** R-15/D-1: a new deadline (an ACK timer, a join, a state change). */
    private fun wakeTicker() {
        synchronized(tickSignal) { tickSignal.notifyAll() }
    }

    /**
     * D-1: the ticker wakes for the next timer (ping policy, pong, joined drop,
     * drain, grace), not on a fixed poll. A session with no timer at all only
     * needs a keepalive wake.
     */
    internal fun nextTickDelay(at: Long): Long {
        var next = hub.nextDeadline(transferRunning())
        pathMachine.state.graceDeadline()?.let { deadline ->
            val graceAt = (deadline * 1000).toLong()
            if (graceAt in (at + 1) until next) next = graceAt
        }
        if (next == Long.MAX_VALUE) return TICK_KEEPALIVE_MS
        return (next - at).coerceIn(TICK_MIN_MS, TICK_KEEPALIVE_MS)
    }

    /** D-1: the screen is on or a transfer runs (a stream, drop, APK, fs bulk). */
    private fun transferRunning(): Boolean =
        synchronized(streams) { streams.isNotEmpty() } ||
            stateTracker.current?.screen == ScreenState.ON ||
            hub.bulkActive()

    private fun startPathReader(
        t: PathHub.Transport,
        reader: FrameReader = FrameReader(t.socket.getInputStream()),
        first: Frame? = null,
    ) {
        onPathReaderStart(t.id)
        if (pathReaders.any { it.name == "pocketdeck-path-${t.id}" }) return
        val thread = Thread({
            var pending: Frame? = first
            // R-11: frames ahead of a gap that this same path must fill wait
            // here, never dropped and never behind a paused reader. RR-10:
            // bounded by bytes (one window, PATH-15), not by a frame count.
            val held = ArrayDeque<Frame>()
            var heldBytes = 0
            try {
                while (teardown.get() == SessionTeardown.State.LIVE && !t.closed) {
                    val frame = when {
                        pending != null -> pending!!.also { pending = null }
                        held.isNotEmpty() && hub.canBuffer() ->
                            held.removeFirst().also { heldBytes -= it.payload.size }
                        else -> reader.readFrame() ?: break
                    }
                    val read = hub.receive(t.id, frame)
                    val events = read.events
                    val pressure = events.filterIsInstance<PathHub.Event.Backpressure>().firstOrNull()
                    if (pressure != null) {
                        if (pressure.stop) {
                            pending = frame
                            hub.awaitReorderSpace(t.id)
                        } else {
                            // The gap is earlier in this same path's stream:
                            // pausing the reader would never fill it (PATH-10).
                            held.addLast(frame)
                            heldBytes += frame.payload.size
                            if (held.size > ReorderWindow.MAX_FRAMES ||
                                heldBytes > ReorderWindow.MAX_BYTES
                            ) {
                                inbound.put(Inbound.ProtocolError)
                                return@Thread
                            }
                        }
                        continue
                    }
                    for (event in events) {
                        when (event) {
                            is PathHub.Event.Deliver -> inbound.put(Inbound.Deliver(event.frame))
                            is PathHub.Event.Down -> {
                                inbound.put(Inbound.Down(event.path))
                                return@Thread
                            }
                            is PathHub.Event.Pong -> inbound.put(Inbound.Pong(event.path, event.rttMs))
                            is PathHub.Event.Ping -> Unit
                            is PathHub.Event.PeerSwitch ->
                                inbound.put(Inbound.PeerSwitch(event.path, event.seq, event.arrivedOn))
                            PathHub.Event.AckAboveSent -> inbound.put(Inbound.AckAboveSent)
                            PathHub.Event.ProtocolError -> {
                                inbound.put(Inbound.ProtocolError)
                                return@Thread
                            }
                            is PathHub.Event.Backpressure -> Unit
                        }
                    }
                    // R-1: the ACK leaves only after every frame the hub
                    // delivered is in the session's hand-off, so a slow handler
                    // pushes back through TCP instead of losing an acked frame.
                    // RR-8: only a delivered RELIABLE frame earns one; the
                    // Mac's ACKs, pings and lossy input would be pure airtime.
                    // A closing session never acks: the refusal/bye is the last
                    // frame the Mac may see.
                    if (!closing && read.deliveredReliable) hub.ackHandled(t.id)
                }
            } catch (e: Throwable) {
                if (teardown.get() == SessionTeardown.State.LIVE) {
                    log("path reader ended: ${e.message}")
                }
            } finally {
                // E-10/PATH-9: EOF and a Mac close are detaches here; the hub
                // reports the PathDown from its single removal point.
                if (teardown.get() == SessionTeardown.State.LIVE) hub.detach(t.id)
            }
        }, "pocketdeck-path-${t.id}")
        thread.isDaemon = true
        pathReaders.add(thread)
        thread.start()
    }

    /**
     * A join (PATH-3): the same session, one more path. The slot already
     * decided; this attaches the socket and answers `welcome.session`.
     */
    override fun attachPath(pathId: String, socket: Socket, plain: Socket): AttachResult {
        if (phase != Phase.READY || teardown.get() != SessionTeardown.State.LIVE) return AttachResult.BUSY
        if (hub.hasPath(pathId) || hub.pathCount >= PathHub.MAX_PATHS) return AttachResult.TOO_MANY
        runCatching { socket.tcpNoDelay = true }
        runCatching { socket.soTimeout = 0 }
        val t = PathHub.Transport(pathId, socket, plain, pathKind)
        if (!hub.attach(t)) return AttachResult.TOO_MANY
        hub.expectFirstPong(pathId)
        sendWelcomeOn(pathId)
        // E-10: the machine learns the path before its reader can hand over a
        // marker. The session thread starts the reader (Inbound.Up) and is the
        // only caller: two startPathReader calls on one socket raced, and the
        // losing reader read the first frame's body as its length ("frame
        // length too large: 16777216", a probe join's first ping, 11-02).
        inbound.put(Inbound.Up(pathId, joined = true))
        // D-1: a joined path is pinged at once so its ranking starts (the
        // welcome is already queued; the ping follows it on the same writer).
        hub.pingPath(pathId)
        wakeTicker()
        log("paths: joined $pathId (paths ${hub.pathCount})")
        return AttachResult.ATTACHED
    }

    private fun shutdown() {
        // The reader loop is the one caller; a drop racing it has already cut
        // the transport, so only the cleanup below is left.
        if (teardown.get() == SessionTeardown.State.FINISHED) return
        apply(SessionTeardown.Event.Ended)
        // The Mac's session ended: stop forwarding and tell the app.
        notifyWanted = false
        // The app's attention item is local state and must go even when the
        // session never forwarded (no access): clear it from the close path,
        // which runs whatever the phase was.
        if (notifyGateState != NotifyGate.OFF) {
            log("notify gate: ${notifyGateState.name.lowercase()} -> off")
            notifyGateState = NotifyGate.OFF
            notifyForwarding = false
            runCatching { notifyState?.invoke(false, null) }
        }
        val abandoned = synchronized(pairLock) {
            val open = if (pairSettled) null else pendingPairId
            pairSettled = true
            readerWork.clear()
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
        // A removal already running finishes; no close can arrive now.
        closeTasks.shutdown()
        runCatching { audioCapture?.stop() }
        queue.clearAudio()
        // Close outside the lock: a stream's close stops an encoder and joins
        // its drain thread, and the watch thread's snapshot needs the lock.
        val closing = synchronized(streams) {
            val open = streams.values.toList()
            streams.clear()
            open
        }
        for (s in closing) runCatching { display.close(s.stream) }
        runCatching { power.setActiveStreams(emptyList()) }
        runCatching { power.onSessionEnded() }
        runCatching { power.onPanelChanged = null }
        runCatching { power.onPowerLocked = null }
        pathTicker?.interrupt()
        pathTicker = null
        // Wake a reader blocked in the hand-off: the session is going.
        inbound.close()
        // The writer drains the queue through the path hub: close the hub only
        // after it has written the last frame (a refusal's error, a bye).
        queue.close()
        runCatching { writerThread?.join(1000) }
        hub.closeAll()
        for (t in pathReaders) runCatching { t.join(200) }
        pathReaders.clear()
        closeTransport()
        if (phase == Phase.READY) runCatching { callback.onSessionChanged(false, clientId.ifEmpty { null }, null, 0) }
    }

    private fun writerLoop() {
        try {
            while (true) {
                val bytes = queue.poll() ?: break
                // Reliable frames are wrapped and kept for a switch; lossy ones
                // go bare on the current path (docs/design/paths.md §5.5).
                hub.send(bytes)
            }
            // Drained after a stop (e.g. pair_denied): the reader is still in a
            // blocking read, and closing the transport is what wakes it. The
            // path writers flush first (R-2): a refusal must not lose its race
            // with this close.
            hub.drain()
            closeTransport()
        } catch (e: Throwable) {
            log("writer ended: ${e.message}")
            // A failed write is the transport's death, not the caller's wait.
            apply(SessionTeardown.Event.Drop)
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
                // A second hello in one session is not a new handshake: the
                // pairing phase it is already in decides (PAIR-10's QR probe).
                "hello" -> logOnce("second hello ignored")
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
        // The path id names this connection; a v4 hello always carries one.
        val pathId = Json.str(obj["path"]) ?: PathIds.pathId(emptySet())
        if (firstTransport == null) {
            firstPathId = pathId
            firstTransport = PathHub.Transport(pathId, socket, plainSocket, pathKind)
            hub.start(firstTransport!!)
        } else if (pathId != firstPathId) {
            hub.rekey(firstPathId, pathId)
            firstPathId = pathId
            firstTransport?.id = pathId
        }
        if (dev.pocketdeck.proto.PathVersion.refused(v)) {
            // PATH-1: the refusal carries this phone's own version; the screen
            // names the Mac's side from the hello's v.
            log("version: ${dev.pocketdeck.proto.PathVersion.phoneSentence(v)}")
            runCatching { callback.onVersionRefused(v) }
            sendJson(mapOf(
                "t" to "error",
                "code" to "version",
                "v" to dev.pocketdeck.proto.PathVersion.CURRENT,
            ))
            apply(SessionTeardown.Event.Stop)
            return
        }
        clientId = Json.str(obj["clientId"]) ?: ""
        clientName = Json.str(obj["name"]) ?: "Mac"
        // The iPad named itself by a stable id on the phone's memory; the TLS
        // channel now has to prove it is still that Mac (a rotated cert means
        // the Mac reinstalled: pair again — docs/design/e2ee.md §7).
        val client = store.snapshot().firstOrNull { it.clientId == clientId }
        // A user-driven pairing says so in its hello (PAIR-23); a Mac that
        // believes it is paired sends a bare one. A scanned QR makes an unpinned
        // probe a pairing too: the phone itself invited it.
        val pairingAttempt = Json.bool(obj["pair"]) == true || qrPendingForPeer()
        when (ConnectionGate.decide(gateProvider(), isPaired = client != null, isPairing = pairingAttempt)) {
            GateDecision.REFUSE_CONNECTIONS_OFF ->
                return refuse(GateDecision.REFUSE_CONNECTIONS_OFF)
            GateDecision.REFUSE_PAIRING_OFF ->
                return refuse(GateDecision.REFUSE_PAIRING_OFF)
            GateDecision.NOT_PAIRED -> {
                // The Mac holds our pin but we hold none of its: say so at once
                // instead of waiting for a pair.request it will never send.
                log("refused: no pairing for this Mac mac=${macIdHash(clientId)}")
                finishWithError("not_paired", "this phone has no pairing with this Mac")
                return
            }
            GateDecision.CLOSE_SILENT -> {
                // PAIR-12: a peer we pin nothing for learns nothing at all.
                log("refused: no pairing for this Mac, pairings off mac=${macIdHash(clientId)}")
                apply(SessionTeardown.Event.Stop)
                queue.close()
                return
            }
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
            apply(SessionTeardown.Event.Stop)
            return
        }
        if (peer.size != 32 || stored.size != 32 || !peer.contentEquals(stored)) {
            sendError("bad_pin", "this Mac's certificate changed; pair again")
            apply(SessionTeardown.Event.Stop)
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
            // A distinct code: the Mac's sheet tells the person to wait for the
            // window to pass, not that this Mac was refused again (PAIR-5).
            log("pair.request refused: cooling down after a denied prompt")
            finishWithError("pair_cooldown", "pairing is cooling down after a denied prompt")
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
        // Mac going away: poll so a decision on another thread is seen at once.
        runCatching { socket.soTimeout = PAIR_POLL_MS }
        val commit = PairingCodeV2.commit(np, pendingPhoneFp, pendingMacFp)
        sendJson(mapOf("t" to "pair.commit", "c" to PairingCodeV2.hex(commit)))
        phase = Phase.PAIR
        Thread({ expirePairing(id) }, "pocketdeck-pair-timeout").also {
            it.isDaemon = true
            it.start()
        }
    }

    /** True when a scanned QR names this peer: the phone invited its hello. */
    private fun qrPendingForPeer(): Boolean {
        val qr = pendingQrProvider() ?: return false
        val fp = Json.str(qr["macFp"]) ?: return false
        val at = Json.long(qr["at"]) ?: 0
        if (System.currentTimeMillis() - at !in 0..PENDING_QR_TTL_MS) return false
        return fp.contentEqualsHex(tlsFacts.peerFingerprint())
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
        runCatching { socket.soTimeout = PAIR_POLL_MS }
        val hmac = PairingCodeV2.qrHmac(secret, exporter, pendingPhoneFp)
        // One-time: a second hello with the same QR secret must not be answered
        // (review L-3). Consume before the write so a reader that sees the frame
        // never sees a secret still stored.
        runCatching { pendingQrConsumer() }
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
        runCatching { socket.soTimeout = PAIR_POLL_MS }
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
        synchronized(pairLock) {
            while (!pairSettled && pendingPairId == id) {
                val left = deadline - System.currentTimeMillis()
                if (left <= 0) {
                    // M-1: nobody answered. Keep the phone quiet for a moment so
                    // a peer cannot retry the prompt in a tight loop. The reader
                    // writes the timeout error; this thread never touches the
                    // socket (PATH-2).
                    pairSettled = true
                    readerWork.addLast(ReaderWork.PairExpired)
                    pairLock.notifyAll()
                    return
                }
                pairLock.wait(left)
            }
        }
    }

    /**
     * Called from the app process (binder thread) when the person answers the
     * prompt. Only the decision is recorded here: the reader thread writes
     * `pair.ok` or the denial, because before `welcome` it is the one thread
     * that may touch the TLS socket (PATH-2, boot 5).
     */
    override fun respondPairing(requestId: String, allow: Boolean) {
        synchronized(pairLock) {
            if (requestId != pendingPairId || pairSettled || isClosed) return
            pairSettled = true
            readerWork.addLast(if (allow) ReaderWork.PairAllowed else ReaderWork.PairDenied)
            pairLock.notifyAll()
        }
        log("pairing: ${if (allow) "allow" else "deny"} recorded")
    }

    /**
     * Runs the pre-welcome work another thread recorded. Only the reader calls
     * this; [finishWithError] hands a refusal here too, so no binder thread
     * ever writes on the TLS socket (PATH-2).
     */
    private fun drainReaderWork() {
        while (true) {
            val work = synchronized(pairLock) { readerWork.pollFirst() } ?: return
            if (teardown.get() != SessionTeardown.State.LIVE) return
            // The pairing frames must not wait out the 250 ms read poll: clear
            // the read timeout before the first write, as main did.
            runCatching { socket.soTimeout = 0 }
            when (work) {
                ReaderWork.PairAllowed -> {
                    log("pairing: allow")
                    completePairing()
                }
                ReaderWork.PairDenied -> {
                    log("pairing: deny")
                    pairCooldown.start()
                    finishWithError("pair_denied", "pairing denied")
                }
                ReaderWork.PairExpired -> {
                    log("pairing: no decision")
                    pairCooldown.start()
                    pendingPairId?.let { runCatching { callback.onPairingEnded(it) } }
                    finishWithError("pair_timeout", "no decision on the phone")
                }
                is ReaderWork.Refuse -> finishWithError(work.code, work.message)
            }
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
        if (phase != Phase.READY && Thread.currentThread() !== readerThread) {
            // A pre-welcome refusal may not write from a caller thread (the
            // app's gate push, a binder decision): hand it to the reader.
            if (teardown.get() != SessionTeardown.State.LIVE) return
            synchronized(pairLock) {
                readerWork.addLast(ReaderWork.Refuse(code, message))
                pairLock.notifyAll()
            }
            return
        }
        sendError(code, message)
        apply(SessionTeardown.Event.Stop)
        queue.close()
    }

    private fun welcome() {
        if (sessionId.isEmpty()) sessionId = PathIds.sessionId()
        liveSessionId = sessionId
        // The first path is live before `welcome` is queued: after a pairing the
        // reader may see the Mac's first request as soon as the frame is out.
        hub.sendJSONOn(firstPathId, welcomeMessage())
        phase = Phase.READY
        // The read timeout only guards the handshake; a live session may be
        // silent for long stretches (static content, no input).
        runCatching { socket.soTimeout = 0 }
        pathMachine.startLive(firstPathId)
        log("session ${sessionId.take(8)}: welcome (protocol ${dev.pocketdeck.proto.PathVersion.CURRENT})")
        runCatching { callback.onSessionChanged(true, clientId, currentMacName ?: clientName, windowCount()) }
        startStateWatch()
        startClipboardSync()
        startClipImagePoll()
    }

    /** A `welcome` on a joined path echoes the same session id (PATH-3). */
    private fun sendWelcomeOn(pathId: String) {
        // PATH-3: the welcome must precede every path frame, and the join ping
        // (PATH-12/D-1) is a priority frame: both take the priority lane in
        // queue order, or the ping would overtake the welcome.
        hub.sendJSONOn(pathId, welcomeMessage(), priority = true)
    }

    private fun welcomeMessage(): Map<String, Any?> {
        val d = device.info()
        return mapOf(
            "t" to "welcome",
            "session" to sessionId,
            "device" to mapOf(
                "id" to d.id,
                "name" to d.name,
                "model" to d.model,
                "sdk" to d.sdk,
                "screen" to mapOf("w" to d.screenW, "h" to d.screenH, "dpi" to d.dpi),
                "locked" to d.locked,
            ),
        )
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
                "clip.enable" -> onClipEnable(obj)
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
        val apps = catalog.list().map {
            mapOf("pkg" to it.pkg, "label" to it.label, "activity" to it.activity, "multi" to it.multi)
        }
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
        openStream(obj, stream, content, newInstance = Json.bool(obj["newInstance"]) ?: false)
    }

    private fun onLinkOpen(obj: Map<String, Any?>, frame: Frame) {
        val stream = streamOf(obj, frame)
        val url = LinkPolicy.validate(Json.str(obj["url"])) ?: run {
            sendError("bad_url", "link.open needs an http, https, geo, tel or mailto URL", stream)
            return
        }
        openStream(obj, stream, WindowContent.Link(url), newInstance = false)
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
        if (synchronized(streams) { streams.containsKey(stream) }) {
            display.close(stream)
            gate.forget(stream)
        }
        gate.expect(stream)
        val displayId = display.open(stream, w, h, dpi, this)
        val state = StreamState(stream, displayId, IntSize(w, h)).also { it.content = WindowContent.App(task.pkg, task.activity) }
        synchronized(streams) { streams[stream] = state }
        // The episode's take-over first: on a shared group the move waits for
        // the sleeping display to wake, so the wake cannot wait for it.
        updatePower()
        // Moving before the reply: `started` must match what actually happened.
        val moved = runCatching { mover.move(task.taskId, displayId) }.getOrDefault(false)
        if (moved) {
            goHome()
            state.taskId = task.taskId
        } else {
            launchOn(displayId, task.pkg, task.activity, newInstance = false)
            state.taskId = awaitTaskId(stream, displayId)
        }
        gate.announce(stream) {
            val fields = openedFields(stream, displayId, w, h, state.taskId)
            fields["started"] = if (moved) "moved" else "fresh"
            sendJson(fields)
        }
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
    private fun openStream(obj: Map<String, Any?>, stream: Int, content: WindowContent, newInstance: Boolean) {
        val w = floor16(Json.int(obj["w"]) ?: 0)
        val h = floor16(Json.int(obj["h"]) ?: 0)
        val dpi = Json.int(obj["dpi"]) ?: 160
        if (w <= 0 || h <= 0) {
            sendError("bad_size", "${obj["t"]} needs w,h", stream)
            return
        }
        // WIN-32: the cap is read before a display exists, so a refusal costs the
        // phone nothing; the mirror is never counted (its own encoder).
        if (WindowCap.counted(content) && !WindowCap.allows(openAppStreams(excluding = stream))) {
            sendError("too_many_windows", "the phone runs at most ${WindowCap.MAX_WINDOWS} app windows", stream)
            return
        }
        if (synchronized(streams) { streams.containsKey(stream) }) {
            display.close(stream)
            gate.forget(stream)
        }
        gate.expect(stream)
        if (content == WindowContent.Phone) {
            val size = runCatching { display.openMirror(stream, w, h, this) }.getOrElse {
                log("phone mirror failed: ${it.message}")
                gate.forget(stream)
                sendError("mirror_unavailable", "this phone can't mirror its screen", stream)
                return
            }
            val state = StreamState(stream, PHONE_DISPLAY, size).also { it.content = content }
            synchronized(streams) { streams[stream] = state }
            gate.announce(stream) {
                sendJson(openedFields(stream, PHONE_DISPLAY, size.w, size.h, taskId = 0))
            }
        } else {
            val displayId = display.open(stream, w, h, dpi, this)
            val state = StreamState(stream, displayId, IntSize(w, h)).also { it.content = content }
            synchronized(streams) { streams[stream] = state }
            // The episode's take-over first: a VD created while the panel's
            // group sleeps starts OFF, and the launch waits for the wake (the
            // 10-30 open: 11 s in the launch, 23 s to the first frame). The
            // keep-alive's own step runs after this returns, beside the launch.
            updatePower()
            // The launch next: `window.opened` names the task it made (WIN-32),
            // and video that arrived before this point waits in the gate.
            val launched = when (content) {
                is WindowContent.App -> launchOn(displayId, content.pkg, content.activity, newInstance)
                is WindowContent.Link -> viewOn(displayId, content.url)
                WindowContent.Phone -> true
            }
            val taskId = awaitTaskId(stream, displayId)
            state.taskId = taskId
            gate.announce(stream) { sendJson(openedFields(stream, displayId, w, h, taskId)) }
            if (!launched) {
                when (content) {
                    is WindowContent.App -> sendError("launch_failed", "could not launch ${content.pkg}", stream)
                    is WindowContent.Link -> sendError("launch_failed", "no app opens this link", stream)
                    WindowContent.Phone -> Unit
                }
            }
        }
        // An app or link stream already told the power policy before its
        // launch; only the mirror decides after its reply (it never wakes).
        if (content == WindowContent.Phone) updatePower()
        runCatching { callback.onSessionChanged(true, clientId, currentMacName ?: clientName, windowCount()) }
        startStreamWatch()
        notifyAudioWindowsChanged()
    }

    private fun openedFields(stream: Int, displayId: Int, w: Int, h: Int, taskId: Int): LinkedHashMap<String, Any?> =
        linkedMapOf(
            "t" to "window.opened", "stream" to stream, "displayId" to displayId,
            "w" to w, "h" to h, "taskId" to taskId,
        )

    /** App streams open now, the one being reopened excluded: the cap's count (WIN-32). */
    private fun openAppStreams(excluding: Int): Int = synchronized(streams) {
        streams.values.count { it.stream != excluding && WindowCap.counted(it.content) }
    }

    /**
     * The task the display shows, waited for at most [TASK_WAIT_MS]: the platform
     * creates it inside the launch call, so this normally answers at once. 0 when
     * the phone cannot read its task list. The wait is measured per open: the
     * reader thread pays it and answers no other window meanwhile.
     */
    private fun awaitTaskId(stream: Int, displayId: Int): Int {
        val presence = taskPresence ?: return 0
        val startedMs = System.currentTimeMillis()
        val deadline = startedMs + TASK_WAIT_MS
        var taskId = 0
        while (true) {
            val found = runCatching { presence.taskId(displayId) }.getOrNull()
            if (found != null) {
                taskId = found
                break
            }
            if (System.currentTimeMillis() >= deadline) break
            Thread.sleep(TASK_POLL_MS)
        }
        log("opened stream=$stream task_wait_ms=${System.currentTimeMillis() - startedMs}")
        return taskId
    }

    private fun onWindowResize(obj: Map<String, Any?>, frame: Frame) {
        val stream = streamOf(obj, frame)
        val askedW = Json.int(obj["w"]) ?: 0
        val askedH = Json.int(obj["h"]) ?: 0
        val dpi = Json.int(obj["dpi"]) ?: 160
        // Every resize the phone reads is answered, the ones it cannot apply
        // included: the Mac keeps one request in flight and only sends the value
        // that waited behind it when this arrives. Silence here would swallow
        // every later press and drag of that window.
        val state = requireState(stream)
        if (state == null) {
            sendResizeAck(stream, askedW, askedH, dpi, ResizeOutcome.REFUSED)
            return
        }
        val w = floor16(askedW)
        val h = floor16(askedH)
        if (w <= 0 || h <= 0) {
            sendResizeAck(stream, askedW, askedH, dpi, ResizeOutcome.REFUSED)
            return
        }
        state.size = IntSize(w, h)
        val outcome = display.resize(stream, w, h, dpi)
        // The echo is the request as the Mac sent it, not the display's floored
        // size: the Mac matches it against the resize it has in flight.
        sendResizeAck(stream, askedW, askedH, dpi, outcome)
        // The new size means a redraw: make sure the group is awake for it.
        updatePower()
    }

    private fun sendResizeAck(stream: Int, w: Int, h: Int, dpi: Int, outcome: ResizeOutcome) {
        sendJson(mapOf("t" to "window.resize.ack", "stream" to stream,
                       "w" to w, "h" to h, "dpi" to dpi, "outcome" to outcome.wire))
    }

    private fun onWindowClose(obj: Map<String, Any?>, frame: Frame) {
        val stream = streamOf(obj, frame)
        val state = synchronized(streams) { streams.remove(stream) }
        if (state == null) {
            sendError("no_stream", "unknown stream $stream", stream)
            return
        }
        display.close(stream)
        gate.forget(stream)
        // The panel follows the session's windows, so it is settled before the
        // reply: a closed window never leaves the Mac on a held panel.
        updatePower()
        sendJson(mapOf("t" to "window.closed", "stream" to stream, "reason" to "requested"))
        stopAudioIfIdle()
        notifyAudioWindowsChanged()
        runCatching { callback.onSessionChanged(true, clientId, currentMacName ?: clientName, windowCount()) }
        // WIN-31: the display is gone; a task that outlived it is ended off this
        // thread, after the Mac has the close (never the app: the other windows
        // and the session keep running).
        closeTasks.execute { endClosedTask(state) }
        log("closed stream $stream (display ${state.displayId})")
    }

    /**
     * WIN-31: the closed display's task, when the platform left it behind.
     * `FLAG_DESTROY_CONTENT_ON_REMOVAL` takes the activity with the display but
     * not the task's Recents card, so the decision asks both lists whether the
     * task still exists and removes only one that no other window shows.
     */
    private fun endClosedTask(state: StreamState) {
        val mover = taskMove ?: run {
            // No task manager (a build without the shell service): nothing can
            // be read or removed, and the line says so instead of claiming one.
            logCloseDecision(state, CloseTask.Decision(CloseTask.Action.NONE, CloseTask.Reason.UNREAD))
            return
        }
        val running = runCatching { mover.tasks() }.getOrNull()?.map { it.taskId }?.toSet()
        val recents = runCatching { mover.recentTaskIds() }.getOrNull()
        val otherTasks = synchronized(streams) {
            streams.values.mapNotNull { it.taskId.takeIf { id -> id > 0 } }.toSet()
        }
        val decision = CloseTask.judge(
            CloseTask.Facts(
                counted = WindowCap.counted(state.content),
                taskId = state.taskId,
                otherTasks = otherTasks,
                runningNow = running,
                recentsNow = recents,
            ),
        )
        if (decision.action == CloseTask.Action.REMOVE_TASK) {
            runCatching { mover.remove(state.taskId) }
        }
        logCloseDecision(state, decision)
    }

    /** One line per close decision, ids and states only: R-PRIV-1. */
    private fun logCloseDecision(state: StreamState, decision: CloseTask.Decision) {
        val closeState = decision.action
        val closeCode = decision.reason
        log("close: stream=${state.stream} task=${state.taskId} action=$closeState reason=$closeCode")
    }

    private fun onWindowPause(obj: Map<String, Any?>, frame: Frame) {
        val state = requireState(streamOf(obj, frame)) ?: return
        if (!state.paused) {
            state.paused = true
            display.pause(state.stream)
            updatePower()
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
        if (!launchOn(state.displayId, pkg, Json.str(obj["activity"]), newInstance = false)) {
            sendError("launch_failed", "could not launch $pkg", state.stream)
        }
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
        port.listen { clip ->
            if (clipGateState == ClipGate.OFF) return@listen
            if (clip.sensitive) {
                // A password manager's item: the count only, never its text.
                sensitiveClipsSkipped += 1
                log("clipboard: skipped a sensitive clip (${sensitiveClipsSkipped} so far)")
            } else if (clipSync.shouldSend(clip.text)) {
                sendJson(mapOf("t" to "clip.set", "text" to clip.text))
            }
        }
    }

    /**
     * `clip.enable`: the Mac's own "Share clipboard with your phone" setting,
     * the only switch (SHARE-13). Off stops the phone's sends and its applies at
     * once; on starts them again. One-way: the Mac needs no answer.
     */
    private fun onClipEnable(obj: Map<String, Any?>) {
        val on = Json.bool(obj["on"]) ?: run {
            sendError("bad_request", "clip.enable needs a boolean on", 0)
            return
        }
        val next = clipGate(clipGateState, ClipGateEvent.MacSaid(on))
        if (next != clipGateState) log("clip gate: ${clipGateState.name.lowercase()} -> ${next.name.lowercase()}")
        clipGateState = next
    }

    private fun stopClipboardSync() {
        runCatching { clipboard?.stop() }
    }

    // ------------------------------------------------------------------
    // notifications + media controls (docs/design/notify.md)
    // ------------------------------------------------------------------

    /**
     * `notify.enable`: the Mac's per-session opt-in, the only person-facing
     * switch (docs/design/notify.md). A missing listener grant is tried once at
     * shell UID; when that fails the phone answers `no_access` and shows the
     * person where to allow it.
     *
     * Every `on:true` is also announced to the app, even a repeat: after a
     * same-session rejoin the Mac asks again and the phone answers with its
     * active set (NOTIFY-1/PATH-6, ISS-5).
     */
    private fun onNotifyEnable(obj: Map<String, Any?>) {
        val on = Json.bool(obj["on"]) ?: run {
            sendError("bad_request", "notify.enable needs a boolean on", 0)
            return
        }
        notifyWanted = on
        if (on && !notifyGranted) {
            notifyGranted = notifyAccess() || notifyGrant()
            if (notifyGranted) log("notify: listener access granted")
        }
        reconcileNotify(announce = on)
    }

    /** Re-evaluates the forwarding gate (also runs when the app reports a grant). */
    fun reconcileNotify(announce: Boolean = false) {
        // A session that has not authenticated gets nothing but the machine; the
        // Mac's `notify.enable` after welcome asks again.
        if (phase != Phase.READY) return
        val gate = notifyGate(notifyWanted && !isClosed, notifyGranted)
        val gateChanged = gate != notifyGateState
        if (gateChanged) {
            log("notify gate: ${notifyGateState.name.lowercase()} -> ${gate.name.lowercase()}")
            notifyGateState = gate
        }
        // A gate change always reaches the app, even when forwarding was false
        // both before and after (no access -> off): the attention item is the
        // app's own state. NO_ACCESS repeats, so a late-attached app still learns.
        // [announce] is the Mac's own enable: it reaches the app even when the
        // gate did not move, so the listener can resend its active set.
        val forward = gate == NotifyGate.FORWARDING
        notifyForwarding = forward
        if (gateChanged || needsNotificationAccessAttention(gate) || (announce && forward)) {
            runCatching { notifyState?.invoke(forward, if (gate == NotifyGate.NO_ACCESS) "no_access" else null) }
        }
        sendJson(notifyStateMessage(gate))
    }

    /**
     * The app's notification listener connected or went away: a later grant
     * turns forwarding on without another Mac toggle.
     */
    override fun listenerAccessChanged(granted: Boolean) {
        if (notifyGranted == granted) return
        notifyGranted = granted
        reconcileNotify()
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
    override fun onDeviceEvent(t: String, obj: Map<String, Any?>) {
        if (phase != Phase.READY || !notifyForwarding) return
        when (t) {
            "notify.post" -> deviceNotifyPost(obj)
            "notify.image" -> deviceNotifyImage(obj)
            "notify.remove" -> deviceNotifyRemove(obj)
            "notify.snapshot" -> deviceNotifySnapshot(obj)
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
        // The Mac shows a post only when it knows whether Android would alert
        // (NOTIFY-19), so the decision is required, never defaulted.
        val alert = obj["alert"] as? Boolean ?: return dropNotifyPost("alert")
        val title = Json.str(obj["title"])?.takeIf { it.isNotEmpty() && it.length <= NotifyEvents.MAX_CHARS }
        val text = Json.str(obj["text"])?.takeIf { it.isNotEmpty() && it.length <= NotifyEvents.MAX_CHARS }
        if (title == null && text == null) return dropNotifyPost("empty content")
        val whenMs = Json.long(obj["when"])?.takeIf { it > 0 }
        val ongoing = Json.bool(obj["ongoing"]) == true
        val group = validGroup(Json.str(obj["group"]))
        val live = validLive(obj["live"])
        val actions = validActions(obj["actions"])
        val message = LinkedHashMap<String, Any?>()
        message["t"] = "notify.post"
        message["id"] = id
        message["pkg"] = pkg
        if (title != null) message["title"] = title
        if (text != null) message["text"] = text
        if (whenMs != null) message["when"] = whenMs
        message["alert"] = alert
        if (ongoing) message["ongoing"] = true
        if (live != null) message["live"] = live
        if (group != null) message["group"] = group
        if (actions.isNotEmpty()) message["actions"] = actions
        sendJson(message)
    }

    /**
     * `group` is the phone's own hash (NOTIFY-20): 8 bytes of SHA-256 printed
     * as lowercase hex, nothing else. Any other shape is dropped — the post
     * itself is still the person's, so only the field goes.
     */
    private fun validGroup(raw: String?): String? {
        if (raw == null) return null
        if (raw.length != GROUP_HASH_CHARS || raw.any { it !in '0'..'9' && it !in 'a'..'f' }) {
            log("notify.post group dropped")
            return null
        }
        return raw
    }

    /**
     * `live` (docs/design/notify.md "Part 2b"): the shape the listener's
     * `liveFor` builds and the Mac's `NotifyLive(json:)` reads. A key the Mac
     * never reads is dropped; a known key with the wrong type or outside its
     * range drops the whole object, because the Mac would otherwise trust a
     * value the phone promised. The log names the key, never its value.
     */
    private fun validLive(raw: Any?): Map<String, Any?>? {
        if (raw == null) return null
        val source = raw as? Map<*, *> ?: return dropLive("shape")
        val live = LinkedHashMap<String, Any?>()
        for ((key, value) in source) {
            when (key) {
                "progress" -> {
                    val progress = (value as? Number)?.toDouble()?.takeIf { it.isFinite() }
                        ?: return dropLive("progress")
                    if (progress !in 0.0..1.0) return dropLive("progress")
                    live["progress"] = progress
                }
                "chip" -> {
                    val chip = (value as? String)?.trim() ?: return dropLive("chip")
                    if (chip.isEmpty() || chip.length > NotifyEvents.MAX_CHIP) return dropLive("chip")
                    live["chip"] = chip
                }
                "chrono" -> {
                    val chrono = (value as? Number)?.toLong() ?: return dropLive("chrono")
                    if (chrono <= 0L) return dropLive("chrono")
                    live["chrono"] = chrono
                }
                "countDown" -> {
                    val countDown = value as? Boolean ?: return dropLive("countDown")
                    if (countDown) live["countDown"] = true
                }
                // The Mac reads no other key; an unknown one is dropped.
                else -> Unit
            }
        }
        // An empty object is still the marker a promoted notification sends.
        return live
    }

    private fun dropLive(key: String): Map<String, Any?>? {
        log("notify.post live dropped: $key")
        return null
    }

    /**
     * `notify.image` (docs/design/notify.md): the picture that follows a post
     * for the same id. Re-checked so the Mac never holds more than the phone
     * promised: the id token, the mime allowlist, the side bounds, the encoded
     * cap and a body that decodes. A refusal names the field, never the bytes.
     */
    private fun deviceNotifyImage(obj: Map<String, Any?>) {
        val id = validToken(Json.str(obj["id"]), 64) ?: return dropNotifyImage("id")
        val mime = Json.str(obj["mime"])?.lowercase()
        if (mime == null || mime !in NOTIFY_IMAGE_MIMES) return dropNotifyImage("mime")
        val width = (obj["w"] as? Number)?.toInt() ?: return dropNotifyImage("w")
        val height = (obj["h"] as? Number)?.toInt() ?: return dropNotifyImage("h")
        if (width !in 1..NotifyImageRules.MAX_SIDE) return dropNotifyImage("w")
        if (height !in 1..NotifyImageRules.MAX_SIDE) return dropNotifyImage("h")
        val data = Json.str(obj["data"]) ?: return dropNotifyImage("data")
        val bytes = runCatching { Base64.getDecoder().decode(data) }.getOrNull()
            ?: return dropNotifyImage("data")
        if (bytes.isEmpty() || bytes.size > NotifyImageRules.MAX_BYTES) return dropNotifyImage("bytes")
        val message = LinkedHashMap<String, Any?>()
        message["t"] = "notify.image"
        message["id"] = id
        message["mime"] = mime
        message["w"] = width
        message["h"] = height
        // Canonical base64, so the Mac's decoder never sees padding or wrapping
        // this side tolerated.
        message["data"] = Base64.getEncoder().encodeToString(bytes)
        sendJson(message)
        log("notify.image id=$id mime=$mime w=$width h=$height size=${bytes.size}")
    }

    private fun dropNotifyImage(why: String) {
        log("notify.image dropped: $why")
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

    /**
     * `notify.snapshot` (NOTIFY-1/PATH-6): the ids the phone's active set still
     * holds, after a quiet post for each. Re-validated like every device event:
     * at most [NotifyEvents.MAX_SNAPSHOT_IDS] opaque ids; a malformed one is
     * dropped, the rest still go out.
     */
    private fun deviceNotifySnapshot(obj: Map<String, Any?>) {
        val raw = obj["ids"] as? List<*> ?: run {
            log("notify.snapshot dropped: ids")
            return
        }
        val ids = ArrayList<String>(minOf(raw.size, NotifyEvents.MAX_SNAPSHOT_IDS))
        for (entry in raw) {
            if (ids.size == NotifyEvents.MAX_SNAPSHOT_IDS) break
            val id = validToken(entry as? String, 64) ?: continue
            if (id !in ids) ids += id
        }
        sendJson(mapOf("t" to "notify.snapshot", "ids" to ids))
        log("notify.snapshot ids=${ids.size}")
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
        // Off is off in both directions: the Mac's own setting says so, and its
        // text does not land here either (SHARE-13).
        if (clipGateState == ClipGate.OFF) {
            log("clip.set ignored (clipboard sync is off)")
            return
        }
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
        if (clipGateState == ClipGate.OFF) return
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
        while (!isClosed && clipImagePoll === Thread.currentThread()) {
            val port = clipImages
            if (port != null && clipGateState == ClipGate.ON) {
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
        val rect = """{"t":"window.content","stream":$stream,"x":${content.x},"y":${content.y},"w":${content.w},"h":${content.h}}"""
        val payload = Frames.encodeVideoConfig(VideoConfigPayload(codec, w, h, csd))
        gate.config(stream, rect, Frames.encode(Frames.TYPE_VIDEO_CONFIG, stream, payload))
    }

    override fun onFrame(stream: Int, ptsUs: Long, key: Boolean, data: ByteArray) {
        // The picture's own clock for the power-press gap: one Long store in a
        // fixed ring, no allocation and no display lookup. The session's clock
        // (uptime milliseconds) is the seam the JVM tests replace.
        power.noteFrame(now())
        val payload = Frames.encodeVideoFrame(VideoFramePayload(ptsUs, key, data))
        gate.frame(stream, ptsUs, key, Frames.encode(Frames.TYPE_VIDEO_FRAME, stream, payload))
    }

    /**
     * `window.still` (PHONE-21): the stream is live but its encoder has produced
     * nothing for a second. The Mac counts it as a picture heartbeat, never as a
     * first frame.
     */
    override fun onStill(stream: Int) {
        sendJson(mapOf("t" to "window.still", "stream" to stream))
    }

    // ------------------------------------------------------------------
    // audio sink (device-wide, stream 0)
    // ------------------------------------------------------------------

    override fun onAudioConfig(codec: Int, sampleRate: Int, channels: Int, frameMs: Int, setup: ByteArray) {
        val payload = Frames.encodeAudioConfig(AudioConfigPayload(codec, sampleRate, channels, frameMs, setup))
        val bytes = Frames.encode(Frames.TYPE_AUDIO_CONFIG, 0, payload)
        lastAudioConfig = bytes
        queue.enqueueControl(0, bytes)
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
        lastAudioConfig = null
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
        // One choke point: before `welcome` a session may say only what the
        // handshake and pairing machine own. Post-welcome state (a notify
        // toggle, the panel, the device state) reached a half-open session and
        // the rig read `notify.state` where it expected `pair.reveal`; a peer
        // that has not authenticated must see nothing else. The type only in
        // the log, never a payload.
        val t = obj["t"] as? String ?: ""
        val bytes = Frames.encodeJson(0, Json.encode(obj))
        if (phase != Phase.READY) {
            if (t !in PRE_READY_TYPES) {
                logOnce("dropped before ready: $t")
                return
            }
            // The handshake and pairing frames are bare: no session seq space
            // exists before `welcome` (PATH-2).
            hub.sendOn(firstPathId, bytes)
            return
        }
        queue.enqueueJson(bytes)
    }

    private fun sendError(code: String, message: String, stream: Int = 0) {
        sendJson(mapOf("t" to "error", "code" to code, "message" to message, "stream" to stream))
    }

    private fun rejectProtocol(why: String) {
        log("protocol error: $why")
        sendError("protocol", why)
        apply(SessionTeardown.Event.Stop)
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
     * Polls the top task on each display (phone-mode `window.title`, an app
     * stream's task label) and, at most every [exitPollIntervalMs], whether an
     * app window's display still has a task. It performs no query at all while
     * there are no streams (the task list is only polled while ≥1 stream is open
     * and unpaused).
     */
    private fun streamWatchLoop() {
        var lastExitCheck = 0L
        var lastSecureCheck = 0L
        while (!isClosed) {
            val snapshot = synchronized(streams) { streams.values.toList() }
            // A held label's due time: the loop comes back for it instead of
            // waiting its whole second (WIN-28's "the last value always goes out").
            var wakeAtMs = 0L
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
                    val nowMs = System.currentTimeMillis()
                    for (s in unpaused) {
                        val top = runCatching { observer.topTask(s.displayId) }.getOrNull() ?: continue
                        val previous = s.lastTitle
                        val changed = top != previous
                        // The app on top, not its label: a browser's tab title is
                        // the throttled case, its package is not (WIN-3, WIN-28).
                        val appChanged = previous == null || previous.pkg != top.pkg || previous.label != top.label
                        if (changed) {
                            s.lastTitle = top
                            titlesChanged = true
                        }
                        if (top.taskId > 0) s.taskId = top.taskId
                        when (s.content) {
                            is WindowContent.App, is WindowContent.Link -> {
                                val due = tickAppTitle(s, top, appChanged, nowMs)
                                if (due > 0 && (wakeAtMs == 0L || due < wakeAtMs)) wakeAtMs = due
                            }
                            else -> if (changed) {
                                // The phone's own screen: today's message, at once.
                                sendJson(mapOf("t" to "window.title", "stream" to s.stream, "label" to top.label, "pkg" to top.pkg))
                            }
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

            val wakeMs = if (wakeAtMs == 0L) 1_000L else (wakeAtMs - System.currentTimeMillis()).coerceIn(20L, 1_000L)
            synchronized(pairLock) { if (!isClosed) runCatching { pairLock.wait(wakeMs) } }
        }
    }

    /**
     * One tick of an app or link stream's `window.title` (WIN-3, WIN-28). Every
     * message carries the display's `label` and `pkg`; `title` is the task's own
     * label, the app's while the phone describes none.
     *
     * A new app on top goes out at once (the Mac's link and handoff windows take
     * their package from it) and its title counts as the second's send; a change
     * to the title alone waits the machine's second. Returns the time a held
     * label is due, or 0 when nothing waits.
     */
    private fun tickAppTitle(s: StreamState, top: TopTask, appChanged: Boolean, nowMs: Long): Long {
        val title = top.taskLabel ?: top.label
        var state = s.title
        val events = if (appChanged) {
            listOf(TaskLabelThrottle.Event.Immediate(title, nowMs))
        } else {
            listOf(TaskLabelThrottle.Event.Label(title, nowMs), TaskLabelThrottle.Event.Wake(nowMs))
        }
        val actions = ArrayList<TaskLabelThrottle.Action>(2)
        for (event in events) {
            val step = TaskLabelThrottle.transition(state, event)
            state = step.state
            actions.addAll(step.actions)
        }
        s.title = state
        var due = 0L
        for (action in actions) {
            when (action) {
                is TaskLabelThrottle.Action.Send -> {
                    sendJson(
                        mapOf(
                            "t" to "window.title", "stream" to s.stream,
                            "label" to top.label, "pkg" to top.pkg, "title" to action.label,
                        ),
                    )
                    // R-PRIV-1: a label is phone content — its length, never it.
                    log("window.title stream=${s.stream} task=${s.taskId} len=${action.label.length}")
                }
                is TaskLabelThrottle.Action.Wake -> due = action.atMs
            }
        }
        return due
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
        gate.forget(stream)
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
     * Tells the power policy what the session holds now. [ids] is every open app
     * stream's display, covered windows included: a pause is not a close, and a
     * window the Mac covers must not take its display (or the episode) with it.
     * [allPaused] says every one of them is covered, which starts the grace.
     */
    private fun updatePower() {
        val ids: List<Int>
        val allPaused: Boolean
        val mirroring: Boolean
        var phoneOpen = false
        synchronized(streams) {
            val open = streams.values.toList()
            val apps = open.filter { it.content != WindowContent.Phone }
            ids = apps.map { it.displayId }
            allPaused = apps.isNotEmpty() && apps.all { it.paused }
            mirroring = open.any { it.content == WindowContent.Phone && !it.paused }
            phoneOpen = open.any { it.content == WindowContent.Phone }
        }
        // The hold owns `state.panel` (paused, resumed, closed) and reports a
        // change through `onPanelChanged`; the session only says what it sees.
        power.setActiveStreams(ids, allPaused = allPaused, mirroring = mirroring, phoneWindowOpen = phoneOpen)
    }

    private fun streamOf(obj: Map<String, Any?>, frame: Frame): Int =
        Json.int(obj["stream"]) ?: frame.stream

    private fun launchOn(displayId: Int, pkg: String, activity: String?, newInstance: Boolean): Boolean {
        if (displayId < 0) return false
        val ok = runCatching { launcher.launch(displayId, pkg, activity, newInstance) }.getOrDefault(false)
        if (!ok) log("launch $pkg failed on display $displayId")
        return ok
    }

    private fun viewOn(displayId: Int, url: String): Boolean {
        if (displayId < 0) return false
        val ok = runCatching { launcher.view(displayId, url) }.getOrDefault(false)
        if (!ok) log("view link failed on display $displayId")
        return ok
    }

    private fun logOnce(message: String) {
        if (loggedUnknown.add(message)) log(message)
    }

    companion object {
        const val PROTOCOL_VERSION = 4
        const val OWN_PACKAGE = "dev.pocketdeck"
        const val PHONE_DISPLAY = 0
        const val KEYCODE_BACK = 4
        const val KEYCODE_HOME = 3
        const val KEYCODE_APP_SWITCH = 187

        /**
         * The only types a session may send before `welcome` (docs/PROTOCOL.md
         * "Session handshake" and "Pairing"): the handshake, the §4 pairing
         * machine, and the fail-closed `error`. Everything else is post-welcome
         * state.
         */
        val PRE_READY_TYPES = setOf("welcome", "pair.commit", "pair.reveal", "pair.ok", "pair.qr", "error")

        /** The phone's own screen: where "Continue on Mac" looks. */
        const val PHONE_DISPLAY_ID = 0

        /**
         * R-1/PATH-15: the session's inbound hand-off is bounded by bytes, not
         * by a frame count: a 256-slot queue could hold 2 GiB of 8 MiB frames.
         * The reorder window's own budget covers it because a delivered frame
         * has left the window; a single frame larger than the budget is still
         * admitted when the queue is empty.
         */
        const val INBOX_MAX_BYTES = 4 shl 20
        const val PATH_FRAME_OVERHEAD = 9

        /** How long `window.opened` waits for the task id the launch made. */
        const val TASK_WAIT_MS = 2_000L
        const val TASK_POLL_MS = 50L

        /** D-1: the ticker's floor and its idle keepalive wake. */
        const val TICK_MIN_MS = 5L
        const val TICK_KEEPALIVE_MS = 60_000L

        /** A sanity bound on `notify.action`'s index (the app checks the real set). */
        const val MAX_ACTION_INDEX = 64

        /** `NotifyEvents.groupHash`: 8 bytes of SHA-256 printed as lowercase hex. */
        const val GROUP_HASH_CHARS = 16

        /** The two formats the phone's `NotifyImageRules` can produce. */
        private val NOTIFY_IMAGE_MIMES = setOf(
            NotifyImageRules.mime(hasAlpha = false),
            NotifyImageRules.mime(hasAlpha = true),
        )

        /** The clipboard-image poll: images are user-paced, not sub-second. */
        const val CLIP_IMAGE_POLL_MS = 1_000L

        /** `state.secure` is polled at most this often, and only for a phone window. */
        const val SECURE_POLL_MS = 1_000L

        /** Bounds the kernel's video backlog so the delta-drop rule can fire. */
        const val SEND_BUFFER_BYTES = 128 * 1024

        /** The pairing phase's read poll: a decision may land on another thread. */
        const val PAIR_POLL_MS = 250

        /** Virtual displays and encoders need dimensions that are multiples of 16. */
        fun floor16(v: Int): Int = if (v <= 0) 0 else (v / 16) * 16

        /**
         * One daemon for every session's TLS close: the platform close waits for
         * a reader stuck in `SSL_read` and can take as long as the peer, so it
         * must never hold a reader, a writer or a binder thread (PAIR-20).
         */
        private val tlsCloser: java.util.concurrent.Executor =
            Executors.newSingleThreadExecutor { r ->
                Thread(r, "pocketdeck-tls-close").apply { isDaemon = true }
            }
    }
}
