package dev.pocketdeck.server

import java.util.concurrent.CopyOnWriteArrayList

/** Lets a test feed a canned H.264 stream to a stream's sink. */
fun interface CannedVideo {
    fun start(stream: Int, w: Int, h: Int, sink: VideoSink)
}

/**
 * Deterministic v2 TLS fixture for the loopback session tests: fingerprints and
 * exporter from the design's vector B (docs/design/e2ee.md §4); the nonces are
 * not fixtures — they flow through the live commit/nonce/reveal exchange.
 */
object TlsV2Fixture {
    const val MAC_FP_HEX = "20ac3461fdd5af5cc0b6c0c7ca6cf2df8edb8eb1322096c3fc9e06297e97dc41"
    const val PHONE_FP_HEX = "88227c41edbdf92b83c27bff6ae8570eb14144050a5b0903e351a777e09ecfe5"

    private fun digest(hexOr: String): ByteArray =
        java.security.MessageDigest.getInstance("SHA-256").digest(hexOr.toByteArray(Charsets.UTF_8))

    val exporterBytes: ByteArray = digest("pd-v2-vector exporter")
    val macFpBytes: ByteArray = bytesOf(MAC_FP_HEX)
    val phoneFpBytes: ByteArray = bytesOf(PHONE_FP_HEX)

    fun bytesOf(hex: String): ByteArray {
        val clean = hex.trim().lowercase()
        return ByteArray(clean.length / 2) { i -> clean.substring(i * 2, i * 2 + 2).toInt(16).toByte() }
    }

    /** The injected TlsView the JVM tests share (§4b: no engine needed). */
    val view: dev.pocketdeck.server.Session.TlsView = Session.TlsView(
        peerFingerprint = { macFpBytes },
        selfFingerprint = { phoneFpBytes },
        exporter = { exporterBytes },
    )
}

/**
 * A fully recording fake of every platform seam. Shared by the session tests
 * and the C4 loopback harness.
 */
class FakePlatform : DisplayLayer, AppCatalog, Launcher, Injector, Power, DeviceSource, PairingStore, DeckCallback, ClipboardPort {

    data class OpenCall(val stream: Int, val w: Int, val h: Int, val dpi: Int, val displayId: Int)
    data class ResizeCall(val stream: Int, val w: Int, val h: Int, val dpi: Int)
    data class LaunchCall(val displayId: Int, val pkg: String, val activity: String?, val newInstance: Boolean)
    data class ViewCall(val displayId: Int, val url: String)
    data class TouchCall(val displayId: Int, val action: Int, val pointerId: Int, val nx: Float, val ny: Float, val downTime: Long, val eventTime: Long)
    data class KeyCall(val displayId: Int, val action: Int, val keycode: Int, val metaState: Int, val downTime: Long, val eventTime: Long)
    data class HoverCall(val displayId: Int, val action: Int, val nx: Float, val ny: Float)
    data class PairingReq(val requestId: String, val macName: String, val code: String)
    data class SessionChange(val connected: Boolean, val clientId: String?, val macName: String?, val windows: Int)
    data class QualityCall(val stream: Int, val bitrate: Int?, val maxFps: Int?)

    val opens = CopyOnWriteArrayList<OpenCall>()
    val mirrors = CopyOnWriteArrayList<Int>()
    var screenSize = IntSize(1080, 2340)
    var mirrorFails = false
    var openFails = false
    val resizes = CopyOnWriteArrayList<ResizeCall>()
    val pauses = CopyOnWriteArrayList<Int>()
    val resumes = CopyOnWriteArrayList<Int>()
    val keyframeRequests = CopyOnWriteArrayList<Int>()
    val closes = CopyOnWriteArrayList<Int>()
    val launches = CopyOnWriteArrayList<LaunchCall>()
    val views = CopyOnWriteArrayList<ViewCall>()
    val touches = CopyOnWriteArrayList<TouchCall>()
    val keys = CopyOnWriteArrayList<KeyCall>()
    val hovers = CopyOnWriteArrayList<HoverCall>()
    val scrolls = CopyOnWriteArrayList<Int>()
    val texts = CopyOnWriteArrayList<String>()
    val activeStreams = CopyOnWriteArrayList<List<Int>>()
    /** Every setActiveStreams call with its flags, in order: (displays, allPaused, mirroring). */
    val streamCalls = CopyOnWriteArrayList<Triple<List<Int>, Boolean, Boolean>>()
    /** Whether a phone window stream was open at each call (paused or not). */
    val phoneWindows = CopyOnWriteArrayList<Boolean>()
    val inputs = CopyOnWriteArrayList<Int>()
    val qualities = CopyOnWriteArrayList<QualityCall>()
    val backpressures = CopyOnWriteArrayList<Int>()
    /** ISS-40: what each `stream.stats {on}` asked for, and the next snapshot. */
    val statsSettings = CopyOnWriteArrayList<Boolean>()
    var encoderStats: EncoderStats? = EncoderStats(
        frames = 120, keyframes = 2, keyframesRequested = 1, bytes = 250_000,
        framesSkipped = 0, targetBps = 8_000_000,
        encodeP50 = 12_000, encodeP95 = 18_000, qpP50 = null, qpP95 = null,
    )

    val clients = CopyOnWriteArrayList<PairedClient>()
    val pairRequests = CopyOnWriteArrayList<PairingReq>()
    val paired = CopyOnWriteArrayList<PairedClient>()
    val pairEnded = CopyOnWriteArrayList<String>()
    val sessionChanges = CopyOnWriteArrayList<SessionChange>()
    /** R-8: every protocol version a Mac's hello was refused for (null = absent). */
    val versionRefusals = CopyOnWriteArrayList<Int?>()

    var apps: List<AppEntry> = emptyList()
    var iconResult: String? = null
    var iconLayersResult: IconLayers? = null
    val iconPngPx = mutableListOf<Int?>()
    val iconLayersPx = mutableListOf<Int?>()
    var launchResult = true
    var deviceInfo = DeviceInfo("dev1", "Pixel", "Pixel 9", 36, 1080, 2340, 450, true)
    var deviceState = DeviceState(true, 55, false)
    val wakeCalls = CopyOnWriteArrayList<WakeResult>()
    var wakeResult = WakeResult.OK
    var onWake: (() -> Unit)? = null
    var video: CannedVideo? = null
    var onPairingRequestHandler: ((PairingReq) -> Unit)? = null
    /** Runs inside `open` before it returns: a slow encoder/VD start (stream). */
    var onOpen: ((Int) -> Unit)? = null
    /** Runs inside `requestKeyframe`: a display busy with another window's open. */
    var onKeyframeRequest: ((Int) -> Unit)? = null

    private val sizes = HashMap<Int, IntSize>()
    private var nextDisplayId = 100

    // ---- DisplayLayer -------------------------------------------------

    override fun open(stream: Int, w: Int, h: Int, dpi: Int, sink: VideoSink): Int {
        check(!openFails) { "display open failed" }
        val id = nextDisplayId++
        opens.add(OpenCall(stream, w, h, dpi, id))
        sizes[stream] = IntSize(w, h)
        video?.start(stream, w, h, sink)
        onOpen?.invoke(stream)
        return id
    }

    override fun openMirror(stream: Int, w: Int, h: Int, sink: VideoSink): IntSize {
        check(!mirrorFails) { "no mirror on this phone" }
        mirrors.add(stream)
        sizes[stream] = screenSize
        val frame = MirrorFrame.pick(IntSize(w, h), screenSize, IntSize(16, 16), Int.MAX_VALUE, Int.MAX_VALUE)
        video?.start(stream, frame.w, frame.h, sink)
        return frame
    }

    override fun size(stream: Int): IntSize = sizes[stream] ?: IntSize(0, 0)

    override fun resize(stream: Int, w: Int, h: Int, dpi: Int): ResizeOutcome {
        resizes.add(ResizeCall(stream, w, h, dpi))
        sizes[stream] = IntSize(w, h)
        return ResizeOutcome.RESIZED
    }

    override fun pause(stream: Int) {
        pauses.add(stream)
    }

    override fun resume(stream: Int) {
        resumes.add(stream)
    }

    override fun requestKeyframe(stream: Int) {
        keyframeRequests.add(stream)
        onKeyframeRequest?.invoke(stream)
    }

    override fun setStatsEnabled(on: Boolean) {
        statsSettings.add(on)
    }

    override fun statsSnapshot(stream: Int, nowUs: Long, reset: Boolean): EncoderStats? =
        encoderStats

    override fun close(stream: Int) {
        closes.add(stream)
        sizes.remove(stream)
    }

    override fun setQuality(stream: Int, bitrate: Int?, maxFps: Int?) {
        qualities.add(QualityCall(stream, bitrate, maxFps))
    }

    override fun onBackpressure(stream: Int) {
        backpressures.add(stream)
    }

    // ---- AppCatalog ---------------------------------------------------

    override fun list(): List<AppEntry> = apps

    override fun iconPng(pkg: String, px: Int?): String? {
        iconPngPx.add(px)
        return iconResult
    }

    override fun iconLayers(pkg: String, px: Int?): IconLayers? {
        iconLayersPx.add(px)
        return iconLayersResult
    }

    // ---- Launcher -----------------------------------------------------

    override fun launch(displayId: Int, pkg: String, activity: String?, newInstance: Boolean): Boolean {
        launches.add(LaunchCall(displayId, pkg, activity, newInstance))
        return launchResult
    }

    override fun view(displayId: Int, url: String): Boolean {
        views.add(ViewCall(displayId, url))
        return launchResult
    }

    // ---- Injector -----------------------------------------------------

    override fun touch(displayId: Int, action: Int, pointerId: Int, nx: Float, ny: Float, size: IntSize, downTime: Long, eventTime: Long) {
        touches.add(TouchCall(displayId, action, pointerId, nx, ny, downTime, eventTime))
    }

    override fun scroll(displayId: Int, nx: Float, ny: Float, hscroll: Float, vscroll: Float, size: IntSize) {
        scrolls.add(displayId)
    }

    override fun hover(displayId: Int, action: Int, nx: Float, ny: Float, size: IntSize) {
        hovers.add(HoverCall(displayId, action, nx, ny))
    }

    override fun key(displayId: Int, action: Int, keycode: Int, metaState: Int, downTime: Long, eventTime: Long) {
        keys.add(KeyCall(displayId, action, keycode, metaState, downTime, eventTime))
    }

    override fun text(displayId: Int, s: String) {
        texts.add(s)
    }

    // ---- Power --------------------------------------------------------

    override fun onInput(displayId: Int) {
        inputs.add(displayId)
    }

    override fun setActiveStreams(
        displayIds: List<Int>,
        allPaused: Boolean,
        mirroring: Boolean,
        phoneWindowOpen: Boolean,
    ) {
        activeStreams.add(displayIds)
        streamCalls.add(Triple(displayIds, allPaused, mirroring))
        phoneWindows.add(phoneWindowOpen)
        // Model the hold the way AndroidPower's machine does, so a session
        // test sees the same `state.panel` truth the phone reports.
        mirrorActive = mirroring
        if (!phoneWindowOpen) {
            heldRequested = false
            if (panelHeld) setPanelHeld(false)
        } else if (!mirroring && panelHeld) {
            setPanelHeld(false)
        } else if (mirroring && heldRequested && !panelHeld) {
            setPanelHeld(true)
        }
    }

    override fun onSessionEnded() = Unit

    /** False makes `phone.panel` answer `unavailable` (a build without panel control). */
    var mirrorPanelOffSupported = true
    val mirrorPanelOffs = CopyOnWriteArrayList<Boolean>()
    /** Every `phone.panel` request with the Mac's keep-it-off setting. */
    val panelRequests = CopyOnWriteArrayList<Pair<Boolean, Boolean>>()
    override var onPanelChanged: ((Boolean) -> Unit)? = null

    @Volatile private var panelHeld = false
    @Volatile private var heldRequested = false
    @Volatile private var mirrorActive = false
    override val panelHeldOff: Boolean get() = panelHeld

    private fun setPanelHeld(on: Boolean) {
        panelHeld = on
        onPanelChanged?.invoke(on)
    }

    /** The phone ends the hold by itself (the person's power press). */
    fun endPanelHold() {
        heldRequested = false
        setPanelHeld(false)
    }

    override fun setMirrorPanelOff(off: Boolean, ignorePower: Boolean): Boolean {
        mirrorPanelOffs.add(off)
        panelRequests.add(off to ignorePower)
        if (!mirrorPanelOffSupported) return false
        heldRequested = off
        if (off) {
            if (mirrorActive) setPanelHeld(true)
        } else {
            setPanelHeld(false)
        }
        return true
    }

    override fun wakeScreen(): WakeResult {
        wakeCalls.add(wakeResult)
        onWake?.invoke()
        return wakeResult
    }

    // ---- DeviceSource -------------------------------------------------

    private val stateSubscribers = CopyOnWriteArrayList<(DeviceState) -> Unit>()

    override fun info(): DeviceInfo = deviceInfo

    override fun state(): DeviceState = deviceState

    override fun subscribeState(onChange: (DeviceState) -> Unit): AutoCloseable? {
        stateSubscribers.add(onChange)
        onChange(deviceState)
        return AutoCloseable { stateSubscribers.remove(onChange) }
    }

    /** Pushes a state to the session like the platform watcher would. */
    fun pushState(state: DeviceState) {
        deviceState = state
        for (subscriber in stateSubscribers) subscriber(state)
    }

    val stateSubscriberCount: Int get() = stateSubscribers.size

    // ---- ClipboardPort ------------------------------------------------

    @Volatile var clipText: String? = null
    /** The system's sensitive mark on the phone's current clip. */
    @Volatile var clipSensitive = false
    val clipWrites = CopyOnWriteArrayList<String>()
    @Volatile private var clipRegistration: ClipRegistration? = null

    /** Every clipboard stop call that finished, live or stale (ISS-13). */
    val clipStopsDone = java.util.concurrent.atomic.AtomicInteger(0)

    /** Every [listen] call: a re-adopt makes the second one (ISS-13). */
    val clipListenCalls = java.util.concurrent.atomic.AtomicInteger(0)

    /** Stops of a replaced or already stopped handle (ISS-13). */
    val staleClipStops = java.util.concurrent.atomic.AtomicInteger(0)

    override fun getText(): ClipText? = clipText?.let { ClipText(it, clipSensitive) }

    /**
     * Like the platform, a write notifies the listener, which is the echo the
     * session must not send back. The write is recorded last, so a test that
     * sees it knows the echo has already been handled.
     */
    override fun setText(text: String) {
        clipText = text
        clipSensitive = false
        clipRegistration?.onChange?.invoke()
        clipWrites.add(text)
    }

    override fun listen(onChange: () -> Unit): ClipRegistration {
        val reg = ClipRegistration(onChange)
        clipRegistration = reg
        clipListenCalls.incrementAndGet()
        return reg
    }

    /**
     * Like the shared port: only the live registration stops delivery; a stale
     * handle changes nothing. [onClipStop] parks a slow teardown before the
     * ownership check, so the world can change while it runs (ISS-13).
     */
    override fun stop(registration: ClipRegistration?) {
        val reg = registration ?: return
        onClipStop?.invoke()
        if (clipRegistration !== reg) staleClipStops.incrementAndGet() else clipRegistration = null
        clipStopsDone.incrementAndGet()
    }

    /** Runs inside the session's shutdown, before the ownership check: a slow teardown. */
    var onClipStop: (() -> Unit)? = null

    /** Whether a session is listening; it does so just after `welcome` is queued. */
    val clipListening: Boolean get() = clipRegistration != null

    /** Simulates the person copying [text] on the phone. */
    fun changeClip(text: String, sensitive: Boolean = false) {
        clipText = text
        clipSensitive = sensitive
        clipRegistration?.onChange?.invoke()
    }

    // ---- PairingStore -------------------------------------------------

    override fun snapshot(): List<PairedClient> = clients

    override fun add(client: PairedClient) {
        if (clients.none { it.clientId == client.clientId }) clients.add(client)
    }

    // ---- DeckCallback -------------------------------------------------

    override fun onPairingRequest(requestId: String, macName: String, code: String) {
        val req = PairingReq(requestId, macName, code)
        pairRequests.add(req)
        onPairingRequestHandler?.invoke(req)
    }

    override fun onPairingEnded(requestId: String) {
        pairEnded.add(requestId)
    }

    override fun onPaired(clientId: String, name: String, macFp: String) {
        paired.add(PairedClient(clientId, name, macFp))
    }

    override fun onSessionChanged(connected: Boolean, clientId: String?, macName: String?, windows: Int) {
        sessionChanges.add(SessionChange(connected, clientId, macName, windows))
    }

    override fun onVersionRefused(macV: Int?) {
        versionRefusals.add(macV)
    }
}
