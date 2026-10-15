package dev.pocketdeck.server

import java.util.concurrent.CopyOnWriteArrayList

/** Lets a test feed a canned H.264 stream to a stream's sink. */
fun interface CannedVideo {
    fun start(stream: Int, w: Int, h: Int, sink: VideoSink)
}

/**
 * A fully recording fake of every platform seam. Shared by the session tests
 * and the C4 loopback harness.
 */
class FakePlatform : DisplayLayer, AppCatalog, Launcher, Injector, Power, DeviceSource, PairingStore, DeckCallback, ClipboardPort {

    data class OpenCall(val stream: Int, val w: Int, val h: Int, val dpi: Int, val displayId: Int)
    data class ResizeCall(val stream: Int, val w: Int, val h: Int, val dpi: Int)
    data class LaunchCall(val displayId: Int, val pkg: String, val activity: String?)
    data class ViewCall(val displayId: Int, val url: String)
    data class TouchCall(val displayId: Int, val action: Int, val pointerId: Int, val nx: Float, val ny: Float, val downTime: Long, val eventTime: Long)
    data class KeyCall(val displayId: Int, val action: Int, val keycode: Int, val metaState: Int, val downTime: Long, val eventTime: Long)
    data class PairingReq(val requestId: String, val macName: String, val code: String)
    data class SessionChange(val connected: Boolean, val macName: String?, val windows: Int)
    data class QualityCall(val stream: Int, val bitrate: Int?, val maxFps: Int?)

    val opens = CopyOnWriteArrayList<OpenCall>()
    val mirrors = CopyOnWriteArrayList<Int>()
    var screenSize = IntSize(1080, 2340)
    var mirrorFails = false
    val resizes = CopyOnWriteArrayList<ResizeCall>()
    val pauses = CopyOnWriteArrayList<Int>()
    val resumes = CopyOnWriteArrayList<Int>()
    val keyframeRequests = CopyOnWriteArrayList<Int>()
    val closes = CopyOnWriteArrayList<Int>()
    val launches = CopyOnWriteArrayList<LaunchCall>()
    val views = CopyOnWriteArrayList<ViewCall>()
    val touches = CopyOnWriteArrayList<TouchCall>()
    val keys = CopyOnWriteArrayList<KeyCall>()
    val scrolls = CopyOnWriteArrayList<Int>()
    val texts = CopyOnWriteArrayList<String>()
    val activeStreams = CopyOnWriteArrayList<List<Int>>()
    val inputs = CopyOnWriteArrayList<Int>()
    val qualities = CopyOnWriteArrayList<QualityCall>()
    val backpressures = CopyOnWriteArrayList<Int>()

    val clients = CopyOnWriteArrayList<PairedClient>()
    val pairRequests = CopyOnWriteArrayList<PairingReq>()
    val paired = CopyOnWriteArrayList<PairedClient>()
    val pairEnded = CopyOnWriteArrayList<String>()
    val sessionChanges = CopyOnWriteArrayList<SessionChange>()

    var apps: List<AppEntry> = emptyList()
    var iconResult: String? = null
    var launchResult = true
    var deviceInfo = DeviceInfo("dev1", "Pixel", "Pixel 9", 36, 1080, 2340, 450, true)
    var deviceState = DeviceState(true, 55, false)
    var video: CannedVideo? = null
    var onPairingRequestHandler: ((PairingReq) -> Unit)? = null

    private val sizes = HashMap<Int, IntSize>()
    private var nextDisplayId = 100

    // ---- DisplayLayer -------------------------------------------------

    override fun open(stream: Int, w: Int, h: Int, dpi: Int, sink: VideoSink): Int {
        val id = nextDisplayId++
        opens.add(OpenCall(stream, w, h, dpi, id))
        sizes[stream] = IntSize(w, h)
        video?.start(stream, w, h, sink)
        return id
    }

    override fun openMirror(stream: Int, w: Int, h: Int, sink: VideoSink): IntSize {
        check(!mirrorFails) { "no mirror on this phone" }
        mirrors.add(stream)
        sizes[stream] = screenSize
        val fit = MirrorFit.fit(IntSize(w, h), screenSize)
        video?.start(stream, fit.w, fit.h, sink)
        return fit
    }

    override fun size(stream: Int): IntSize = sizes[stream] ?: IntSize(0, 0)

    override fun resize(stream: Int, w: Int, h: Int, dpi: Int) {
        resizes.add(ResizeCall(stream, w, h, dpi))
        sizes[stream] = IntSize(w, h)
    }

    override fun pause(stream: Int) {
        pauses.add(stream)
    }

    override fun resume(stream: Int) {
        resumes.add(stream)
    }

    override fun requestKeyframe(stream: Int) {
        keyframeRequests.add(stream)
    }

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

    override fun iconPng(pkg: String): String? = iconResult

    // ---- Launcher -----------------------------------------------------

    override fun launch(displayId: Int, pkg: String, activity: String?): Boolean {
        launches.add(LaunchCall(displayId, pkg, activity))
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

    override fun setActiveStreams(displayIds: List<Int>) {
        activeStreams.add(displayIds)
    }

    override fun onSessionEnded() = Unit

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
    val clipWrites = CopyOnWriteArrayList<String>()
    @Volatile private var clipListener: ((String) -> Unit)? = null

    override fun getText(): String? = clipText

    /**
     * Like the platform, a write notifies the listener, which is the echo the
     * session must not send back. The write is recorded last, so a test that
     * sees it knows the echo has already been handled.
     */
    override fun setText(text: String) {
        clipText = text
        clipListener?.invoke(text)
        clipWrites.add(text)
    }

    override fun listen(onChange: (String) -> Unit) {
        clipListener = onChange
    }

    override fun stop() {
        clipListener = null
    }

    /** Whether the session has started listening; it does so just after `welcome` is queued. */
    val clipListening: Boolean get() = clipListener != null

    /** Simulates the person copying [text] on the phone. */
    fun changeClip(text: String) {
        clipText = text
        clipListener?.invoke(text)
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

    override fun onPaired(clientId: String, name: String, keyHex: String) {
        paired.add(PairedClient(clientId, name, keyHex))
    }

    override fun onSessionChanged(connected: Boolean, macName: String?, windows: Int) {
        sessionChanges.add(SessionChange(connected, macName, windows))
    }
}
