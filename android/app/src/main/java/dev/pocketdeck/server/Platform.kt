package dev.pocketdeck.server

/**
 * Platform seams for the session core.
 *
 * Everything the protocol needs from the device sits behind these interfaces so
 * [Session] can be exercised on a plain JVM (see `src/test`). The Android
 * implementations live in the sibling files and are wired up by [DeckService].
 */

data class IntSize(val w: Int, val h: Int)

data class AppEntry(val pkg: String, val label: String, val activity: String)

data class DeviceInfo(
    val id: String,
    val name: String,
    val model: String,
    val sdk: Int,
    val screenW: Int,
    val screenH: Int,
    val dpi: Int,
    val locked: Boolean,
)

data class DeviceState(val locked: Boolean, val battery: Int, val charging: Boolean)

/** What a window shows: an app on the virtual display, or our phone-mode launcher. */
sealed class WindowContent {
    data class App(val pkg: String, val activity: String?) : WindowContent()
    object Phone : WindowContent()
}

/** Receives encoded video from a display stream. */
interface VideoSink {
    fun onConfig(stream: Int, codec: Int, w: Int, h: Int, csd: ByteArray)
    fun onFrame(stream: Int, ptsUs: Long, key: Boolean, data: ByteArray)
}

/** Reports the top app on a display, for phone-mode `window.title` updates. */
data class TopApp(val pkg: String, val label: String)

fun interface WindowObserver {
    fun topApp(displayId: Int): TopApp?
}

/**
 * Reports whether a display still hosts at least one task, used to detect that
 * an app left its display. `null` means the query failed (leave the stream as
 * it was rather than treating it as an exit).
 */
fun interface TaskPresence {
    fun hasTask(displayId: Int): Boolean?
}

/** Owns the VirtualDisplay + encoder for one window stream. */
interface DisplayLayer {
    /** Create the display + encoder; returns the display id. */
    fun open(stream: Int, w: Int, h: Int, dpi: Int, sink: VideoSink): Int

    /** Current video size of the stream (used to map normalized input). */
    fun size(stream: Int): IntSize

    fun resize(stream: Int, w: Int, h: Int, dpi: Int)
    fun pause(stream: Int)
    fun resume(stream: Int)
    fun requestKeyframe(stream: Int)
    fun close(stream: Int)

    /**
     * Runtime quality for one stream: a bitrate target in bps and/or an fps cap.
     * Both are optional and best-effort; implementations may ignore them.
     */
    fun setQuality(stream: Int, bitrate: Int?, maxFps: Int?) {}

    /**
     * The session dropped delta frames for this stream because its backlog
     * exceeded the protocol's budget; the encoder should lower its bitrate.
     */
    fun onBackpressure(stream: Int) {}
}

interface AppCatalog {
    fun list(): List<AppEntry>
    fun iconPng(pkg: String): String?
}

interface Launcher {
    /** @return true when the launch was accepted; false means report `launch_failed`. */
    fun launch(displayId: Int, pkg: String, activity: String?): Boolean
}

/**
 * Injects input on a display. Times are computed by the session (monotonic,
 * strictly increasing, per-gesture downTime) so this stays a thin IPC call.
 */
interface Injector {
    fun touch(displayId: Int, action: Int, pointerId: Int, nx: Float, ny: Float, size: IntSize, downTime: Long, eventTime: Long)
    fun scroll(displayId: Int, nx: Float, ny: Float, hscroll: Float, vscroll: Float, size: IntSize)
    fun key(displayId: Int, action: Int, keycode: Int, metaState: Int, downTime: Long, eventTime: Long)
    fun text(displayId: Int, s: String)
}

/** Battery/keep-awake policy. Never touches the physical panel. */
interface Power {
    /** Input is flowing; poke the display's own group (throttled internally). */
    fun onInput(displayId: Int)

    /** The set of displays whose streams are currently unpaused. */
    fun setActiveStreams(displayIds: List<Int>)

    fun onSessionEnded()
}

data class PairedClient(val clientId: String, val name: String, val keyHex: String)

/** Paired-client storage; the app process owns the durable copy. */
interface PairingStore {
    fun snapshot(): List<PairedClient>
    fun add(client: PairedClient)
}

/** Device identity + live state. */
interface DeviceSource {
    fun info(): DeviceInfo
    fun state(): DeviceState

    /**
     * Event-driven state updates for the session: registers the platform's
     * listeners and calls [onChange] once with the current state, then only on
     * change. Returns a handle the session closes on teardown, or null when the
     * platform has no push source (the protocol's single post-welcome `state`
     * still goes out).
     */
    fun subscribeState(onChange: (DeviceState) -> Unit): AutoCloseable?
}

/** Events pushed to the app process (pairing prompt, session state). */
interface DeckCallback {
    fun onPairingRequest(requestId: String, macName: String, code: String)
    fun onPaired(clientId: String, name: String, keyHex: String)
    fun onSessionChanged(connected: Boolean, macName: String?, windows: Int)
}
