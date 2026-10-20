package dev.pocketdeck.server

import android.os.ParcelFileDescriptor
import dev.pocketdeck.camera.CameraAuReader
import dev.pocketdeck.camera.CameraInfo
import dev.pocketdeck.camera.CameraRelay
import dev.pocketdeck.camera.CameraSpec
import java.io.BufferedInputStream
import java.util.concurrent.ConcurrentHashMap

/** Why a `cam.start` did not start a capture (the session turns it into a state). */
enum class CameraStart { STARTED, BUSY, OFF, ERROR }

/** The session's view of the camera side; the JVM tests hand in a fake. */
interface CameraPort {
    fun attach(session: Session)

    fun detach(session: Session)

    fun allowed(): Boolean

    fun list(): List<CameraInfo>

    fun start(spec: CameraSpec): CameraStart

    fun stop(stream: Int)

    /** The app's `IDeckService.cameraState` push (gate, list or a capture state). */
    fun onAppState(json: String)
}

/**
 * The shell side of C1 (docs/design/camera.md "C1 implementation notes"): one
 * capture at a time, a reliable pipe per capture, and the state relay.
 *
 * The pipe is the whole data path: this class never sees pixels, only the app →
 * shell access-unit records, which the session wraps as VIDEO_FRAMEs. The pipe's
 * read end is also the stop signal: closing it makes the app's next write fail.
 */
internal class CameraHub(
    private val log: (String) -> Unit,
    /** `{read, write}` from `ParcelFileDescriptor.createReliablePipe()`. */
    private val newPipe: () -> Array<ParcelFileDescriptor>,
    /** `IDeckCallback.onCameraStart(params, writeEnd)`; false when unbound. */
    private val handOff: (String, ParcelFileDescriptor) -> Boolean,
    /** Starts the app's CameraCaptureService as uid 2000 (`am ...`). */
    private val startApp: (String) -> Boolean,
) : CameraPort {

    @Volatile
    private var session: Session? = null

    @Volatile
    private var allowedFlag = false

    @Volatile
    private var cams: List<CameraInfo> = emptyList()

    private val lock = Any()
    private var capture: Capture? = null

    /** Streams whose `stopped` the session already sent itself (`cam.stop`). */
    private val quietStopped = ConcurrentHashMap.newKeySet<Int>()

    private class Capture(val stream: Int, val read: ParcelFileDescriptor) {
        @Volatile
        var closed = false

        @Volatile
        var terminal = false

        var thread: Thread? = null
    }

    override fun attach(session: Session) {
        this.session = session
    }

    override fun detach(session: Session) {
        if (this.session === session) this.session = null
        stopAll("session")
    }

    override fun allowed(): Boolean = allowedFlag

    override fun list(): List<CameraInfo> = if (allowedFlag) cams else emptyList()

    override fun start(spec: CameraSpec): CameraStart {
        if (!allowedFlag) {
            log("cam.start stream=${spec.stream}: consent off")
            return CameraStart.OFF
        }
        synchronized(lock) {
            if (capture != null) {
                log("cam.start stream=${spec.stream}: busy (stream ${capture?.stream})")
                return CameraStart.BUSY
            }
            val pipe = try {
                newPipe()
            } catch (t: Throwable) {
                log("cam.start: pipe failed (${t.javaClass.simpleName})")
                return CameraStart.ERROR
            }
            val params = spec.toJson()
            // The pipe goes first: the app parks it by stream id, then the shell
            // starts the service and the service picks it up.
            if (!handOff(params, pipe[1])) {
                closeQuietly(pipe[0])
                closeQuietly(pipe[1])
                log("cam.start: no app callback")
                return CameraStart.ERROR
            }
            val started = Capture(spec.stream, pipe[0])
            capture = started
            if (!startApp(params)) {
                log("cam.start stream=${spec.stream}: the app service did not start")
                finish(started, "start_failed")
                return CameraStart.ERROR
            }
            log("cam.start stream=${spec.stream} ${spec.w}x${spec.h}@${spec.fps}")
            started.thread = Thread({ readLoop(started) }, "pocketdeck-camera-${spec.stream}").apply {
                isDaemon = true
                start()
            }
            return CameraStart.STARTED
        }
    }

    override fun stop(stream: Int) {
        val current = synchronized(lock) { capture } ?: return
        if (current.stream != stream) return
        quietStopped.add(stream)
        finish(current, "requested")
    }

    private fun stopAll(why: String) {
        val current = synchronized(lock) { capture } ?: return
        finish(current, why)
    }

    /** A terminal app state or the pipe ending: release and forget the capture. */
    private fun finish(capture: Capture, why: String) {
        synchronized(lock) {
            if (this.capture !== capture) return
            this.capture = null
        }
        capture.closed = true
        closeQuietly(capture.read)
        if (capture.thread !== Thread.currentThread()) {
            runCatching { capture.thread?.join(400) }
        }
        if (why != "requested") log("camera stream=${capture.stream} ended: $why")
    }

    override fun onAppState(json: String) {
        val update = CameraRelay.parse(json) ?: return
        if (update.hasGate) {
            allowedFlag = update.allowed == true
            cams = update.cams.orEmpty()
            log("camera gate: allowed=$allowedFlag cams=${cams.size}")
        }
        if (!update.hasState) return
        val stream = update.stream ?: return
        val state = update.state ?: return
        if (state == "stopped" && quietStopped.remove(stream)) return
        log("camera state stream=$stream state=$state" + (update.reason?.let { " reason=$it" } ?: ""))
        session?.onCameraState(stream, state, update.reason)
        if (state != "streaming") {
            val current = synchronized(lock) { capture } ?: return
            if (current.stream != stream) return
            current.terminal = true
            finish(current, state)
        }
    }

    private fun readLoop(capture: Capture) {
        var frames = 0
        var keys = 0
        var bytes = 0L
        try {
            ParcelFileDescriptor.AutoCloseInputStream(capture.read).use { raw ->
                val reader = CameraAuReader(BufferedInputStream(raw, 64 * 1024))
                while (!capture.closed) {
                    val au = reader.next() ?: break
                    frames++
                    bytes += au.data.size
                    if (au.key) keys++
                    session?.onCameraFrame(capture.stream, au.ptsUs, au.key, au.data)
                }
            }
        } catch (t: Throwable) {
            if (!capture.closed) log("camera pipe broke: ${t.javaClass.simpleName}")
        }
        log("camera stream=${capture.stream} frames=$frames keys=$keys bytes=$bytes")
        // EOF with no state from the app (it died, or closed its end): the Mac
        // gets `stopped` once, and nothing is retried.
        if (!capture.closed && !capture.terminal) {
            finish(capture, "eof")
            if (quietStopped.remove(capture.stream)) return
            session?.onCameraState(capture.stream, "stopped", "eof")
        }
    }

    private fun closeQuietly(fd: ParcelFileDescriptor?) {
        if (fd == null) return
        runCatching { fd.close() }
    }
}
