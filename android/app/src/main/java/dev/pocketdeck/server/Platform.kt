package dev.pocketdeck.server

import java.io.File

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

data class DeviceState(
    val locked: Boolean,
    val battery: Int,
    val charging: Boolean,
    val dnd: DndMode? = null,
    val ringer: RingerMode? = null,
    /** Display 0's power state; null when this build cannot read it. */
    val screen: ScreenState? = null,
)

/**
 * The phone's own screen (display 0), as `state.screen` names it
 * (docs/PROTOCOL.md "Phone screen"). Doze and doze-suspend are off: an
 * Always-On Display is not a live picture.
 */
enum class ScreenState(val wire: String) {
    ON("on"),
    OFF("off"),
    ;

    companion object {
        /**
         * Maps the platform's values. An unknown display state (some builds
         * report UNKNOWN for the default display) follows the interactive flag
         * instead of guessing "off".
         */
        fun of(displayState: Int, interactive: Boolean): ScreenState = when (displayState) {
            android.view.Display.STATE_ON -> ON
            android.view.Display.STATE_OFF,
            android.view.Display.STATE_DOZE,
            android.view.Display.STATE_DOZE_SUSPEND,
            android.view.Display.STATE_ON_SUSPEND,
            -> OFF
            else -> if (interactive) ON else OFF
        }

        /** Display 0's state at the caller's UID; null when it cannot be read. */
        fun read(ctx: android.content.Context?): ScreenState? {
            ctx ?: return null
            return runCatching {
                val pm = ctx.getSystemService(android.content.Context.POWER_SERVICE)
                    as? android.os.PowerManager ?: return@runCatching null
                of(DisplayProbe.state(android.view.Display.DEFAULT_DISPLAY), pm.isInteractive)
            }.getOrNull()
        }
    }
}

/** The outcome of `phone.wake`, logged by name (docs/PROTOCOL.md "Phone screen"). */
enum class WakeResult(val wire: String) {
    OK("ok"),
    FALLBACK("fallback"),
    FAILED("failed"),
}

/**
 * The phone's Do Not Disturb mode, named as the wire names it
 * (docs/PROTOCOL.md "Focus and Do Not Disturb"). [zen] is the value of
 * `Settings.Global.zen_mode`.
 */
enum class DndMode(val wire: String, val zen: Int) {
    OFF("off", 0),
    PRIORITY("priority", 1),
    NONE("none", 2),
    ALARMS("alarms", 3),
    ;

    val isOn: Boolean get() = this != OFF

    companion object {
        fun fromWire(value: String?): DndMode? = entries.firstOrNull { it.wire == value }

        /** An unknown zen value is read as off: nothing is changed by guessing. */
        fun fromZen(value: Int): DndMode = entries.firstOrNull { it.zen == value } ?: OFF
    }
}

/** Reads the phone's zen mode; null when this build cannot read it. */
interface ZenSettings {
    fun read(): DndMode?

    /**
     * Delivers mode changes made by the person (and our own). Null when the
     * shell UID cannot register an observer on this build; the caller polls.
     */
    fun listen(onChange: (DndMode?) -> Unit): AutoCloseable?
}

/** Runs `cmd notification set_dnd <mode>` at shell UID; false when the phone refused. */
fun interface ZenSetter {
    fun set(mode: DndMode): Boolean
}

/**
 * The phone's ringer mode, named as `phone.ringer` and `state.ringer` do
 * (docs/design/controls.md). [android] is `Settings.Global.mode_ringer`.
 */
enum class RingerMode(val wire: String, val android: Int) {
    SILENT("silent", 0),
    VIBRATE("vibrate", 1),
    NORMAL("normal", 2),
    ;

    companion object {
        fun fromWire(value: String?): RingerMode? = entries.firstOrNull { it.wire == value }

        /** An unknown value is unreadable, never guessed. */
        fun fromAndroid(value: Int): RingerMode? = entries.firstOrNull { it.android == value }
    }
}

/** Reads the phone's ringer mode; null when this build cannot read it. */
interface RingerSettings {
    fun read(): RingerMode?
    fun listen(onChange: (RingerMode?) -> Unit): AutoCloseable?
}

/** Runs `cmd audio set-ringer-mode <MODE>` at shell UID; false when the phone refused. */
fun interface RingerSetter {
    fun set(mode: RingerMode): Boolean
}

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

/** One entry per currently open window, for the AudioFollow decision (AudioFollow.kt). */
interface AudioCaptureLayer {
    val isRunning: Boolean

    /**
     * Starts capture for the session. [windows] reads the open windows at any
     * time; the capture follows their UID set while it runs (window open/close).
     */
    fun start(
        sink: AudioSink,
        preferredCodecs: List<Int> = listOf(2, 3),
        windows: () -> List<CaptureWindow> = { emptyList() },
    )

    /** The open windows changed; the running (or planned) capture must follow. */
    fun onWindowsChanged(owner: AudioSink?) {}

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

    /**
     * The flat icon as base64 PNG. `px` is the optional 108 dp size the Mac asked
     * for (`apps.icon`): null keeps the historical 96 px flat icon, otherwise the
     * flat icon is rendered at px·2/3.
     */
    fun iconPng(pkg: String, px: Int? = null): String?

    /**
     * The adaptive icon's layers as base64 PNGs (`fg`/`bg`/`mono` fields of the
     * `icon` message), each the whole 108 dp layer at `px` pixels (default 216,
     * clamped to 216…1296); null when the icon is not adaptive.
     */
    fun iconLayers(pkg: String, px: Int? = null): IconLayers? = null
}

/** @property fg foreground layer; @property bg background layer; `mono` only on API 33+. */
data class IconLayers(val fg: String, val bg: String, val mono: String?)

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
    /** A mouse hovering with no button down: enter, move or exit at (nx, ny). */
    fun hover(displayId: Int, action: Int, nx: Float, ny: Float, size: IntSize)
    fun key(displayId: Int, action: Int, keycode: Int, metaState: Int, downTime: Long, eventTime: Long)
    fun text(displayId: Int, s: String)
}

/** Battery/keep-awake policy. It never keeps the panel on beyond the person's own timeout. */
interface Power {
    /** Input is flowing; poke the display's own group (throttled internally). */
    fun onInput(displayId: Int)

    /** The set of displays whose streams are currently unpaused. */
    fun setActiveStreams(displayIds: List<Int>)

    fun onSessionEnded()

    /**
     * `phone.wake`: wake display 0 once. Waking only — the keyguard stays and
     * nothing is unlocked. [WakeResult.FAILED] when the platform refused both
     * the display call and the key-event fallback.
     */
    fun wakeScreen(): WakeResult = WakeResult.FAILED
}

/** One paired Mac in v2: the pin is the Mac cert's point fingerprint (§3/§6);
 * there is no shared secret any more. */
data class PairedClient(val clientId: String, val name: String, val macFpHex: String)

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

/** An image the clipboard holds: primary bytes (JPEG/PNG) of the first image item. */
data class ClipImage(val bytes: ByteArray, val mime: String)

/** Clipboard images, the extension [ClipboardPort] needs beyond text. */
interface ClipboardImagePort {
    /**
     * The image currently on the clipboard, or null. Reading may fail for another
     * app's content URI; a null is simply "nothing synced", never an error.
     */
    fun readImage(): ClipImage?

    /**
     * Puts the already-written image [file] on the clipboard; the platform decides
     * how another app can reach it (a FileProvider URI is the intent).
     */
    fun writeImage(file: File, mime: String, label: String)
}

/** Events pushed to the app process (pairing prompt, session state). */
interface DeckCallback {
    fun onPairingRequest(requestId: String, macName: String, code: String)
    /** The request ended without an answer (Mac cancelled, connection lost, timed out). */
    fun onPairingEnded(requestId: String)
    fun onPaired(clientId: String, name: String, keyHex: String)
    fun onSessionChanged(connected: Boolean, clientId: String?, macName: String?, windows: Int)
}

/**
 * `phone.ring` / `phone.ring.stop` (docs/PROTOCOL.md "Ring"). The shell service
 * forwards them to the app process: only an app may show an activity over the
 * lock screen and play the alarm.
 */
interface Ringer {
    fun start(seconds: Int)
    fun stop()
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
