package dev.pocketdeck.server

import dev.pocketdeck.proto.Crypto
import dev.pocketdeck.proto.Frame
import dev.pocketdeck.proto.FrameReader
import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.Json
import dev.pocketdeck.proto.VideoConfigPayload
import dev.pocketdeck.proto.VideoFramePayload
import java.io.BufferedOutputStream
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.atomic.AtomicBoolean

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
    private val now: () -> Long = { System.nanoTime() / 1_000_000 },
    private val log: (String) -> Unit = {},
    private val handshakeTimeoutMs: Int = 15_000,
    /** How long a person has to tap Allow or Deny before the request expires. */
    private val pairDecisionTimeoutMs: Long = 120_000,
    private val exitPollIntervalMs: Long = 2_000,
    maxDeltaBytesPerStream: Int = SendQueue.DEFAULT_MAX_DELTA_BYTES,
    private val autoApprovePairing: Boolean = false,
) : VideoSink {

    private enum class Phase { HELLO, AUTH, READY }

    private class StreamState(val stream: Int, val displayId: Int, var size: IntSize) {
        var paused = false
        var content: WindowContent? = null
        var lastTitle: TopApp? = null
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

    private var clientId = ""
    private var clientName = "Mac"
    private var nonce = ""

    /** Guarded by [pairLock]: the open pairing request and whether it was already settled. */
    private var pendingPairId: String? = null
    private var pairSettled = false
    private var currentMacName: String? = null

    private val loggedUnknown = HashSet<String>()

    private var writerThread: Thread? = null
    private var stateHandle: AutoCloseable? = null
    private var watchThread: Thread? = null

    /** The protocol's `state` stream: one emission per real change. */
    private val stateTracker = DeviceStateTracker { state ->
        sendJson(mapOf("t" to "state", "locked" to state.locked, "battery" to state.battery, "charging" to state.charging))
    }

    val isClosed: Boolean get() = closed.get()

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
        runCatching { apk?.close() }
        stopStreamWatch()
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
            Phase.AUTH -> when (t) {
                "hello" -> onHello(obj)
                "auth" -> onAuth(obj)
                "pair.request" -> onPairRequest()
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
        nonce = Crypto.toHex(Crypto.randomBytes(16))
        // `id` lets a Mac that connected by address pick the right stored key.
        sendJson(mapOf("t" to "challenge", "nonce" to nonce, "id" to device.info().id))
        phase = Phase.AUTH
    }

    private fun onAuth(obj: Map<String, Any?>) {
        val mac = Json.str(obj["mac"]) ?: ""
        val client = store.snapshot().firstOrNull { it.clientId == clientId }
        if (client == null) {
            sendError("auth_failed", "unknown client")
            closeRequested = true
            return
        }
        val key = try {
            Crypto.fromHex(client.keyHex)
        } catch (e: Exception) {
            sendError("auth_failed", "bad stored key")
            closeRequested = true
            return
        }
        val expected = Crypto.hmacSha256Hex(key, nonce.toByteArray(Charsets.UTF_8))
        if (!Crypto.constantTimeEquals(expected, mac.lowercase())) {
            sendError("auth_failed", "bad mac")
            closeRequested = true
            return
        }
        currentMacName = client.name
        welcome()
    }

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
        val code = "%06d".format((0..999999).random())
        // A person decides on the phone while this thread only watches for the
        // Mac going away, so no read timeout applies; the watchdog below bounds
        // the wait instead.
        runCatching { socket.soTimeout = 0 }
        sendJson(mapOf("t" to "pair.code_shown", "code" to code))
        if (autoApprovePairing) {
            log("debug build: auto-approved pairing for $clientName")
            synchronized(pairLock) { pairSettled = true }
            completePairing()
            return
        }
        runCatching { callback.onPairingRequest(id, clientName, code) }
        Thread({ expirePairing(id) }, "pocketdeck-pair-timeout").also {
            it.isDaemon = true
            it.start()
        }
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

    private fun completePairing() {
        val key = Crypto.randomBytes(32)
        val keyHex = Crypto.toHex(key)
        val client = PairedClient(clientId, clientName, keyHex)
        store.add(client)
        currentMacName = clientName
        sendJson(mapOf("t" to "pair.ok", "key" to keyHex))
        runCatching { callback.onPaired(clientId, clientName, keyHex) }
        welcome()
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
            "nav" -> onNav(obj, frame)
            "text" -> onText(obj, frame)
            "clip.set" -> onClipSet(obj)
            "apk.install" -> onApkInstall(obj)
            "apk.cancel" -> (obj["id"] as? Number)?.let { apk?.cancel(it.toLong()) }
            else -> logOnce("unknown message '$t'")
        }
    }

    private fun onAppsList() {
        val apps = catalog.list().map { mapOf("pkg" to it.pkg, "label" to it.label, "activity" to it.activity) }
        sendJson(mapOf("t" to "apps", "apps" to apps))
    }

    private fun onAppsIcon(obj: Map<String, Any?>) {
        val pkg = Json.str(obj["pkg"]) ?: return
        sendJson(mapOf("t" to "icon", "pkg" to pkg, "png" to (catalog.iconPng(pkg) ?: "")))
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

    /** Creates the display for a `window.open` / `link.open` and starts its content. */
    private fun openStream(obj: Map<String, Any?>, stream: Int, content: WindowContent) {
        val w = floor16(Json.int(obj["w"]) ?: 0)
        val h = floor16(Json.int(obj["h"]) ?: 0)
        val dpi = Json.int(obj["dpi"]) ?: 160
        if (w <= 0 || h <= 0) {
            sendError("bad_size", "${obj["t"]} needs w,h", stream)
            return
        }
        if (streams.containsKey(stream)) display.close(stream)
        val displayId = display.open(stream, w, h, dpi, this)
        val state = StreamState(stream, displayId, IntSize(w, h)).also { it.content = content }
        synchronized(streams) { streams[stream] = state }
        sendJson(mapOf("t" to "window.opened", "stream" to stream, "displayId" to displayId, "w" to w, "h" to h))
        when (content) {
            is WindowContent.App -> launchOn(stream, displayId, content.pkg, content.activity)
            WindowContent.Phone -> launchOn(stream, displayId, OWN_PACKAGE, LAUNCHER_ACTIVITY)
            is WindowContent.Link -> viewOn(stream, displayId, content.url)
        }
        power.setActiveStreams(activeDisplayIds())
        runCatching { callback.onSessionChanged(true, currentMacName ?: clientName, windowCount()) }
        startStreamWatch()
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
    }

    private fun onNav(obj: Map<String, Any?>, frame: Frame) {
        val state = requireState(streamOf(obj, frame)) ?: return
        when (Json.str(obj["action"])) {
            "back" -> {
                val t = bumpTime(state)
                injector.key(state.displayId, Frames.ACTION_DOWN, KEYCODE_BACK, 0, t, t)
                injector.key(state.displayId, Frames.ACTION_UP, KEYCODE_BACK, 0, t, t + 1)
            }
            "home" -> launchOn(state.stream, state.displayId, OWN_PACKAGE, LAUNCHER_ACTIVITY)
            "recents" -> log("recents: no-op in v0")
            else -> logOnce("unknown nav action")
        }
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
                power.onInput(state.displayId)
            }
            Frames.TYPE_SCROLL -> {
                val p = Frames.decodeScroll(frame.payload)
                val state = requireState(frame.stream) ?: return
                injector.scroll(state.displayId, p.nx, p.ny, p.hscroll, p.vscroll, display.size(state.stream))
                power.onInput(state.displayId)
            }
            Frames.TYPE_APK_DATA -> apk?.data(frame.stream.toLong() and 0xFFFF_FFFFL, frame.payload)
            Frames.TYPE_KEY -> {
                val p = Frames.decodeKey(frame.payload)
                val state = requireState(frame.stream) ?: return
                val t = bumpTime(state)
                val downTime = if (p.action == Frames.ACTION_DOWN) t else state.keyDownTime
                if (p.action == Frames.ACTION_DOWN) state.keyDownTime = t
                injector.key(state.displayId, p.action, p.keycode, p.metaState, downTime, t)
                power.onInput(state.displayId)
            }
            else -> logOnce("unknown frame type 0x${frame.type.toString(16)}")
        }
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
                    for (s in unpaused) {
                        val top = runCatching { observer.topApp(s.displayId) }.getOrNull() ?: continue
                        if (top != s.lastTitle) {
                            s.lastTitle = top
                            sendJson(mapOf("t" to "window.title", "stream" to s.stream, "label" to top.label, "pkg" to top.pkg))
                        }
                    }
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
            // Phone-mode windows run our own launcher and never auto-close.
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

    private fun activeDisplayIds(): List<Int> = synchronized(streams) {
        streams.values.filter { !it.paused }.map { it.displayId }
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
        const val PROTOCOL_VERSION = 1
        const val OWN_PACKAGE = "dev.pocketdeck"
        const val LAUNCHER_ACTIVITY = "dev.pocketdeck.launcher.LauncherActivity"
        const val KEYCODE_BACK = 4

        /** Bounds the kernel's video backlog so the delta-drop rule can fire. */
        const val SEND_BUFFER_BYTES = 128 * 1024

        /** Virtual displays and encoders need dimensions that are multiples of 16. */
        fun floor16(v: Int): Int = if (v <= 0) 0 else (v / 16) * 16
    }
}
