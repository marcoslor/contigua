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
    private val now: () -> Long = { System.nanoTime() / 1_000_000 },
    private val log: (String) -> Unit = {},
    private val handshakeTimeoutMs: Int = 15_000,
    private val pairDecisionTimeoutMs: Long = 30_000,
    private val exitPollIntervalMs: Long = 2_000,
    maxDeltaBytesPerStream: Int = SendQueue.DEFAULT_MAX_DELTA_BYTES,
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

    private var clientId = ""
    private var clientName = "Mac"
    private var nonce = ""
    private var pendingPairId: String? = null
    private var pairCode = ""
    private var pairAttempts = 0
    private var pairAllowed: Boolean? = null
    private var currentMacName: String? = null

    private val loggedUnknown = HashSet<String>()

    private var writerThread: Thread? = null
    private var stateThread: Thread? = null
    private var watchThread: Thread? = null

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
        stopStateWatch()
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
                "pair.confirm" -> onPairConfirm(obj)
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
        pendingPairId = Crypto.toHex(Crypto.randomBytes(8))
        pairCode = "%06d".format((0..999999).random())
        pairAttempts = 0
        pairAllowed = null
        synchronized(pairLock) { pairLock.notifyAll() }
        val id = pendingPairId!!
        runCatching { callback.onPairingRequest(id, clientName, pairCode) }
        sendJson(mapOf("t" to "pair.code_shown"))
    }

    private fun onPairConfirm(obj: Map<String, Any?>) {
        if (pendingPairId == null) return
        val code = Json.str(obj["code"]) ?: ""
        if (code != pairCode) {
            pairAttempts++
            log("pair code mismatch ($pairAttempts)")
            if (pairAttempts >= 3) denyPairing()
            return
        }
        if (pairAllowed == null) {
            synchronized(pairLock) {
                val deadline = System.currentTimeMillis() + pairDecisionTimeoutMs
                while (pairAllowed == null && !closed.get() && System.currentTimeMillis() < deadline) {
                    pairLock.wait(250)
                }
            }
        }
        if (pairAllowed == true) completePairing() else denyPairing()
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

    private fun denyPairing() {
        sendError("pair_denied", "pairing denied")
        closeRequested = true
    }

    private fun welcome() {
        val d = device.info()
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
        phase = Phase.READY
        // The read timeout only guards the handshake; a live session may be
        // silent for long stretches (static content, no input).
        runCatching { socket.soTimeout = 0 }
        runCatching { callback.onSessionChanged(true, currentMacName ?: clientName, windowCount()) }
        startStateWatch()
    }

    private fun dispatch(obj: Map<String, Any?>, frame: Frame, t: String) {
        when (t) {
            "ping" -> sendJson(mapOf("t" to "pong", "ts" to obj["ts"]))
            "apps.list" -> onAppsList()
            "apps.icon" -> onAppsIcon(obj)
            "window.open" -> onWindowOpen(obj, frame)
            "window.resize" -> onWindowResize(obj, frame)
            "window.close" -> onWindowClose(obj, frame)
            "window.pause" -> onWindowPause(obj, frame)
            "window.resume" -> onWindowResume(obj, frame)
            "window.keyframe" -> onWindowKeyframe(obj, frame)
            "window.launch" -> onWindowLaunch(obj, frame)
            "nav" -> onNav(obj, frame)
            "text" -> onText(obj, frame)
            "clipboard.set" -> logOnce("clipboard.set ignored (not in v0)")
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
        val w = floor16(Json.int(obj["w"]) ?: 0)
        val h = floor16(Json.int(obj["h"]) ?: 0)
        val dpi = Json.int(obj["dpi"]) ?: 160
        if (w <= 0 || h <= 0) {
            sendError("bad_size", "window.open needs w,h", stream)
            return
        }
        val content: WindowContent = if (Json.str(obj["mode"]) == "phone") {
            WindowContent.Phone
        } else {
            val pkg = Json.str(obj["pkg"]) ?: run {
                sendError("bad_request", "window.open needs pkg or mode=phone", stream)
                return
            }
            WindowContent.App(pkg, Json.str(obj["activity"]))
        }
        if (streams.containsKey(stream)) display.close(stream)
        val displayId = display.open(stream, w, h, dpi, this)
        val state = StreamState(stream, displayId, IntSize(w, h)).also { it.content = content }
        synchronized(streams) { streams[stream] = state }
        sendJson(mapOf("t" to "window.opened", "stream" to stream, "displayId" to displayId, "w" to w, "h" to h))
        when (content) {
            is WindowContent.App -> launchOn(stream, displayId, content.pkg, content.activity)
            WindowContent.Phone -> launchOn(stream, displayId, OWN_PACKAGE, LAUNCHER_ACTIVITY)
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
        if (key) queue.enqueueControl(stream, bytes) else queue.enqueueDelta(stream, bytes)
    }

    private fun onDeltaDrop(stream: Int) {
        log("stream $stream backpressure: dropping deltas, requesting keyframe")
        runCatching { display.requestKeyframe(stream) }
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

    /** Called from the app process (binder thread) when the user answers a prompt. */
    fun respondPairing(requestId: String, allow: Boolean) {
        synchronized(pairLock) {
            if (requestId == pendingPairId) {
                pairAllowed = allow
                pairLock.notifyAll()
            }
        }
        if (!allow && requestId == pendingPairId) {
            // Let the (possibly blocked) reader thread produce pair_denied promptly.
        }
    }

    // ------------------------------------------------------------------
    // state watch
    // ------------------------------------------------------------------

    private fun startStateWatch() {
        if (stateThread != null) return
        stateThread = Thread({
            var last: DeviceState? = null
            while (!closed.get()) {
                val s = runCatching { device.state() }.getOrNull()
                if (s != null && s != last) {
                    last = s
                    sendJson(mapOf("t" to "state", "locked" to s.locked, "battery" to s.battery, "charging" to s.charging))
                }
                synchronized(pairLock) {
                    if (!closed.get()) runCatching { pairLock.wait(3_000) }
                }
            }
        }, "pocketdeck-state").also { it.start() }
    }

    private fun stopStateWatch() {
        synchronized(pairLock) { pairLock.notifyAll() }
        runCatching { stateThread?.interrupt() }
        stateThread = null
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
            if (s.content !is WindowContent.App) continue
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

    private fun logOnce(message: String) {
        if (loggedUnknown.add(message)) log(message)
    }

    companion object {
        const val PROTOCOL_VERSION = 1
        const val OWN_PACKAGE = "dev.pocketdeck"
        const val LAUNCHER_ACTIVITY = "dev.pocketdeck.launcher.LauncherActivity"
        const val KEYCODE_BACK = 4

        /** Virtual displays and encoders need dimensions that are multiples of 16. */
        fun floor16(v: Int): Int = if (v <= 0) 0 else (v / 16) * 16
    }
}
