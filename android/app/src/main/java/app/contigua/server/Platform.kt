package app.contigua.server

import java.io.File

/**
 * Platform seams for the session core.
 *
 * Everything the protocol needs from the device sits behind these interfaces so
 * [Session] can be exercised on a plain JVM (see `src/test`). The Android
 * implementations live in the sibling files and are wired up by [DeckService].
 */

data class IntSize(val w: Int, val h: Int)

/**
 * @property multi whether a second instance can run in its own task (WIN-24,
 *   [MultiInstancePolicy]); the Mac's New Window items follow it.
 */
data class AppEntry(val pkg: String, val label: String, val activity: String, val multi: Boolean)

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
    /**
     * Display 0 shows a secure window or the keyguard bouncer, so the mirror is
     * blank; null while nothing has been read (no phone window is open).
     */
    val secure: Boolean? = null,
    /** STREAM_MUSIC's level and its maximum; both null on a phone that cannot read them. */
    val volume: Int? = null,
    val volumeMax: Int? = null,
)

/**
 * Display 0's secure-surface state (docs/PROTOCOL.md "Secure screens"). Read at
 * shell UID because only the window manager and keyguard know it. Polled at
 * most once a second, and only while a phone window stream is open.
 */
fun interface SecureProbe {
    /** True while a secure window or the bouncer covers display 0; null when unreadable. */
    fun read(): Boolean?
}

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
         * report UNKNOWN for the default display) follows display 0's own
         * interactive flag instead of guessing "off".
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

        /**
         * Display 0's state at the caller's UID; null when it cannot be read.
         * Never the global `PowerManager.isInteractive()`: an app window's
         * display group keeps the global wakefulness awake while display 0
         * dozes (WIN-74), so the fallback asks about display 0 by id.
         */
        fun read(ctx: android.content.Context?): ScreenState? {
            ctx ?: return null
            return runCatching {
                val pm = ctx.getSystemService(android.content.Context.POWER_SERVICE)
                    as? android.os.PowerManager ?: return@runCatching null
                val state = DisplayProbe.state(android.view.Display.DEFAULT_DISPLAY)
                if (state == android.view.Display.STATE_UNKNOWN) {
                    of(state, panelInteractive(pm))
                } else {
                    of(state, interactive = false)
                }
            }.getOrNull()
        }

        /** Hidden `PowerManager.isInteractive(int displayId)` (Android 14+); false without it. */
        private val isInteractiveById: java.lang.reflect.Method? = runCatching {
            android.os.PowerManager::class.java.getMethod("isInteractive", Int::class.javaPrimitiveType)
        }.getOrNull()

        private fun panelInteractive(pm: android.os.PowerManager): Boolean =
            runCatching { isInteractiveById?.invoke(pm, android.view.Display.DEFAULT_DISPLAY) as? Boolean }
                .getOrNull() ?: false
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

/**
 * STREAM_MUSIC's level (docs/PROTOCOL.md "Volume"). `read` returns the level
 * and the stream's maximum; null when this build cannot read them. `listen`
 * carries a person's change; null when no listener is reachable and the caller
 * must poll.
 */
interface VolumeSettings {
    fun read(): Pair<Int, Int>?
    fun listen(onChange: () -> Unit): AutoCloseable?
    /** Writes STREAM_MUSIC at [level] with no UI flag; false when the phone refused. */
    fun set(level: Int): Boolean
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
    /** [content] is where the picture sits in the w×h frame (a mirror's black edges are outside it). */
    fun onConfig(stream: Int, codec: Int, w: Int, h: Int, csd: ByteArray, content: IntRect)
    fun onFrame(stream: Int, ptsUs: Long, key: Boolean, data: ByteArray)
    /** `window.still`: the stream is live, but its encoder produced nothing. */
    fun onStill(stream: Int)
    /** WIN-66: one state of a stream's no-frame episode (recorded, then its end). */
    fun onNoFrame(stream: Int, episode: NoFrameEpisode) {}

    /** WIN-66: whether a task was launched on the stream's display, for the record. */
    fun noFrameTask(stream: Int): NoFrameTask = NoFrameTask.Unknown
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

/**
 * The top task on a display: the app (phone-mode titles, the audio follow) and
 * the task's own label (an app stream's `window.title`, WIN-28).
 *
 * @property pkg the task's own app — its root's package, not the package of an
 *   activity another app put on top of the task.
 * @property taskId the phone's task id, 0 when unknown.
 * @property taskLabel `taskDescription.label` — the window's own title (a
 *   browser page's, a conversation's); null when the phone described none and
 *   [label] is the fallback.
 */
data class TopTask(val pkg: String, val label: String, val taskId: Int = 0, val taskLabel: String? = null)

fun interface WindowObserver {
    fun topTask(displayId: Int): TopTask?
}

/**
 * Reports whether a display still hosts at least one task, used to detect that
 * an app left its display. `null` means the query failed (leave the stream as
 * it was rather than treating it as an exit).
 */
fun interface TaskPresence {
    fun hasTask(displayId: Int): Boolean?

    /**
     * The display's top task id, for `window.opened` (WIN-32); null when this
     * phone cannot read it or the display has no task yet.
     */
    fun taskId(displayId: Int): Int? = null

    /**
     * A task's own description (`RecentTaskInfo.taskDescription.label`) by id,
     * for `window.task` (WIN-44); null when the phone describes none.
     */
    fun taskLabel(taskId: Int): String? = null
}

/** One task-stack callback the phone's system reports (WIN-44, WIN-48, WIN-49). */
sealed class TaskStackEvent {
    /** A task was created. [pkg] may be null on the first callback for an id. */
    data class Created(val taskId: Int, val pkg: String?) : TaskStackEvent()

    /** An existing task changed display; the id is unchanged. */
    data class DisplayChanged(val taskId: Int, val displayId: Int) : TaskStackEvent()

    /** A task was removed. */
    data class Removed(val taskId: Int) : TaskStackEvent()
}

/**
 * The system's task-stack listener at shell UID (`ITaskStackListener`).
 * `start` answers false when the phone refuses registration: there is then no
 * report path, and nothing else changes (WIN-44).
 */
interface TaskStackEvents {
    fun start(onEvent: (TaskStackEvent) -> Unit): Boolean
    fun stop()
}

/** Owns the VirtualDisplay + encoder for one window stream. */
interface DisplayLayer {
    /** The codecs the Mac's `hello` said it decodes (HEVC is the opt-in arm). */
    fun setMacCodecs(codecs: Set<VideoCodec>) {}

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

    /**
     * A `window.resize`: [ResizeOutcome.SAME] when the display already shows
     * that size and density, [ResizeOutcome.DENSITY] when only the density
     * changed (no encoder rebuild), else the encoder's answer. The session
     * sends it back as `window.resize.ack`; an unknown stream answers KEPT.
     */
    fun resize(stream: Int, w: Int, h: Int, dpi: Int): ResizeOutcome
    fun pause(stream: Int)
    fun resume(stream: Int)
    fun requestKeyframe(stream: Int)

    /**
     * The send queue dropped this stream's deltas and waits for its next key
     * (the drop rule): an IDR that went out before the drop cannot start the
     * decoder, so the duplicate-IDR gate must not answer this request with it.
     */
    fun requestKeyframeAfterDrop(stream: Int) = requestKeyframe(stream)
    fun close(stream: Int)

    /**
     * Runtime quality for one stream: a bitrate target in bps and/or an fps cap.
     * Both are optional and best-effort; implementations may ignore them.
     */
    fun setQuality(stream: Int, bitrate: Int?, maxFps: Int?) {}

    /**
     * The session dropped delta frames for this stream because its backlog
     * exceeded the protocol's budget; the encoder should lower its bitrate.
     * [measuredBps] is the link's recent goodput and [encodedBps] the encoder's
     * own measured output; the cap on the codec's key reads both.
     */
    fun onBackpressure(stream: Int, measuredBps: Int? = null, encodedBps: Int? = null) {}

    /**
     * PATH-47: the writer's queue delay (p95 over its last window) and the
     * link's newest goodput. The stream lowers its bitrate before the 250 ms
     * budget has to drop anything; [linkBps] is null while the writer cannot
     * measure it.
     */
    fun onQueueDelay(stream: Int, delayP95Us: Long, delayP50Us: Long, linkBps: Int?) {}

    /**
     * Q1 (`overflow=suspend`): stop (true) or resume (false) taking frames at
     * the encoder's input, so the source skips frames instead of the queue.
     */
    fun setEncoderSuspend(stream: Int, suspended: Boolean) {}

    /**
     * `stream.stats {on}`: while on, the encoders keep the per-frame delay and
     * QP rings the phone reports every 2 s. Counters themselves are always
     * plain increments; this only turns on the expensive per-frame reads.
     */
    fun setStatsEnabled(on: Boolean) {}

    /**
     * One stream's counters since the last call, or null for an unknown stream.
     * Used only while stats are on; `reset` starts the next 2 s window.
     */
    fun statsSnapshot(stream: Int, nowUs: Long, reset: Boolean = true): EncoderStats? = null

    /**
     * One closed-token lifetime line (`stream N totals: …`) for a stream that is
     * about to close, or null when the platform keeps no such counters.
     */
    fun totalsLine(stream: Int): String? = null
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
    /**
     * @param newInstance `window.open`'s `newInstance`: another task of the same
     *   activity ([LaunchFlags]).
     * @return true when the launch was accepted; false means report `launch_failed`.
     */
    fun launch(displayId: Int, pkg: String, activity: String?, newInstance: Boolean): Boolean

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

    /**
     * The set of displays whose app streams are open, covered windows included.
     * A pause is not a close: the episode keeps every open stream's display
     * while one is live, and ends when the last one closes or all are covered.
     */
    fun setActiveStreams(
        displayIds: List<Int>,
        allPaused: Boolean = false,
        mirroring: Boolean = false,
        phoneWindowOpen: Boolean = false,
    )

    fun onSessionEnded()

    /**
     * `phone.wake`: wake display 0 once. Waking only — the keyguard stays and
     * nothing is unlocked. [WakeResult.FAILED] when the platform refused both
     * the display call and the key-event fallback.
     */
    fun wakeScreen(): WakeResult = WakeResult.FAILED

    /**
     * `phone.panel` (docs/PROTOCOL.md "Phone screen"): hold the mirrored panel
     * off while the mirror keeps rendering, or give it back. [ignorePower] is
     * the Mac's "Keep the phone screen off until I turn it on from the Mac"
     * setting, carried with every off request. False when this build cannot
     * control the panel at all.
     */
    fun setMirrorPanelOff(off: Boolean, ignorePower: Boolean = false): Boolean = false

    /** True while the phone itself holds the panel off: the only source of `state.panel`. */
    val panelHeldOff: Boolean get() = false

    /**
     * The hold changed `state.panel` on its own (the person's power press, a
     * paused window, the session ending): the session sends a fresh state.
     * Runs on the power thread.
     */
    var onPanelChanged: ((off: Boolean) -> Unit)?
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

    /**
     * WIN-46: moves a task the app started itself onto [displayId] with
     * `startActivityFromRecents` and a launch display. Unlike [move] it also
     * accepts a task that is a child of a split root. false means the system
     * refused, the task is gone, or it did not land on the display.
     */
    fun adopt(taskId: Int, displayId: Int): Boolean = false

    /**
     * WIN-31: the task ids the phone remembers in Recents, whether or not the
     * task still runs. A closed window's task keeps its card here after its
     * display is gone, so "is it gone" has to ask both lists. null when the
     * phone cannot read Recents.
     */
    fun recentTaskIds(): Set<Int>? = null

    /**
     * Ends one task (WIN-31: a window's task that outlived its display). Never
     * the app: its other tasks keep running. false when the phone cannot say.
     */
    fun remove(taskId: Int): Boolean = false
}

/**
 * A clipboard text as the sync sees it. [sensitive] is the system's own
 * "do not put this anywhere" mark: a password manager's item carries it, and
 * the phone never sends one (SHARE share Q3).
 */
data class ClipText(val text: String, val sensitive: Boolean = false)

/**
 * The device clipboard as plain text. [listen] callbacks arrive on a platform
 * thread and fire for every primary-clip change, including our own [setText].
 * The callback carries the signal only: the session decides whether the gate
 * allows a read (ISS-27).
 */
interface ClipboardPort {
    /** The primary clip's text, or null when it holds no text. */
    fun getText(): ClipText?
    fun setText(text: String)

    /**
     * Starts delivering change signals to [onChange] and returns this
     * listener's handle. The port has one live listener: this replaces any
     * earlier one, whose handle becomes stale.
     */
    fun listen(onChange: () -> Unit): ClipRegistration

    /**
     * Stops delivery for [registration], but only while it is the live one. A
     * stale handle (replaced, already stopped or null) is a no-op, so an old
     * session's teardown can never silence the next session's sync (ISS-13).
     */
    fun stop(registration: ClipRegistration?)
}

/**
 * One clipboard listener registration (ISS-13): the handle [ClipboardPort.listen]
 * hands back. Only the owner of the live registration may stop it.
 */
class ClipRegistration internal constructor(internal val onChange: () -> Unit) {
    /** The platform listener this registration installed, if any. */
    internal var listener: Any? = null
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
}

/**
 * The app-owned clipboard write (SHARE-2/16): the shell has the bytes, the app
 * has the provider and the clipboard. [done] receives the app's answer once,
 * or false when there is no app or it does not answer in time.
 */
fun interface ClipImageHost {
    fun offer(id: Int, mime: String, bytes: ByteArray, done: (Boolean) -> Unit)
}

/** Events pushed to the app process (pairing prompt, session state). */
interface DeckCallback {
    fun onPairingRequest(requestId: String, macName: String, code: String)
    /** The request ended without an answer (Mac cancelled, connection lost, timed out). */
    fun onPairingEnded(requestId: String)
    fun onPaired(clientId: String, name: String, keyHex: String)
    fun onSessionChanged(connected: Boolean, clientId: String?, macName: String?, windows: Int)

    /**
     * R-8/D-4: a Mac's `hello` named another protocol version; `macV` is that
     * version (null when absent). The app shows the sentence naming which side
     * to update until a session succeeds.
     */
    fun onVersionRefused(macV: Int?) {}

    /** WIN-66: one episode for the app's ring; `json` is ids, counts and closed tokens only. */
    fun onNoFrameEpisode(episode: Int, json: String) {}
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
