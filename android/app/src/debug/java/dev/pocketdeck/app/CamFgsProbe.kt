package dev.pocketdeck.app

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureFailure
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.TotalCaptureResult
import android.media.Image
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.util.Log
import android.util.Range
import android.util.Size
import dev.pocketdeck.R
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * C0b probe, debug builds only: can the *app process* start a `camera`
 * foreground service and capture while the app is in the background and the
 * phone is locked? (C0 proved the shell UID cannot open a camera at all.)
 *
 * One run per start; exactly one `stage=... ok=... started_fg=... opened=...
 * frames=... error=...` line under [TAG], whether the refusal comes from
 * `startForeground`, from Camera2 or from the receiver. A 60 s watchdog logs
 * `error=watchdog` and stops the service instead of holding the boot.
 *
 * Device side (see tools/emulator/cam-fgs.sh):
 *   adb shell am start-foreground-service -n dev.pocketdeck/dev.pocketdeck.app.CamFgsProbe \
 *       --es stage bg-unlocked-a --ei seconds 5
 *   adb shell am broadcast -a dev.pocketdeck.DEBUG_CAM_FGS -p dev.pocketdeck \
 *       --es stage bg-unlocked-b --ei seconds 5
 *
 * The service is exported only because uid 2000 (adb, the same UID as the
 * Shizuku user service) is the "system component starts the service" case this
 * probe has to exercise; `android.permission.DUMP` keeps ordinary apps out
 * (docs/design/camera.md, C0b).
 */
class CamFgsProbe : Service() {

    private val running = AtomicBoolean(false)

    @Volatile
    private var current: Run? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val request = CamFgsRequest.parse(
            intent?.getStringExtra(EXTRA_STAGE),
            intent?.getIntExtra(EXTRA_SECONDS, CamFgsRequest.DEFAULT_SECONDS) ?: CamFgsRequest.DEFAULT_SECONDS,
            intent?.getBooleanExtra(EXTRA_FRAME, false) ?: false,
        )
        if (request == null) {
            enterForeground()
            emit(CamFgsResult("bad-request", false, false, false, 0, "bad_extras_or_stage"))
            stopSelf()
            return START_NOT_STICKY
        }

        // A late start from the previous stage must still satisfy the
        // startForegroundService contract, but must not disturb the live run.
        if (!running.compareAndSet(false, true)) {
            enterForeground()
            emit(CamFgsResult(request.stage, true, true, false, 0, "busy"))
            return START_NOT_STICKY
        }

        try {
            startForeground(NOTIFICATION_ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA)
        } catch (t: Throwable) {
            Log.i(TAG, "fgs stage=${request.stage} refused=${CamFgsResult.describe(t)}")
            emit(CamFgsResult(request.stage, false, false, false, 0, CamFgsResult.describe(t)))
            running.set(false)
            quietStop()
            return START_NOT_STICKY
        }
        Log.i(TAG, "fgs stage=${request.stage} type=camera started=true")

        val run = Run(request)
        run.startedFg = true
        current = run
        armWatchdog(run)
        startCapture(run)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        current?.let { finish(it, "service_destroyed") }
        super.onDestroy()
    }

    private fun enterForeground() {
        runCatching {
            startForeground(NOTIFICATION_ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA)
        }
    }

    private fun quietStop() {
        runCatching { stopForeground(STOP_FOREGROUND_REMOVE) }
        stopSelf()
    }

    // ---------------------------------------------------------------- capture

    private fun startCapture(run: Run) {
        val manager = getSystemService(CameraManager::class.java)
        if (manager == null) {
            finish(run, "no_camera_manager")
            return
        }
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            finish(run, "camera_permission_not_granted")
            return
        }
        val id = try {
            pickCamera(manager)
        } catch (t: Throwable) {
            finish(run, CamFgsResult.describe(t))
            return
        }
        if (id == null) {
            finish(run, "no_camera")
            return
        }
        val size = try {
            chooseSize(manager, id)
        } catch (_: Throwable) {
            Size(640, 480)
        }
        val reader = try {
            ImageReader.newInstance(size.width, size.height, ImageFormat.YUV_420_888, 2)
        } catch (t: Throwable) {
            finish(run, "image_reader:${CamFgsResult.describe(t)}")
            return
        }
        run.reader = reader
        reader.setOnImageAvailableListener({ r -> onImage(run, r) }, run.handler)
        run.size = size

        Log.i(TAG, "open stage=${run.request.stage} camera=$id size=${size.width}x${size.height}")
        val callback = object : CameraDevice.StateCallback() {
            override fun onOpened(cam: CameraDevice) = onCameraOpened(run, cam)

            override fun onDisconnected(cam: CameraDevice) {
                runCatching { cam.close() }
                Log.i(TAG, "evict stage=${run.request.stage} reason=onDisconnected frames=${run.frames.get()}")
                finish(run, "onDisconnected")
            }

            override fun onError(cam: CameraDevice, error: Int) {
                runCatching { cam.close() }
                val name = errorName(error)
                Log.i(
                    TAG,
                    "evict stage=${run.request.stage} reason=onError_${error}_$name frames=${run.frames.get()}",
                )
                finish(run, "onError_${error}_$name")
            }
        }
        try {
            manager.openCamera(id, callback, run.handler)
        } catch (t: Throwable) {
            finish(run, "open:${CamFgsResult.describe(t)}")
        }
    }

    private fun onCameraOpened(run: Run, cam: CameraDevice) {
        if (run.finished.get()) {
            runCatching { cam.close() }
            return
        }
        run.opened = true
        run.device = cam
        val reader = run.reader
        if (reader == null) {
            finish(run, "no_image_reader")
            return
        }
        try {
            cam.createCaptureSession(listOf(reader.surface), sessionCallback(run), run.handler)
        } catch (t: Throwable) {
            finish(run, "createCaptureSession:${CamFgsResult.describe(t)}")
        }
    }

    private fun sessionCallback(run: Run) = object : CameraCaptureSession.StateCallback() {
        override fun onConfigured(created: CameraCaptureSession) {
            if (run.finished.get()) {
                runCatching { created.close() }
                return
            }
            run.session = created
            try {
                val device = run.device ?: error("no_device")
                val reader = run.reader ?: error("no_image_reader")
                val request = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                request.addTarget(reader.surface)
                request.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                runCatching { request.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, fpsRange(device.id)) }
                created.setRepeatingRequest(
                    request.build(),
                    object : CameraCaptureSession.CaptureCallback() {
                        override fun onCaptureCompleted(
                            session: CameraCaptureSession,
                            request: CaptureRequest,
                            result: TotalCaptureResult,
                        ) = Unit

                        override fun onCaptureFailed(
                            session: CameraCaptureSession,
                            request: CaptureRequest,
                            failure: CaptureFailure,
                        ) {
                            run.captureFailures.incrementAndGet()
                        }
                    },
                    run.handler,
                )
                val size = run.size
                Log.i(TAG, "capture=configured stage=${run.request.stage} size=${size.width}x${size.height}")
                run.handler.postDelayed({ finish(run, null) }, run.request.seconds * 1000L)
            } catch (t: Throwable) {
                finish(run, "repeating:${CamFgsResult.describe(t)}")
            }
        }

        override fun onConfigureFailed(created: CameraCaptureSession) {
            finish(run, "onConfigureFailed")
        }
    }

    private fun onImage(run: Run, reader: ImageReader) {
        val image = try {
            reader.acquireLatestImage()
        } catch (_: Throwable) {
            null
        } ?: return
        try {
            val count = run.frames.incrementAndGet()
            if (count == 1) {
                Log.i(TAG, "capture=first-frame stage=${run.request.stage}")
                if (run.request.saveFrame && !run.frameSaved) {
                    run.frameSaved = true
                    val file = File(cacheDir, FRAME_NAME)
                    val bytes = saveJpeg(image, file)
                    Log.i(TAG, "frame stage=${run.request.stage} name=${file.name} bytes=${bytes ?: -1}")
                }
            }
        } finally {
            runCatching { image.close() }
        }
    }

    /** The first frame only, as evidence: a synthetic test pattern, never a person. */
    private fun saveJpeg(image: Image, file: File): Long? = try {
        val width = image.width
        val height = image.height
        val y = image.planes[0]
        val u = image.planes[1]
        val v = image.planes[2]
        val nv21 = ByteArray(width * height * 3 / 2)
        var at = 0
        val yBuffer = y.buffer
        for (row in 0 until height) {
            val base = row * y.rowStride
            for (col in 0 until width) {
                nv21[at++] = yBuffer.get(base + col * y.pixelStride)
            }
        }
        val uBuffer = u.buffer
        val vBuffer = v.buffer
        for (row in 0 until height / 2) {
            val uBase = row * u.rowStride
            val vBase = row * v.rowStride
            for (col in 0 until width / 2) {
                nv21[at++] = vBuffer.get(vBase + col * v.pixelStride)
                nv21[at++] = uBuffer.get(uBase + col * u.pixelStride)
            }
        }
        val jpeg = YuvImage(nv21, ImageFormat.NV21, width, height, null)
        FileOutputStream(file).use { out -> jpeg.compressToJpeg(Rect(0, 0, width, height), 40, out) }
        file.length()
    } catch (t: Throwable) {
        Log.i(TAG, "frame error=${CamFgsResult.describe(t)}")
        null
    }

    private fun pickCamera(manager: CameraManager): String? {
        val ids = manager.cameraIdList
        return ids.firstOrNull {
            manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) ==
                CameraCharacteristics.LENS_FACING_BACK
        } ?: ids.firstOrNull()
    }

    /** 720p when the camera offers it (C1's target), else the closest smaller size. */
    private fun chooseSize(manager: CameraManager, id: String): Size {
        val map = manager.getCameraCharacteristics(id)
            .get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val sizes = map?.getOutputSizes(ImageFormat.YUV_420_888)?.toList().orEmpty()
        return sizes.firstOrNull { it.width == 1280 && it.height == 720 }
            ?: sizes.filter { it.width <= 1280 && it.height <= 720 }
                .maxByOrNull { it.width.toLong() * it.height }
            ?: sizes.minByOrNull { it.width.toLong() * it.height }
            ?: Size(640, 480)
    }

    private fun fpsRange(id: String): Range<Int> {
        val ranges = getSystemService(CameraManager::class.java)
            ?.getCameraCharacteristics(id)
            ?.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
        return ranges?.firstOrNull { it.upper >= 30 && it.lower <= 30 } ?: Range(30, 30)
    }

    private fun errorName(error: Int): String = when (error) {
        CameraDevice.StateCallback.ERROR_CAMERA_IN_USE -> "in_use"
        CameraDevice.StateCallback.ERROR_MAX_CAMERAS_IN_USE -> "max_cameras_in_use"
        CameraDevice.StateCallback.ERROR_CAMERA_DISABLED -> "disabled"
        CameraDevice.StateCallback.ERROR_CAMERA_DEVICE -> "device"
        CameraDevice.StateCallback.ERROR_CAMERA_SERVICE -> "service"
        else -> "unknown"
    }

    // ------------------------------------------------------------------ result

    private fun emit(result: CamFgsResult) {
        Log.i(TAG, result.line())
    }

    /** One line per run; safe from the camera thread, the watchdog and onDestroy. */
    private fun finish(run: Run, error: String?) {
        if (!run.finished.compareAndSet(false, true)) return
        if (error != null) run.error = error
        run.handler.removeCallbacksAndMessages(null)
        runCatching { run.session?.stopRepeating() }
        runCatching { run.session?.close() }
        runCatching { run.reader?.close() }
        runCatching { run.device?.close() }
        run.session = null
        run.reader = null
        run.device = null
        val failures = run.captureFailures.get()
        if (failures > 0 && run.error == null) run.error = "onCaptureFailed_x$failures"
        val frames = run.frames.get()
        emit(
            CamFgsResult(
                stage = run.request.stage,
                ok = run.startedFg && run.opened && frames > 0,
                startedFg = run.startedFg,
                opened = run.opened,
                frames = frames,
                error = run.error ?: "none",
            ),
        )
        runCatching { run.thread.quitSafely() }
        if (current === run) current = null
        running.set(false)
        quietStop()
    }

    private fun armWatchdog(run: Run) {
        Thread({
            try {
                Thread.sleep(WATCHDOG_MS)
            } catch (_: InterruptedException) {
                return@Thread
            }
            if (run.finished.get()) return@Thread
            Log.i(TAG, "watchdog stage=${run.request.stage} ms=$WATCHDOG_MS")
            finish(run, "watchdog_${WATCHDOG_MS}ms")
        }, "cam-fgs-watchdog").apply {
            isDaemon = true
            start()
        }
    }

    // ------------------------------------------------------------ notification

    private fun notification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Camera probe", NotificationManager.IMPORTANCE_LOW),
        )
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_deck)
            .setContentTitle("Camera probe")
            .setContentText("Debug camera check")
            .setOngoing(true)
            .build()
    }

    /** One stage's live state; all counters are read from two threads. */
    private class Run(val request: CamFgsRequest) {
        val thread = HandlerThread("cam-fgs-${request.stage}").apply { start() }
        val handler = Handler(thread.looper)
        val frames = AtomicInteger()
        val captureFailures = AtomicInteger()
        val finished = AtomicBoolean(false)
        @Volatile var startedFg = false
        @Volatile var opened = false
        @Volatile var error: String? = null
        @Volatile var frameSaved = false
        var size: Size = Size(0, 0)
        var device: CameraDevice? = null
        var session: CameraCaptureSession? = null
        var reader: ImageReader? = null
    }

    companion object {
        /** Fixed logcat tag; tools/emulator/cam-fgs.sh greps it. */
        const val TAG = "PdCamFgs"
        const val ACTION_TRIGGER = "dev.pocketdeck.DEBUG_CAM_FGS"
        const val EXTRA_STAGE = "stage"
        const val EXTRA_SECONDS = "seconds"
        const val EXTRA_FRAME = "frame"

        private const val CHANNEL = "cam-fgs-probe"
        private const val NOTIFICATION_ID = 41
        private const val WATCHDOG_MS = 60_000L
        private const val FRAME_NAME = "cam-fgs-frame.jpg"
    }
}

/**
 * The app starting its own camera service from the background, the way an
 * in-app trigger would: `am broadcast -p dev.pocketdeck` (DUMP-protected, so
 * only adb/shell can send it). A refusal never reaches the service, so the
 * receiver itself writes the stage's result line.
 */
class CamFgsTrigger : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != CamFgsProbe.ACTION_TRIGGER) return
        val request = CamFgsRequest.parse(
            intent.getStringExtra(CamFgsProbe.EXTRA_STAGE),
            intent.getIntExtra(CamFgsProbe.EXTRA_SECONDS, CamFgsRequest.DEFAULT_SECONDS),
            intent.getBooleanExtra(CamFgsProbe.EXTRA_FRAME, false),
        )
        if (request == null) {
            Log.i(
                CamFgsProbe.TAG,
                CamFgsResult("bad-request", false, false, false, 0, "bad_extras_or_stage").line(),
            )
            return
        }
        val service = Intent(context, CamFgsProbe::class.java)
            .putExtra(CamFgsProbe.EXTRA_STAGE, request.stage)
            .putExtra(CamFgsProbe.EXTRA_SECONDS, request.seconds)
            .putExtra(CamFgsProbe.EXTRA_FRAME, request.saveFrame)
        try {
            context.startForegroundService(service)
            Log.i(CamFgsProbe.TAG, "trigger stage=${request.stage} start=accepted")
        } catch (t: Throwable) {
            Log.i(CamFgsProbe.TAG, "trigger stage=${request.stage} start=refused")
            Log.i(
                CamFgsProbe.TAG,
                CamFgsResult(request.stage, false, false, false, 0, CamFgsResult.describe(t)).line(),
            )
        }
    }
}
