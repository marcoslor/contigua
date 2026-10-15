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

/** What a window shows: an app on its own virtual display, or a mirror of the phone's screen. */
sealed class WindowContent {
    data class App(val pkg: String, val activity: String?) : WindowContent()
    object Phone : WindowContent()
    /** A link opened with `ACTION_VIEW`; Android picks the app (docs/design/links.md). */
    data class Link(val url: String) : WindowContent()
}

/** Receives encoded video from a display stream. */
interface VideoSink {
    fun onConfig(stream: Int, codec: Int, w: Int, h: Int, csd: ByteArray)
    fun onFrame(stream: Int, ptsUs: Long, key: Boolean, data: ByteArray)
}

/** Receives encoded device-wide audio (one mixer tap, stream 0). */
interface AudioSink {
    fun onAudioConfig(codec: Int, sampleRate: Int, channels: Int, frameMs: Int, setup: ByteArray)
    fun onAudioFrame(ptsUs: Long, data: ByteArray)
}

/** Owns the REMOTE_SUBMIX capture + encoder for the session's audio stream. */
interface AudioCaptureLayer {
    val isRunning: Boolean
    fun start(sink: AudioSink, preferredCodecs: List<Int> = listOf(2, 3))
    fun stop()
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

    /**
     * Mirror the phone's own screen (display 0) into a stream that fits inside
     * w×h at display 0's aspect, following its rotation. Returns the stream's
     * size; input for it goes to display 0, mapped over [size].
     */
    fun openMirror(stream: Int, w: Int, h: Int, sink: VideoSink): IntSize

    /** Size normalized input maps over: the video size, or display 0's real size for a mirror. */
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

    /** Starts `ACTION_VIEW` for an already validated URL; false means `launch_failed`. */
    fun view(displayId: Int, url: String): Boolean
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

/** One task the system currently has, as far as "Continue on Mac" needs. */
data class SystemTask(
    val taskId: Int,
    /** Package of the task's top activity ("" when nothing resolves). */
    val pkg: String,
    /** The top activity's class, when known (the fallback relaunch tracer). */
    val activity: String?,
    val displayId: Int,
    /** The TaskInfo home flag: the launcher, which "Continue on Mac" skips. */
    val isHome: Boolean,
    /** A task drawn by SystemUI (recents UI, and the keyguard's surface). */
    val isSystemUi: Boolean,
)

/**
 * The system's task list and task-to-display moves, at shell UID. Null from
 * [tasks] means the phone cannot report its foreground app.
 */
interface TaskMove {
    /** The system's tasks, most recently active first; null = not available. */
    fun tasks(): List<SystemTask>?

    /** Moves an existing task to a display. false means the system refused: relaunch instead. */
    fun move(taskId: Int, displayId: Int): Boolean
}

/**
 * The device clipboard as plain text. [listen] callbacks arrive on a platform
 * thread and fire for every primary-clip change, including our own [setText].
 */
interface ClipboardPort {
    /** Text of the primary clip, or null when it holds no text. */
    fun getText(): String?
    fun setText(text: String)

    /** Starts delivering text changes to [onChange]; replaces any earlier listener. */
    fun listen(onChange: (String) -> Unit)

    /** Stops delivery. Safe to call more than once and without [listen]. */
    fun stop()
}

/** Events pushed to the app process (pairing prompt, session state). */
interface DeckCallback {
    fun onPairingRequest(requestId: String, macName: String, code: String)
    /** The request ended without an answer (Mac cancelled, connection lost, timed out). */
    fun onPairingEnded(requestId: String)
    fun onPaired(clientId: String, name: String, keyHex: String)
    fun onSessionChanged(connected: Boolean, macName: String?, windows: Int)
}

/** The app a successful install left on the phone. */
data class InstalledApp(val pkg: String, val label: String, val version: String)

/** One `pm install-write` in progress: bytes go to pm's stdin. */
interface PartWriter {
    fun write(bytes: ByteArray, offset: Int, length: Int)

    /** Closes stdin and returns pm's output. */
    fun finish(): String

    fun abort()
}

/**
 * `pm` install sessions at shell UID (docs/design/apk.md). Outputs are pm's own
 * text so [ApkPolicy] can parse success and failure codes in one place.
 */
interface PackageShell {
    /** `pm install-create -S <totalBytes>`; returns pm's output. */
    fun create(totalBytes: Long): String
    fun write(session: Int, name: String, size: Long): PartWriter
    fun commit(session: Int): String
    fun abandon(session: Int)

    /** The package updated most recently at or after [sinceMs] (wall clock), if any. */
    fun newestSince(sinceMs: Long): InstalledApp?
}
