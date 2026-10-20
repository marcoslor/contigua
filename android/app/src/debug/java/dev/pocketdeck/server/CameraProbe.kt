package dev.pocketdeck.server

import android.app.KeyguardManager
import android.content.AttributionSource
import android.content.Context
import android.content.ContextWrapper
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureFailure
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.TotalCaptureResult
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Range
import android.view.Surface
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Camera spike probe (debug builds only, v0.2 #7): can the shell UID open the
 * phone's camera, and does it keep feeding frames with the panel off and the
 * keyguard up?
 *
 * Each stage is its own `app_process` run and prints exactly one
 * `cam: result stage=<name> ok=<bool> ...` line; a stage that cannot answer
 * exits non-zero. A 60 s watchdog ends a hung stage, and every HandlerThread is
 * quit in `finally` (an earlier spike lost a boot to a leaked handler).
 *
 * Device side:
 *   CLASSPATH=$(pm path dev.pocketdeck | cut -d: -f2) app_process /system/bin \
 *       dev.pocketdeck.server.CameraProbe <list|open|locked|feed|evict> \
 *       [--seconds N] [--camera ID] [--ready PATH]
 *
 * No frames are stored: counts, sizes and error codes only.
 */
internal object CameraProbe {

    private const val STAGE_TIMEOUT_MS = 60_000L
    private const val IMAGE_WIDTH = 1280
    private const val IMAGE_HEIGHT = 720
    private const val IMAGE_FPS = 30
    private const val I_FRAME_INTERVAL_S = 1
    private const val BITRATE = 4_000_000
    private const val READY_MARKER = "/data/local/tmp/pd-cam-ready"

    @JvmStatic
    fun main(args: Array<String>) {
        val stage = ProbeStage.parse(args)
        if (stage == null) {
            emit(ProbeResult("args", false, listOf("error" to "unknown arguments ${args.joinToString(" ")}")))
            exitProcess(2)
        }
        armWatchdog(stage.name)
        var code = 1
        try {
            // ActivityThread's constructor makes a Handler, so the bare
            // app_process main thread needs a Looper before any context exists.
            runCatching { Looper.prepareMainLooper() }
            val result = runStage(stage)
            emit(result)
            code = if (result.ok) 0 else 1
        } catch (t: Throwable) {
            emit(
                ProbeResult(
                    stage.name,
                    false,
                    listOf("error" to t.javaClass.simpleName, "message" to (t.message ?: "-")),
                ),
            )
        }
        System.out.flush()
        exitProcess(code)
    }

    /** One line and a hard halt: a stage past 60 s is not allowed to hold the boot. */
    private fun armWatchdog(stage: String) {
        Thread({
            try {
                Thread.sleep(STAGE_TIMEOUT_MS)
            } catch (_: InterruptedException) {
                return@Thread
            }
            emit(ProbeResult(stage, false, listOf("error" to "timeout", "timeoutMs" to STAGE_TIMEOUT_MS.toString())))
            System.out.flush()
            Runtime.getRuntime().halt(3)
        }, "cam-probe-timeout").apply {
            isDaemon = true
            start()
        }
    }

    private fun emit(result: ProbeResult) {
        println(result.line())
        System.out.flush()
    }

    private fun exitProcess(code: Int): Nothing {
        System.out.flush()
        System.err.flush()
        Runtime.getRuntime().halt(code)
        error("halted with $code")
    }

    private fun runStage(stage: ProbeStage): ProbeResult {
        val probe = shellCamera()
        val manager = probe.manager
            ?: return ProbeResult(stage.name, false, probe.facts + listOf("error" to (probe.error ?: "no manager")))
        return when (stage.name) {
            "list" -> stageList(manager, stage, probe.facts)
            "open" -> stageOpen(manager, probe.shell!!, stage, probe.facts)
            "locked" -> stageCapture(manager, probe.shell!!, stage, probe.facts, locked = true)
            "feed" -> stageCapture(manager, probe.shell!!, stage, probe.facts, locked = false)
            "evict" -> stageEvict(manager, probe.shell!!, stage, probe.facts)
            else -> ProbeResult(stage.name, false, probe.facts + listOf("error" to "unknown_stage"))
        }
    }

    // ------------------------------------------------------------------ context

    private class ShellCamera(
        val manager: CameraManager?,
        val shell: Context?,
        val facts: List<Pair<String, String>>,
        val error: String? = null,
    )

    /**
     * The framework Context from a bare `app_process` plus a `CameraManager`
     * that names uid 2000's package. `getSystemService` cannot be used:
     * ContextWrapper delegates to the base ContextImpl, which hands the service
     * its own package name ("android"), and the camera service then refuses the
     * call because uid 2000 does not own that package. So the base's package
     * fields are rewritten too, not only the wrapper's.
     */
    private fun shellCamera(): ShellCamera {
        val base = systemContext()
            ?: return ShellCamera(null, null, listOf("uid" to uid().toString()), "no_context")
        val shell = ShellContext(base)
        val baseFields = (base as? ContextWrapper)?.baseContext ?: base
        val attribution = AttributionSource.Builder(android.os.Process.myUid())
            .setPackageName("com.android.shell")
            .build()
        val failed = ReflectionFields.write(
            baseFields,
            mapOf(
                "mPackageName" to "com.android.shell",
                "mOpPackageName" to "com.android.shell",
                "mAttributionSource" to attribution,
            ),
        )
        val adopted = listOf("mPackageName", "mOpPackageName", "mAttributionSource")
            .filter { it !in failed }
            .joinToString(",")
        val facts = mutableListOf(
            "uid" to uid().toString(),
            "pid" to android.os.Process.myPid().toString(),
            "pkg" to shell.packageName,
            "op" to shell.opPackageName,
            "attribution" to "${shell.attributionSource.packageName}/${shell.attributionSource.uid}",
            "basePkg" to runCatching { baseFields.packageName }.getOrDefault("-"),
            "adopted" to adopted.ifEmpty { "none" },
            "notAdopted" to failed.joinToString(",").ifEmpty { "none" },
        )
        val manager = runCatching {
            CameraManager::class.java.getConstructor(Context::class.java).newInstance(shell) as CameraManager
        }.onFailure { facts += "managerError" to chain(it) }.getOrNull()
            ?: runCatching { shell.getSystemService(Context.CAMERA_SERVICE) as CameraManager }
                .onFailure { facts += "serviceError" to chain(it) }.getOrNull()
        return ShellCamera(manager, shell, facts, if (manager == null) "no_camera_manager" else null)
    }

    private fun uid(): Int = android.os.Process.myUid()

    /**
     * A framework Context from a bare `app_process`: [android.app.ActivityThread.systemMain]
     * attaches it to the system the way system_server does. Hidden API, which
     * the shell UID (2000) is not restricted from.
     */
    private fun systemContext(): Context? {
        val at = runCatching { Class.forName("android.app.ActivityThread") }.getOrNull() ?: return null
        runCatching {
            val thread = at.getDeclaredMethod("systemMain").invoke(null)
            at.getMethod("getSystemContext").invoke(thread) as Context
        }.onSuccess { return it }
        val bare = runCatching {
            at.getDeclaredConstructor().apply { isAccessible = true }.newInstance()
        }.getOrNull() ?: return null
        runCatching { at.getMethod("getSystemContext").invoke(bare) as Context }.onSuccess { return it }
        return runCatching {
            Class.forName("android.app.ContextImpl")
                .getDeclaredMethod("createSystemContext", at)
                .apply { isAccessible = true }
                .invoke(null, bare) as Context
        }.getOrNull()
    }

    private fun chain(t: Throwable): String =
        generateSequence(t) { it.cause }.take(6)
            .joinToString("<-") { "${it.javaClass.simpleName}:${it.message}" }

    // -------------------------------------------------------------------- P1

    private fun stageList(manager: CameraManager, stage: ProbeStage, base: List<Pair<String, String>>): ProbeResult {
        val ids = try {
            manager.cameraIdList.toList()
        } catch (t: Throwable) {
            return ProbeResult(
                stage.name,
                false,
                base + listOf("error" to t.javaClass.simpleName, "message" to (t.message ?: "-")),
            )
        }
        val fields = base.toMutableList()
        fields += "cams" to ids.size.toString()
        fields += "ids" to ids.joinToString(",")
        for (id in ids) {
            val c = runCatching { manager.getCameraCharacteristics(id) }.getOrNull()
            if (c == null) {
                fields += "camera_$id" to "characteristics_failed"
                continue
            }
            val facing = when (c.get(CameraCharacteristics.LENS_FACING)) {
                CameraCharacteristics.LENS_FACING_BACK -> "back"
                CameraCharacteristics.LENS_FACING_FRONT -> "front"
                CameraCharacteristics.LENS_FACING_EXTERNAL -> "external"
                else -> "unknown"
            }
            val level = when (c.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)) {
                CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY -> "legacy"
                CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED -> "limited"
                CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_FULL -> "full"
                CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_3 -> "level3"
                CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_EXTERNAL -> "external"
                else -> "unknown"
            }
            val sizes = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                ?.getOutputSizes(SurfaceTexture::class.java)
                ?.sortedByDescending { it.width.toLong() * it.height }
            val has720 = sizes?.any { it.width == IMAGE_WIDTH && it.height == IMAGE_HEIGHT } ?: false
            val biggest = sizes?.take(3)?.joinToString("+") { "${it.width}x${it.height}" } ?: "-"
            val ranges = c.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                ?.joinToString(",") { "${it.lower}-${it.upper}" } ?: "-"
            fields += "camera_$id" to "$facing/$level/sizes=${sizes?.size ?: 0}/biggest=$biggest/720p=$has720/fps=$ranges"
        }
        return ProbeResult(stage.name, true, fields)
    }

    private fun stageOpen(
        manager: CameraManager,
        shell: Context,
        stage: ProbeStage,
        base: List<Pair<String, String>>,
    ): ProbeResult {
        val id = pickCamera(manager, stage)
            ?: return ProbeResult(stage.name, false, base + listOf("error" to "no_camera"))
        val thread = HandlerThread("cam-probe-open").apply { start() }
        val capture = Capture(manager, id, thread, shell)
        try {
            capture.startEncoder()
            capture.openCamera()
            val opened = capture.awaitOpened(5_000)
            val configured = capture.awaitConfigured(5_000)
            val ok = opened && configured && capture.openError == null && !capture.disconnected
            return ProbeResult(
                stage.name,
                ok,
                base + listOf(
                    "camera" to id,
                    "opened" to opened.toString(),
                    "session" to if (configured) "configured" else "not_configured",
                    "error" to (capture.openError ?: capture.sessionError ?: capture.deviceError ?: "none"),
                ),
            )
        } finally {
            capture.close()
            quit(thread)
        }
    }

    private fun pickCamera(manager: CameraManager, stage: ProbeStage): String? {
        stage.camera?.let { return it }
        return runCatching { manager.cameraIdList.firstOrNull() }.getOrNull()
    }

    // --------------------------------------------------------------- P2/P3/P4

    /** `locked` (P2) and `feed` (P3) share the capture core; only the reported facts differ. */
    private fun stageCapture(
        manager: CameraManager,
        shell: Context,
        stage: ProbeStage,
        base: List<Pair<String, String>>,
        locked: Boolean,
    ): ProbeResult {
        val id = pickCamera(manager, stage) ?: return ProbeResult(stage.name, false, base + listOf("error" to "no_camera"))
        val thread = HandlerThread("cam-probe-capture").apply { start() }
        val capture = Capture(manager, id, thread, shell)
        try {
            capture.startEncoder()
            capture.openCamera()
            if (!capture.awaitOpened(5_000)) {
                return ProbeResult(
                    stage.name,
                    false,
                    base + listOf("camera" to id, "opened" to "false", "error" to (capture.openError ?: "no_open_callback")),
                )
            }
            if (!capture.awaitConfigured(5_000)) {
                return ProbeResult(
                    stage.name,
                    false,
                    base + listOf(
                        "camera" to id,
                        "opened" to "true",
                        "session" to "not_configured",
                        "error" to (capture.sessionError ?: capture.deviceError ?: "no_session_callback"),
                    ),
                )
            }
            val started = SystemClock.elapsedRealtime()
            var lastCam = 0L
            var lastEnc = 0L
            for (i in 1..stage.seconds) {
                Thread.sleep(1_000)
                lastCam = capture.camFrames.get()
                lastEnc = capture.encoder.frames.get()
                if (capture.disconnected || capture.deviceError != null) break
            }
            val elapsedMs = (SystemClock.elapsedRealtime() - started).coerceAtLeast(1)
            val camFps = lastCam * 1000.0 / elapsedMs
            val encFps = lastEnc * 1000.0 / elapsedMs
            val facts = base.toMutableList()
            facts += "camera" to id
            facts += "ms" to elapsedMs.toString()
            facts += "camFrames" to lastCam.toString()
            facts += "camFps" to "%.1f".format(camFps)
            facts += "encFrames" to lastEnc.toString()
            facts += "encFps" to "%.1f".format(encFps)
            facts += "keyframes" to capture.encoder.keyframes.get().toString()
            facts += "keyGapsMs" to capture.encoder.keyGaps().joinToString(",").ifEmpty { "-" }
            facts += "avgBytes" to (capture.encoder.bytes.get() / lastEnc.coerceAtLeast(1)).toString()
            facts += "format" to (capture.encoder.outputFormat ?: "none")
            facts += "camErrors" to capture.camErrors.get().toString()
            facts += "drainError" to (capture.encoder.drainError ?: "none")
            facts += "error" to (capture.openError ?: capture.sessionError ?: capture.deviceError ?: "none")
            facts += "disconnected" to capture.disconnected.toString()
            if (locked) {
                facts += "interactive" to (capture.interactive?.toString() ?: "-")
                facts += "keyguard" to (capture.keyguardLocked?.toString() ?: "-")
            }
            val ok = lastEnc > 0 && capture.openError == null && capture.sessionError == null
            return ProbeResult(stage.name, ok, facts)
        } finally {
            capture.close()
            quit(thread)
        }
    }

    // -------------------------------------------------------------------- P5

    /**
     * Capture until another client takes the camera. The shell side starts the
     * camera app once [READY_MARKER] exists; the stage then records which
     * callback arrived and that the encoder stopped producing.
     */
    private fun stageEvict(
        manager: CameraManager,
        shell: Context,
        stage: ProbeStage,
        base: List<Pair<String, String>>,
    ): ProbeResult {
        val id = pickCamera(manager, stage) ?: return ProbeResult(stage.name, false, base + listOf("error" to "no_camera"))
        val ready = stage.ready ?: READY_MARKER
        runCatching { File(ready).delete() }
        val thread = HandlerThread("cam-probe-evict").apply { start() }
        val capture = Capture(manager, id, thread, shell, ready)
        try {
            capture.startEncoder()
            capture.openCamera()
            if (!capture.awaitOpened(5_000) || !capture.awaitConfigured(5_000)) {
                return ProbeResult(
                    stage.name,
                    false,
                    base + listOf(
                        "camera" to id,
                        "opened" to capture.openSignalled.toString(),
                        "configured" to capture.configuredSignalled.toString(),
                        "error" to (capture.openError ?: capture.sessionError ?: capture.deviceError ?: "not_streaming"),
                    ),
                )
            }
            val deadline = SystemClock.elapsedRealtime() + stage.seconds * 1000L
            while (SystemClock.elapsedRealtime() < deadline && !capture.disconnected && capture.deviceError == null) {
                Thread.sleep(100)
            }
            val reason = when {
                capture.disconnected -> "onDisconnected"
                capture.deviceError != null -> capture.deviceError!!
                else -> "none"
            }
            val framesAtEviction = capture.encoder.frames.get()
            Thread.sleep(1_000)
            val after = capture.encoder.frames.get() - framesAtEviction
            val ok = capture.disconnected || capture.deviceError != null
            return ProbeResult(
                stage.name,
                ok,
                base + listOf(
                    "camera" to id,
                    "evicted" to ok.toString(),
                    "reason" to reason,
                    "frames" to framesAtEviction.toString(),
                    "framesAfter1s" to after.toString(),
                    "camErrors" to capture.camErrors.get().toString(),
                ),
            )
        } finally {
            capture.close()
            quit(thread)
        }
    }

    private fun quit(thread: HandlerThread) {
        runCatching { thread.quitSafely() }
        runCatching { thread.join(1_000) }
    }

    // ----------------------------------------------------------------- capture

    /**
     * The encoder shape WindowStream uses (H.264 1280x720@30, VBR, 1 s I-frame
     * interval), fed straight from the camera. Counts and sizes only.
     */
    private class Encoder720p {
        val codec: MediaCodec = MediaCodec.createEncoderByType("video/avc")
        var surface: Surface? = null
        val frames = AtomicLong()
        val keyframes = AtomicLong()
        val bytes = AtomicLong()
        @Volatile var outputFormat: String? = null
        @Volatile var drainError: String? = null
        private val stop = AtomicBoolean(false)
        private val gaps = ArrayList<Long>()
        private var lastKeyAt = 0L
        private var drain: Thread? = null

        fun start() {
            val format = MediaFormat.createVideoFormat("video/avc", IMAGE_WIDTH, IMAGE_HEIGHT)
            format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            format.setInteger(MediaFormat.KEY_BIT_RATE, BITRATE)
            format.setInteger(MediaFormat.KEY_FRAME_RATE, IMAGE_FPS)
            format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, I_FRAME_INTERVAL_S)
            format.setInteger(MediaFormat.KEY_PRIORITY, 0)
            format.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            format.setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
            runCatching { format.setInteger(MediaFormat.KEY_LATENCY, 1) }
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            surface = codec.createInputSurface()
            codec.start()
        }

        fun startDrain() {
            drain = Thread({
                val info = MediaCodec.BufferInfo()
                while (!stop.get()) {
                    val index = try {
                        codec.dequeueOutputBuffer(info, 10_000)
                    } catch (t: Throwable) {
                        if (!stop.get()) drainError = "${t.javaClass.simpleName}:${t.message}"
                        break
                    }
                    if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        val f = codec.outputFormat
                        outputFormat = "${f.getString(MediaFormat.KEY_MIME)} " +
                            "${f.getInteger(MediaFormat.KEY_WIDTH)}x${f.getInteger(MediaFormat.KEY_HEIGHT)}"
                        continue
                    }
                    if (index < 0) continue
                    val key = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
                    if (info.size > 0) {
                        if (key) {
                            keyframes.incrementAndGet()
                            val now = SystemClock.elapsedRealtime()
                            synchronized(gaps) {
                                if (lastKeyAt != 0L) gaps.add(now - lastKeyAt)
                                lastKeyAt = now
                            }
                        }
                        bytes.addAndGet(info.size.toLong())
                        frames.incrementAndGet()
                    }
                    runCatching { codec.releaseOutputBuffer(index, false) }
                }
            }, "cam-encoder-drain").apply { start() }
        }

        fun keyGaps(): List<Long> = synchronized(gaps) { gaps.take(6) }

        fun stop() {
            stop.set(true)
            val t = drain
            if (t !== Thread.currentThread()) runCatching { t?.join(500) }
            runCatching { codec.stop() }
            runCatching { codec.release() }
            runCatching { surface?.release() }
            surface = null
        }
    }

    /** One camera hold + encoder + repeating request; all waits are bounded. */
    private class Capture(
        private val manager: CameraManager,
        private val id: String,
        private val thread: HandlerThread,
        private val context: Context,
        private val readyFile: String? = null,
    ) {
        val encoder = Encoder720p()
        val camFrames = AtomicLong()
        val camErrors = AtomicLong()
        private val opened = CountDownLatch(1)
        private val configured = CountDownLatch(1)
        @Volatile var openError: String? = null
        @Volatile var sessionError: String? = null
        @Volatile var deviceError: String? = null
        @Volatile var disconnected = false
        @Volatile var interactive: Boolean? = null
        @Volatile var keyguardLocked: Boolean? = null
        private var device: CameraDevice? = null
        private var session: CameraCaptureSession? = null
        private val closed = AtomicBoolean(false)

        val openSignalled: Boolean get() = opened.count == 0L
        val configuredSignalled: Boolean get() = configured.count == 0L

        fun startEncoder() {
            encoder.start()
            encoder.startDrain()
        }

        fun openCamera() {
            runCatching { manager.openCamera(id, stateCallback, Handler(thread.looper)) }
                .onFailure {
                    openError = "${it.javaClass.simpleName}:${it.message}"
                    opened.countDown()
                    configured.countDown()
                }
        }

        fun awaitOpened(ms: Long): Boolean =
            runCatching { opened.await(ms, TimeUnit.MILLISECONDS) }.getOrDefault(false) && openError == null

        fun awaitConfigured(ms: Long): Boolean =
            runCatching { configured.await(ms, TimeUnit.MILLISECONDS) }.getOrDefault(false) && sessionError == null

        private val handler: Handler get() = Handler(thread.looper)

        private val stateCallback = object : CameraDevice.StateCallback() {
            override fun onOpened(cam: CameraDevice) {
                if (closed.get()) {
                    runCatching { cam.close() }
                    return
                }
                device = cam
                opened.countDown()
                val surface = encoder.surface ?: run {
                    openError = "no_encoder_surface"
                    configured.countDown()
                    return
                }
                runCatching {
                    cam.createCaptureSession(listOf(surface), sessionCallback(surface), handler)
                }.onFailure {
                    sessionError = "${it.javaClass.simpleName}:${it.message}"
                    configured.countDown()
                }
            }

            override fun onDisconnected(cam: CameraDevice) {
                disconnected = true
                runCatching { cam.close() }
                opened.countDown()
                configured.countDown()
            }

            override fun onError(cam: CameraDevice, error: Int) {
                deviceError = "error_${error}_${errorName(error)}"
                runCatching { cam.close() }
                opened.countDown()
                configured.countDown()
            }
        }

        private fun sessionCallback(surface: Surface) = object : CameraCaptureSession.StateCallback() {
            override fun onConfigured(created: CameraCaptureSession) {
                if (closed.get()) {
                    runCatching { created.close() }
                    return
                }
                session = created
                runCatching {
                    val request = device?.createCaptureRequest(CameraDevice.TEMPLATE_RECORD) ?: error("no device")
                    request.addTarget(surface)
                    val range = runCatching {
                        manager.getCameraCharacteristics(id)
                            .get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                            ?.firstOrNull { it.upper >= IMAGE_FPS && it.lower <= IMAGE_FPS }
                    }.getOrNull() ?: Range(IMAGE_FPS, IMAGE_FPS)
                    request.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, range)
                    request.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                    created.setRepeatingRequest(
                        request.build(),
                        object : CameraCaptureSession.CaptureCallback() {
                            override fun onCaptureCompleted(
                                s: CameraCaptureSession,
                                r: CaptureRequest,
                                result: TotalCaptureResult,
                            ) {
                                camFrames.incrementAndGet()
                            }

                            override fun onCaptureFailed(
                                s: CameraCaptureSession,
                                r: CaptureRequest,
                                failure: CaptureFailure,
                            ) {
                                camErrors.incrementAndGet()
                            }
                        },
                        handler,
                    )
                    readPower()
                    readyFile?.let { runCatching { File(it).writeText("ready\n") } }
                    configured.countDown()
                }.onFailure {
                    sessionError = "${it.javaClass.simpleName}:${it.message}"
                    configured.countDown()
                }
            }

            override fun onConfigureFailed(created: CameraCaptureSession) {
                sessionError = "onConfigureFailed"
                configured.countDown()
            }
        }

        /** P2's facts, read at the moment the session went live. */
        private fun readPower() {
            runCatching {
                val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                val keyguard = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
                interactive = power.isInteractive
                keyguardLocked = keyguard.isKeyguardLocked
            }
        }

        fun close() {
            if (!closed.compareAndSet(false, true)) return
            runCatching { session?.close() }
            runCatching { device?.close() }
            session = null
            device = null
            encoder.stop()
        }

        private fun errorName(error: Int): String = when (error) {
            CameraDevice.StateCallback.ERROR_CAMERA_IN_USE -> "in_use"
            CameraDevice.StateCallback.ERROR_MAX_CAMERAS_IN_USE -> "max_cameras_in_use"
            CameraDevice.StateCallback.ERROR_CAMERA_DISABLED -> "disabled"
            CameraDevice.StateCallback.ERROR_CAMERA_DEVICE -> "device"
            CameraDevice.StateCallback.ERROR_CAMERA_SERVICE -> "service"
            else -> "unknown"
        }
    }
}
