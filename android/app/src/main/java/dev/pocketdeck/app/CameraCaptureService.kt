package dev.pocketdeck.app

import android.Manifest
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.graphics.drawable.Icon
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.util.Log
import android.util.Range
import android.util.Size
import android.view.Surface
import androidx.core.content.ContextCompat
import dev.pocketdeck.R
import dev.pocketdeck.camera.AuSink
import dev.pocketdeck.camera.CameraAu
import dev.pocketdeck.camera.CameraControl
import dev.pocketdeck.camera.CameraEngine
import dev.pocketdeck.camera.CameraInfo
import dev.pocketdeck.camera.CameraMessages
import dev.pocketdeck.camera.CameraSpec
import dev.pocketdeck.camera.CameraState
import dev.pocketdeck.camera.CodecSetupException
import dev.pocketdeck.camera.EncoderSetup
import dev.pocketdeck.camera.SurfaceCodec
import java.io.OutputStream
import kotlin.math.abs

/**
 * The hand-over of one capture's pipe: the shell creates it, hands the write end
 * over `IDeckCallback.onCameraStart`, and starts this service with the matching
 * stream id. Both run in this process; the registry is the join point.
 */
internal object CameraSinks {

    private val lock = Object()
    private val pending = HashMap<Int, ParcelFileDescriptor>()

    fun offer(stream: Int, fd: ParcelFileDescriptor) {
        synchronized(lock) {
            pending.remove(stream)?.let { runCatching { it.close() } }
            pending[stream] = fd
            lock.notifyAll()
        }
    }

    /** The pipe for [stream], waiting up to [timeoutMs] for the binder callback. */
    fun take(stream: Int, timeoutMs: Long): ParcelFileDescriptor? {
        val deadline = System.currentTimeMillis() + timeoutMs
        synchronized(lock) {
            while (true) {
                pending.remove(stream)?.let { return it }
                val left = deadline - System.currentTimeMillis()
                if (left <= 0) return null
                runCatching { lock.wait(left) }
            }
        }
    }

    fun drop(stream: Int) {
        synchronized(lock) { pending.remove(stream) }?.let { runCatching { it.close() } }
    }
}

/** The app's gate and camera list, pushed to the shell over `cameraState`. */
internal object CameraGate {

    fun allowed(ctx: Context): Boolean =
        Prefs.isCameraAllowed(ctx) &&
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    /** Best capture size per camera inside the protocol's caps (1920×1080). */
    fun cams(ctx: Context): List<CameraInfo> {
        val manager = ctx.getSystemService(CameraManager::class.java) ?: return emptyList()
        if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.CAMERA) !=
            PackageManager.PERMISSION_GRANTED) {
            return emptyList()
        }
        val out = ArrayList<CameraInfo>()
        for (id in runCatching { manager.cameraIdList }.getOrDefault(emptyArray())) {
            val map = runCatching {
                manager.getCameraCharacteristics(id)
                    .get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            }.getOrNull() ?: continue
            val sizes = runCatching { map.getOutputSizes(MediaCodec::class.java)?.toList() }
                .getOrNull()
                ?: runCatching { map.getOutputSizes(ImageFormat.YUV_420_888)?.toList() }
                    .getOrNull().orEmpty()
            val best = sizes
                .filter { it.width <= CameraSpec.MAX_W && it.height <= CameraSpec.MAX_H && it.width > 0 }
                .maxByOrNull { it.width.toLong() * it.height } ?: continue
            val facing = runCatching {
                manager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING)
            }.getOrNull()
            out.add(
                CameraInfo(
                    id = id,
                    facing = if (facing == CameraCharacteristics.LENS_FACING_FRONT) "front" else "back",
                    w = best.width,
                    h = best.height,
                ),
            )
        }
        return out
    }

    /** Tells the shell the gate and the list; silently a no-op when unbound. */
    fun push(ctx: Context) {
        val allowed = allowed(ctx)
        val cams = if (allowed) cams(ctx) else emptyList()
        val svc = ShizukuClient.current() ?: return
        runCatching { svc.cameraState(CameraMessages.gate(allowed, cams)) }
            .onFailure { Log.i(TAG, "camera gate push failed") }
    }

    private const val TAG = "PocketDeckApp"
}

/**
 * One camera capture, in the app process (docs/design/camera.md, C1). Started by
 * the shell service as uid 2000 (`am start-foreground-service`, the C0b stage-a
 * mechanism) because Android refuses a `camera` FGS started from the background.
 *
 * The service calls `startForeground` first — the 5 s contract — then picks up
 * the pipe the shell handed over and runs [CameraControl]. It lives exactly as
 * long as the capture: every terminal state (stop, pipe EOF, eviction, refusal)
 * reports itself and stops the service.
 */
class CameraCaptureService : Service() {

    @Volatile
    private var control: CameraControl? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            control?.stop("notification")
            if (control == null) stopSelf()
            return START_NOT_STICKY
        }
        val spec = CameraSpec.fromJson(intent?.getStringExtra(EXTRA_PARAMS))
        val entered = try {
            startForeground(NOTIFICATION_ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA)
            true
        } catch (t: Throwable) {
            Log.i(TAG, "fgs refused: ${describe(t)}")
            send(spec?.stream ?: 0, CameraState.ERROR, describe(t))
            false
        }
        if (!entered) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (spec == null) {
            Log.i(TAG, "bad start: no params")
            send(0, CameraState.ERROR, "bad_params")
            stopSelf()
            return START_NOT_STICKY
        }
        if (!CameraGate.allowed(this)) {
            Log.i(TAG, "refused stream=${spec.stream}: consent off")
            send(spec.stream, CameraState.OFF, null)
            if (control?.isActive != true) stopSelf()
            return START_NOT_STICKY
        }
        if (control?.isActive == true) {
            // The live capture keeps the service; only the request is refused.
            send(spec.stream, CameraState.BUSY, null)
            return START_NOT_STICKY
        }
        CameraGate.push(this)
        Thread({ run(spec) }, "pocketdeck-camera-start").apply {
            isDaemon = true
            start()
        }
        return START_NOT_STICKY
    }

    private fun run(spec: CameraSpec) {
        val pfd = CameraSinks.take(spec.stream, PIPE_WAIT_MS)
        if (pfd == null) {
            Log.i(TAG, "stream=${spec.stream}: no pipe from the shell")
            report(spec.stream, CameraState.ERROR, "no_pipe")
            stopSelf()
            return
        }
        val sink = CameraAuSink(ParcelFileDescriptor.AutoCloseOutputStream(pfd))
        val engine = Camera2Engine(
            ctx = this,
            keyguardShowing = {
                runCatching { getSystemService(KeyguardManager::class.java)?.isKeyguardLocked == true }
                    .getOrDefault(false)
            },
            log = { Log.i(TAG, it) },
        )
        val capture = CameraControl(engine, sink, ::report, { Log.i(TAG, it) })
        control = capture
        if (!capture.start(spec, allowed = true)) {
            runCatching { engine.stop() }
            runCatching { sink.close() }
            stopSelf()
        }
    }

    /** Every state change goes to the shell (the session relays `cam.state`). */
    private fun report(stream: Int, state: CameraState, reason: String?) {
        send(stream, state, reason)
        if (state == CameraState.STREAMING) return
        // Terminal: the capture is over, so is the service.
        stopSelf()
    }

    /** Sends a state without deciding the service's life (a refusal keeps it). */
    private fun send(stream: Int, state: CameraState, reason: String?) {
        Log.i(TAG, "state stream=$stream state=${state.wire}" + (reason?.let { " reason=$it" } ?: ""))
        ShizukuClient.current()?.let { svc ->
            runCatching { svc.cameraState(CameraMessages.state(stream, state, reason)) }
        }
    }

    override fun onDestroy() {
        control?.stop("service")
        control = null
        super.onDestroy()
    }

    private fun notification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Camera sharing", NotificationManager.IMPORTANCE_LOW),
        )
        val stop = PendingIntent.getService(
            this,
            2,
            Intent(this, CameraCaptureService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_deck)
            .setContentTitle(getString(R.string.camera_notification_title))
            .setContentText(getString(R.string.camera_notification_text))
            .setOngoing(true)
            .addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(this, R.drawable.ic_deck),
                    getString(R.string.camera_notification_stop),
                    stop,
                ).build(),
            )
            .build()
    }

    companion object {
        const val TAG = "PdCamera"

        /** The shell's extras: the `cam.start` request as JSON (CameraSpec). */
        const val EXTRA_PARAMS = "params"
        const val ACTION_STOP = "dev.pocketdeck.CAMERA_STOP"

        private const val CHANNEL = "camera-sharing"
        private const val NOTIFICATION_ID = 43
        private const val PIPE_WAIT_MS = 3_000L

        /**
         * Parses `onCameraStart`'s params and parks its pipe for the service the
         * shell starts next. Called from the deck service's AIDL callback.
         */
        fun offerPipe(paramsJson: String?, fd: ParcelFileDescriptor?) {
            val spec = CameraSpec.fromJson(paramsJson)
            val pfd = fd
            if (spec == null || pfd == null) {
                Log.i(TAG, "camera start without params or pipe")
                runCatching { pfd?.close() }
                return
            }
            CameraSinks.offer(spec.stream, pfd)
        }
    }
}

private fun describe(t: Throwable): String = "${t.javaClass.simpleName}:${t.message}"

/** The pipe writer: exactly the app → shell records of [CameraAu]. */
internal class CameraAuSink(private val out: OutputStream) : AuSink {

    private val lock = Any()
    private var closed = false

    override fun writeAu(ptsUs: Long, key: Boolean, data: ByteArray) {
        synchronized(lock) {
            if (closed) throw java.io.IOException("sink closed")
            CameraAu.write(out, ptsUs, key, data)
        }
    }

    override fun close() {
        synchronized(lock) {
            if (closed) return
            closed = true
            runCatching { out.close() }
        }
    }
}

/**
 * Camera2 → MediaCodec H.264 with the `WindowStream` encoder settings (surface
 * colour format, VBR, no B-frames, a 2 s I-frame interval), one drain thread.
 * `onDisconnected` is an eviction: the person's own camera app wins and nothing
 * is retried.
 */
internal class Camera2Engine(
    private val ctx: Context,
    private val keyguardShowing: () -> Boolean,
    private val log: (String) -> Unit,
) : CameraEngine {

    private val thread = HandlerThread("pocketdeck-camera").apply { start() }
    private val handler = Handler(thread.looper)

    @Volatile private var stopped = false
    @Volatile private var drainThread: Thread? = null

    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var codec: MediaCodec? = null
    private var surface: Surface? = null
    private var csd: ByteArray? = null
    private var csdSent = false

    override fun start(spec: CameraSpec, listener: CameraEngine.Listener) {
        stopped = false
        handler.post { open(spec, listener) }
    }

    private fun open(spec: CameraSpec, listener: CameraEngine.Listener) {
        if (stopped) return
        val manager = ctx.getSystemService(CameraManager::class.java)
        if (manager == null) {
            listener.onState(CameraState.ERROR, "no_camera_manager")
            return
        }
        val id = pickCamera(manager, spec)
        if (id == null) {
            listener.onState(CameraState.ERROR, "no_camera")
            return
        }
        val size = try {
            chooseSize(manager, id, spec)
        } catch (t: Throwable) {
            listener.onState(CameraState.ERROR, t.javaClass.simpleName)
            return
        }
        val started = try {
            EncoderSetup.start(AvcEncoder(size, spec.fps))
        } catch (e: CodecSetupException) {
            // The diagnostic line the next boot (or a phone's bug report) needs:
            // which call refused, the platform error code and diagnostic string.
            log("encoder failed: step=${e.step} ${codecDiagnostics(e.refused)}")
            listener.onState(CameraState.ERROR, "encoder_${e.refused.javaClass.simpleName}")
            return
        }
        val encoder = started.codec as MediaCodec
        codec = encoder
        val input = started.surface as Surface
        surface = input
        drainThread = Thread({ drain(encoder, listener) }, "pocketdeck-camera-drain").apply {
            isDaemon = true
            start()
        }
        log("opening camera=$id ${size.width}x${size.height}@${spec.fps}")
        val callback = object : CameraDevice.StateCallback() {
            override fun onOpened(cam: CameraDevice) {
                if (stopped) {
                    runCatching { cam.close() }
                    return
                }
                device = cam
                try {
                    cam.createCaptureSession(listOf(input), sessionCallback(cam, listener, size, spec), handler)
                } catch (t: Throwable) {
                    listener.onState(CameraState.ERROR, "session_${t.javaClass.simpleName}")
                }
            }

            override fun onDisconnected(cam: CameraDevice) {
                runCatching { cam.close() }
                device = null
                if (stopped) return
                log("evicted (onDisconnected)")
                listener.onState(CameraState.EVICTED, "onDisconnected")
            }

            override fun onError(cam: CameraDevice, error: Int) {
                runCatching { cam.close() }
                device = null
                if (stopped) return
                log("camera error code=$error")
                listener.onState(mapError(error), "onError_$error")
            }
        }
        try {
            manager.openCamera(id, callback, handler)
        } catch (t: Throwable) {
            log("openCamera failed: ${t.javaClass.simpleName}")
            listener.onState(mapOpenFailure(t), t.javaClass.simpleName)
        }
    }

    private fun sessionCallback(
        cam: CameraDevice,
        listener: CameraEngine.Listener,
        size: Size,
        spec: CameraSpec,
    ) = object : CameraCaptureSession.StateCallback() {
        override fun onConfigured(created: CameraCaptureSession) {
            if (stopped) {
                runCatching { created.close() }
                return
            }
            session = created
            try {
                val request = cam.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                surface?.let { request.addTarget(it) }
                request.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                request.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, fpsRange(cam.id, spec.fps))
                created.setRepeatingRequest(request.build(), null, handler)
                log("capture configured ${size.width}x${size.height}")
                listener.onStarted(size.width, size.height)
            } catch (t: Throwable) {
                listener.onState(CameraState.ERROR, "repeating_${t.javaClass.simpleName}")
            }
        }

        override fun onConfigureFailed(created: CameraCaptureSession) {
            listener.onState(CameraState.ERROR, "onConfigureFailed")
        }
    }

    override fun stop() {
        if (stopped) return
        stopped = true
        handler.post { releaseAll() }
    }

    private fun releaseAll() {
        runCatching { session?.stopRepeating() }
        runCatching { session?.close() }
        session = null
        runCatching { device?.close() }
        device = null
        runCatching { codec?.stop() }
        runCatching { codec?.release() }
        codec = null
        runCatching { surface?.release() }
        surface = null
        val drain = drainThread
        drainThread = null
        if (drain != null && drain !== Thread.currentThread()) runCatching { drain.join(400) }
        thread.quitSafely()
    }

    // ------------------------------------------------------------- encoding

    private fun drain(encoder: MediaCodec, listener: CameraEngine.Listener) {
        val info = MediaCodec.BufferInfo()
        while (!stopped) {
            val index = try {
                encoder.dequeueOutputBuffer(info, 10_000)
            } catch (t: Throwable) {
                return
            }
            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                csd = readCsd(encoder.outputFormat)
                continue
            }
            if (index < 0) continue
            try {
                val buffer = encoder.getOutputBuffer(index)
                if (buffer == null || info.size <= 0 ||
                    info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                ) {
                    encoder.releaseOutputBuffer(index, false)
                    continue
                }
                var data = ByteArray(info.size)
                buffer.position(info.offset)
                buffer.get(data)
                encoder.releaseOutputBuffer(index, false)
                val key = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                if (key && !csdSent) {
                    val config = csd
                    if (config != null && config.isNotEmpty()) data = config + data
                    csdSent = true
                }
                listener.onFrame(info.presentationTimeUs, key, data)
            } catch (t: Throwable) {
                runCatching { encoder.releaseOutputBuffer(index, false) }
            }
            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
        }
    }

    private fun readCsd(format: MediaFormat): ByteArray? {
        val parts = ArrayList<ByteArray>(2)
        for (name in listOf("csd-0", "csd-1")) {
            val buf = runCatching { format.getByteBuffer(name) }.getOrNull() ?: continue
            val bytes = ByteArray(buf.remaining())
            buf.get(bytes)
            parts.add(bytes)
        }
        if (parts.isEmpty()) return null
        val out = java.io.ByteArrayOutputStream()
        for (p in parts) out.write(p)
        return out.toByteArray()
    }

    /** [SurfaceCodec] over MediaCodec: it carries the order, this carries the settings. */
    private inner class AvcEncoder(private val size: Size, private val fps: Int) : SurfaceCodec {

        override fun create(): Any = MediaCodec.createEncoderByType(MIME)

        override fun configure(codec: Any) =
            configure(codec as MediaCodec, size.width, size.height, fps)

        override fun createInputSurface(codec: Any): Any = (codec as MediaCodec).createInputSurface()

        override fun start(codec: Any) = (codec as MediaCodec).start()

        override fun release(codec: Any) {
            runCatching { (codec as MediaCodec).stop() }
            runCatching { (codec as MediaCodec).release() }
        }
    }

    /**
     * The platform's own words for a refused encoder call: error code, the
     * transient/recoverable flags and the diagnostic string. No frame content.
     */
    private fun codecDiagnostics(t: Throwable): String {
        val codec = t as? MediaCodec.CodecException
            ?: return "${t.javaClass.simpleName}:${t.message}"
        return "error=${codec.errorCode} transient=${codec.isTransient} " +
            "recoverable=${codec.isRecoverable} diagnostic=${codec.diagnosticInfo}"
    }

    private fun configure(encoder: MediaCodec, w: Int, h: Int, fps: Int) {
        val format = MediaFormat.createVideoFormat(MIME, w, h)
        format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
        format.setInteger(MediaFormat.KEY_BIT_RATE, bitrateFor(w, h, fps))
        format.setInteger(MediaFormat.KEY_FRAME_RATE, fps)
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, I_FRAME_INTERVAL_S)
        format.setInteger(MediaFormat.KEY_PRIORITY, 0) // realtime
        format.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
        format.setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
        runCatching { format.setInteger(MediaFormat.KEY_LATENCY, 1) }
        encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
    }

    /** ~0.12 bpp·fps, capped at 8 Mbps (WindowStream's rule). */
    private fun bitrateFor(w: Int, h: Int, fps: Int): Int {
        val bits = w.toLong() * h.toLong() * fps * 120 / 1000
        return bits.coerceIn(500_000L, 8_000_000L).toInt()
    }

    // ------------------------------------------------------------- selection

    private fun pickCamera(manager: CameraManager, spec: CameraSpec): String? {
        val ids = runCatching { manager.cameraIdList }.getOrDefault(emptyArray())
        spec.cameraId?.let { id -> if (ids.contains(id)) return id }
        val want = when (spec.facing) {
            "front" -> CameraCharacteristics.LENS_FACING_FRONT
            else -> CameraCharacteristics.LENS_FACING_BACK
        }
        return ids.firstOrNull {
            runCatching {
                manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING)
            }.getOrNull() == want
        } ?: ids.firstOrNull()
    }

    private fun chooseSize(manager: CameraManager, id: String, spec: CameraSpec): Size {
        val map = manager.getCameraCharacteristics(id)
            .get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val sizes = map?.getOutputSizes(MediaCodec::class.java)?.toList().orEmpty()
            .ifEmpty { map?.getOutputSizes(SurfaceTexture::class.java)?.toList().orEmpty() }
            .filter { it.width <= CameraSpec.MAX_W && it.height <= CameraSpec.MAX_H && it.width > 0 }
        if (sizes.isEmpty()) return Size(spec.w, spec.h)
        sizes.firstOrNull { it.width == spec.w && it.height == spec.h }?.let { return it }
        return sizes.minByOrNull { abs(it.width - spec.w) + abs(it.height - spec.h) }
            ?: Size(spec.w, spec.h)
    }

    private fun fpsRange(id: String, fps: Int): Range<Int> {
        val ranges = runCatching {
            ctx.getSystemService(CameraManager::class.java)
                ?.getCameraCharacteristics(id)
                ?.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
        }.getOrNull()
        return ranges?.firstOrNull { it.upper >= fps && it.lower <= fps } ?: Range(fps, fps)
    }

    /** `ERROR_CAMERA_DISABLED` is `locked` while the keyguard is up, else `disabled`. */
    private fun mapError(error: Int): CameraState = when (error) {
        CameraDevice.StateCallback.ERROR_CAMERA_IN_USE,
        CameraDevice.StateCallback.ERROR_MAX_CAMERAS_IN_USE,
        -> CameraState.BUSY
        CameraDevice.StateCallback.ERROR_CAMERA_DISABLED ->
            if (keyguardShowing()) CameraState.LOCKED else CameraState.DISABLED
        else -> CameraState.ERROR
    }

    private fun mapOpenFailure(t: Throwable): CameraState {
        val name = t.javaClass.simpleName
        val message = t.message.orEmpty()
        return when {
            message.contains("CAMERA_IN_USE", ignoreCase = true) ||
                message.contains("MAX_CAMERAS_IN_USE", ignoreCase = true) -> CameraState.BUSY
            message.contains("CAMERA_DISABLED", ignoreCase = true) ->
                if (keyguardShowing()) CameraState.LOCKED else CameraState.DISABLED
            else -> CameraState.ERROR
        }.also { log("open failed: $name") }
    }

    private companion object {
        const val MIME = "video/avc"
        const val I_FRAME_INTERVAL_S = 2
    }
}
