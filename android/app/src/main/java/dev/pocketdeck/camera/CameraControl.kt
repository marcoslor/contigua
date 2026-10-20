package dev.pocketdeck.camera

/** Where encoded access units go: the shell's pipe in production, a buffer in tests. */
interface AuSink {
    /** @throws java.io.IOException when the reader is gone (stop, session end). */
    fun writeAu(ptsUs: Long, key: Boolean, data: ByteArray)

    fun close()
}

/** The capture half: Camera2 + MediaCodec in production, a fake in the JVM tests. */
interface CameraEngine {
    fun start(spec: CameraSpec, listener: Listener)

    /** Stops and releases everything. Idempotent; may be called from any thread. */
    fun stop()

    interface Listener {
        /** The camera opened and the encoder is producing: `streaming` now. */
        fun onStarted(width: Int, height: Int)

        fun onFrame(ptsUs: Long, key: Boolean, data: ByteArray)

        /** A terminal engine state (`evicted`, `disabled`, `locked`, `busy`, `error`). */
        fun onState(state: CameraState, reason: String?)
    }
}

/**
 * One camera capture's state machine (docs/design/camera.md "C1 implementation
 * notes"): one at a time, no retries, and every way out (stop, pipe EOF,
 * eviction, platform refusal) ends in exactly one state report.
 *
 * Pure Kotlin: the JVM test drives it with a fake engine and a fake sink.
 */
class CameraControl(
    private val engine: CameraEngine,
    private val sink: AuSink,
    private val emit: (stream: Int, state: CameraState, reason: String?) -> Unit,
    private val log: (String) -> Unit = {},
) {

    private val lock = Any()

    /** The live request; null once the run ended. Written under [lock]. */
    private var spec: CameraSpec? = null

    /** The service's gate: setting on and CAMERA granted. */
    val stream: Int? get() = synchronized(lock) { spec?.stream }

    val isActive: Boolean get() = synchronized(lock) { spec != null }

    /**
     * Starts [request] unless the gate is closed (`off`) or a capture already
     * runs (`busy`). Returns false when refused; the state was emitted.
     */
    fun start(request: CameraSpec, allowed: Boolean): Boolean {
        synchronized(lock) {
            if (!allowed) {
                log("camera refused: consent off")
                emit(request.stream, CameraState.OFF, null)
                return false
            }
            if (spec != null) {
                log("camera refused: busy (stream ${spec?.stream})")
                emit(request.stream, CameraState.BUSY, null)
                return false
            }
            spec = request
        }
        log("camera start stream=${request.stream} camera=${request.cameraId ?: request.facing} " +
            "${request.w}x${request.h}@${request.fps}")
        engine.start(request, EngineListener(request.stream))
        return true
    }

    /** `cam.stop`, the notification's Stop, a session end or service teardown. */
    fun stop(reason: String? = null) = finish(CameraState.STOPPED, reason)

    /** The pipe's reader is gone: the next write failed or the shell closed it. */
    fun onSinkBroken() = finish(CameraState.STOPPED, "pipe")

    private fun finish(state: CameraState, reason: String?) {
        val stream: Int
        synchronized(lock) {
            val current = spec ?: return
            spec = null
            stream = current.stream
        }
        runCatching { engine.stop() }
            .onFailure { log("camera engine stop failed: ${it.javaClass.simpleName}") }
        runCatching { sink.close() }
        log("camera stop stream=$stream state=${state.wire}" + (reason?.let { " reason=$it" } ?: ""))
        emit(stream, state, reason)
    }

    private inner class EngineListener(private val stream: Int) : CameraEngine.Listener {

        override fun onStarted(width: Int, height: Int) {
            if (!isActive) return
            log("camera streaming stream=$stream ${width}x$height")
            emit(stream, CameraState.STREAMING, null)
        }

        override fun onFrame(ptsUs: Long, key: Boolean, data: ByteArray) {
            if (!isActive) return
            try {
                sink.writeAu(ptsUs, key, data)
            } catch (t: Throwable) {
                // The shell closed the pipe (cam.stop, session end, app exit):
                // there is nobody left to send to, so stop rather than buffer.
                log("camera pipe broken stream=$stream ${t.javaClass.simpleName}")
                finish(CameraState.STOPPED, "pipe")
            }
        }

        override fun onState(state: CameraState, reason: String?) {
            when (state) {
                // Terminal: the capture is over and is never retried.
                CameraState.EVICTED, CameraState.DISABLED, CameraState.LOCKED,
                CameraState.BUSY, CameraState.ERROR ->
                    finish(state, reason)
                else -> emit(stream, state, reason)
            }
        }
    }
}
