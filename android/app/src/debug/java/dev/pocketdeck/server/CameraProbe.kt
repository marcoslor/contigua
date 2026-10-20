package dev.pocketdeck.server

import android.app.KeyguardManager
import android.content.AttributionSource
import android.content.Context
import android.content.ContextWrapper
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import android.os.HandlerThread
import android.os.PowerManager
import android.os.SystemClock
import android.util.Range
import android.view.Surface
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/**
 * Camera spike probe (debug builds only, v0.2 #7).
 *
 * Runs as a second `app_process` at the adb shell UID, the same way the Shizuku
 * user service and the watchdog do, and prints one line per fact. It answers:
 * can that UID list and open a camera, does it keep capturing with the panel off
 * and the keyguard up, does a Camera2 surface feed the H.264 encoder path
 * (WindowStream's settings), and what happens when a second client asks for the
 * camera. No frames are stored: only counts and byte sizes are logged.
 *
 * Usage (device side):
 *   CLASSPATH=$(pm path dev.pocketdeck | cut -d: -f2) app_process /system/bin \
 *       dev.pocketdeck.server.CameraProbe list
 *       dev.pocketdeck.server.CameraProbe run [seconds] [cameraId]
 *       dev.pocketdeck.server.CameraProbe open [seconds] [cameraId]
 *       dev.pocketdeck.server.CameraProbe pkg [cameraId]
 *
 * `open` holds a camera without a session (the second-client side of the
 * eviction test); `pkg` compares a `com.android.shell` attribution with the
 * process' own system context.
 */
internal object CameraProbe {

    private const val MIME = "video/avc"
    private const val WIDTH = 1280
    private const val HEIGHT = 720
    private const val FPS = 30
    private const val IF_INTERVAL_S = 1
    private const val BITRATE = 4_000_000

    @JvmStatic
    fun main(args: Array<String>) {
        // ActivityThread's constructor makes a Handler, so the bare
        // app_process main thread needs a Looper before any context exists.
        runCatching { Looper.prepareMainLooper() }
        val mode = args.getOrNull(0) ?: "list"
        val seconds = args.getOrNull(1)?.toIntOrNull() ?: 6
        val wanted = args.getOrNull(2)
        try {
            when (mode) {
                "list" -> list(wanted)
                "run" -> run(seconds, wanted)
                "open" -> open(seconds, wanted)
                "pkg" -> pkg(wanted)
                "selftest" -> selftest()
                else -> say("unknown mode '$mode'")
            }
        } catch (t: Throwable) {
            say("fatal ${t.javaClass.name}: ${t.message}")
            t.stackTrace.take(4).forEach { say("  at $it") }
        }
        System.out.flush()
    }

    // ------------------------------------------------------------------ context

    /**
     * A framework Context from a bare `app_process`: [android.app.ActivityThread.systemMain]
     * attaches it to the system the way system_server does. Hidden API, which the
     * shell UID (2000) is not restricted from.
     */
    private fun systemContext(): Context? {
        val at = runCatching { Class.forName("android.app.ActivityThread") }.getOrNull()
        if (at == null) {
            say("context: no android.app.ActivityThread")
            return null
        }
        // 1. systemMain returns an ActivityThread (not a Context), and its
        //    getSystemContext builds the framework Context. Attach at uid 2000
        //    may be refused; the bare-thread fallback below does not attach.
        runCatching {
            val thread = at.getDeclaredMethod("systemMain").invoke(null)
            at.getMethod("getSystemContext").invoke(thread) as Context
        }.onSuccess { say("context: systemMain"); return it }
            .onFailure { say("context: systemMain failed ${chain(it)}") }
        // 2. A bare ActivityThread (never attached) still builds the system
        //    Context, and that is all a CameraManager needs.
        val bare = runCatching {
            at.getDeclaredConstructor().apply { isAccessible = true }.newInstance()
        }.onFailure { say("context: ActivityThread() failed ${chain(it)}") }.getOrNull()
        if (bare != null) {
            runCatching { at.getMethod("getSystemContext").invoke(bare) as Context }
                .onSuccess { say("context: bare ActivityThread.getSystemContext"); return it }
                .onFailure { say("context: getSystemContext failed ${chain(it)}") }
            runCatching {
                Class.forName("android.app.ContextImpl")
                    .getDeclaredMethod("createSystemContext", at)
                    .apply { isAccessible = true }
                    .invoke(null, bare) as Context
            }.onSuccess { say("context: ContextImpl.createSystemContext"); return it }
                .onFailure { say("context: createSystemContext failed ${chain(it)}") }
        }
        return null
    }

    private fun chain(t: Throwable): String =
        generateSequence(t) { it.cause }.take(6)
            .joinToString(" <- ") { "${it.javaClass.name}: ${it.message}" }

    /**
     * A CameraManager whose context is [ctx]. `getSystemService` cannot be used:
     * ContextWrapper delegates to the base ContextImpl, which hands the service
     * its own package name ("android"), and the camera service then refuses the
     * call because uid 2000 does not own that package.
     */
    private fun cameraManager(ctx: Context): CameraManager {
        adoptShellPackage((ctx as? ContextWrapper)?.baseContext ?: ctx)
        runCatching {
            CameraManager::class.java.getConstructor(Context::class.java).newInstance(ctx)
        }.onSuccess { return it }
            .onFailure { say("camera manager: direct constructor failed ${chain(it)}") }
        return ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    }

    /**
     * CameraManager calls the service with the *base* ContextImpl's package even
     * when it was constructed with a wrapper (observed on API 36). Give the base
     * the shell identity too, so every service call names uid 2000's package.
     */
    private fun adoptShellPackage(base: Context) {
        runCatching {
            val cls = base.javaClass
            cls.getDeclaredField("mPackageName").apply { isAccessible = true }.set(base, "com.android.shell")
            cls.getDeclaredField("mOpPackageName").apply { isAccessible = true }.set(base, "com.android.shell")
            cls.getDeclaredField("mAttributionSource").apply { isAccessible = true }
                .set(base, AttributionSource.Builder(android.os.Process.myUid())
                    .setPackageName("com.android.shell").build())
        }.onFailure { say("context: base package adoption failed ${chain(it)}") }
    }

    private fun shellManager(ctx: Context): CameraManager = cameraManager(ctx)

    private fun describe(ctx: Context, label: String) {
        say(
            "$label: uid=${android.os.Process.myUid()} pid=${android.os.Process.myPid()} " +
                "pkg=${ctx.packageName} op=${ctx.opPackageName} " +
                "attribution=${ctx.attributionSource.packageName}/${ctx.attributionSource.uid}",
        )
    }

    // -------------------------------------------------------------------- P1

    private fun list(wanted: String?) {
        val base = systemContext() ?: return
        val shell = ShellContext(base)
        describe(base, "base context")
        describe(shell, "shell context")
        val mgr = shellManager(shell)
        val ids = try {
            mgr.cameraIdList
        } catch (t: Throwable) {
            say("list failed ${t.javaClass.name}: ${t.message}")
            return
        }
        say("cameraIds=${ids.size} [${ids.joinToString(",")}]")
        for (id in ids) {
            try {
                val c = mgr.getCameraCharacteristics(id)
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
                    else -> "?"
                }
                val map = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                val sizes = map?.getOutputSizes(android.graphics.SurfaceTexture::class.java)
                val has720 = sizes?.any { it.width == WIDTH && it.height == HEIGHT } ?: false
                val biggest = sizes?.sortedByDescending { it.width.toLong() * it.height }?.take(4)
                val ranges = c.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                say(
                    "camera $id: facing=$facing level=$level orientation=" +
                        "${c.get(CameraCharacteristics.SENSOR_ORIENTATION)} " +
                        "sizes=${sizes?.size ?: 0} ${biggest ?: "[]"} 720p=$has720 " +
                        "fps=${ranges?.joinToString(",") { "${it.lower}-${it.upper}" } ?: "[]"}",
                )
                if (wanted == null || wanted == id) {
                    val best = sizes?.firstOrNull { it.width == WIDTH && it.height == HEIGHT }
                    say("camera $id: 720p stream=${if (best != null) "${best.width}x${best.height}" else "absent"}")
                }
            } catch (t: Throwable) {
                say("camera $id: characteristics failed ${t.javaClass.name}: ${t.message}")
            }
        }
    }

    /**
     * P1's package question: the same open with the system context's own package
     * (`android`, which uid 2000 does not own) and with `com.android.shell`.
     */
    private fun pkg(wanted: String?) {
        val base = systemContext() ?: return
        val id = wanted ?: (shellManager(ShellContext(base)).cameraIdList.firstOrNull()) ?: run {
            say("pkg: no cameras")
            return
        }
        val shell = ShellContext(base)
        tryOpen("pkg=android", shellManager(base), id, holdMs = 0)
        tryOpen("pkg=com.android.shell", shellManager(shell), id, holdMs = 0)
    }

    private fun tryOpen(label: String, mgr: CameraManager, id: String, holdMs: Long) {
        val latch = CountDownLatch(1)
        val outcome = Array(1) { "pending" }
        val cb = object : CameraDevice.StateCallback() {
            override fun onOpened(device: CameraDevice) {
                outcome[0] = "opened"
                latch.countDown()
                if (holdMs <= 0) device.close()
            }

            override fun onDisconnected(device: CameraDevice) {
                outcome[0] = "disconnected"
                latch.countDown()
                device.close()
            }

            override fun onError(device: CameraDevice, error: Int) {
                outcome[0] = "error $error"
                latch.countDown()
                device.close()
            }
        }
        val thread = HandlerThread("cam-pkg").apply { start() }
        try {
            mgr.openCamera(id, cb, Handler(thread.looper))
            latch.await(3, TimeUnit.SECONDS)
            say("$label: open $id -> ${outcome[0]}")
        } catch (t: Throwable) {
            say("$label: open $id threw ${t.javaClass.name}: ${t.message}")
        } finally {
            thread.quitSafely()
        }
    }

    // -------------------------------------------------------------------- P3

    /** The exact encoder shape WindowStream uses, fed straight from the camera. */
    private class Encoder720p {
        val codec: MediaCodec = MediaCodec.createEncoderByType(MIME)
        var surface: Surface? = null
        val frames = AtomicLong()
        val keyframes = AtomicLong()
        val bytes = AtomicLong()
        val keyGapsMs = ArrayList<Long>()
        private var lastKeyAt = 0L
        private val stop = AtomicBoolean(false)
        @Volatile var outputFormat: String? = null
        @Volatile var drainError: String? = null

        fun start() {
            val format = MediaFormat.createVideoFormat(MIME, WIDTH, HEIGHT)
            format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            format.setInteger(MediaFormat.KEY_BIT_RATE, BITRATE)
            format.setInteger(MediaFormat.KEY_FRAME_RATE, FPS)
            format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, IF_INTERVAL_S)
            format.setInteger(MediaFormat.KEY_PRIORITY, 0)
            format.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            format.setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
            runCatching { format.setInteger(MediaFormat.KEY_LATENCY, 1) }
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            surface = codec.createInputSurface()
            codec.start()
        }

        fun startDrain(): Thread = Thread({
            val info = MediaCodec.BufferInfo()
            while (!stop.get()) {
                val idx = try {
                    codec.dequeueOutputBuffer(info, 10_000)
                } catch (t: Throwable) {
                    drainError = "${t.javaClass.name}: ${t.message}"
                    break
                }
                when {
                    idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val f = codec.outputFormat
                        outputFormat = "${f.getString(MediaFormat.KEY_MIME)} " +
                            "${f.getInteger(MediaFormat.KEY_WIDTH)}x${f.getInteger(MediaFormat.KEY_HEIGHT)}"
                    }
                    idx >= 0 -> {
                        val key = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
                        val now = SystemClock.elapsedRealtime()
                        if (key) {
                            keyframes.incrementAndGet()
                            if (lastKeyAt != 0L) synchronized(keyGapsMs) { keyGapsMs.add(now - lastKeyAt) }
                            lastKeyAt = now
                        }
                        bytes.addAndGet(info.size.toLong())
                        frames.incrementAndGet()
                        codec.releaseOutputBuffer(idx, false)
                    }
                }
            }
        }, "cam-encoder-drain").apply { start() }

        fun stop() {
            stop.set(true)
            runCatching { codec.stop() }
            runCatching { codec.release() }
            runCatching { surface?.release() }
        }
    }

    // --------------------------------------------------------------- P1/P2/P3

    private fun run(seconds: Int, wanted: String?) {
        val base = systemContext() ?: return
        val shell = ShellContext(base)
        describe(shell, "shell context")
        val pm = shell.getSystemService(Context.POWER_SERVICE) as PowerManager
        val km = shell.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        val mgr = shellManager(shell)
        val id = wanted ?: mgr.cameraIdList.firstOrNull() ?: run {
            say("run: no cameras")
            return
        }
        say("run: camera=$id seconds=$seconds encoder=${WIDTH}x$HEIGHT@$FPS iframe=${IF_INTERVAL_S}s")

        val encoder = try {
            Encoder720p().also { it.start() }.also { it.startDrain() }
        } catch (t: Throwable) {
            say("encoder failed ${t.javaClass.name}: ${t.message}")
            return
        }
        say("encoder: started, output surface created")

        val thread = HandlerThread("cam-probe").apply { start() }
        val handler = Handler(thread.looper)
        val camFrames = AtomicLong()
        val camErrors = AtomicInteger()
        val opened = CountDownLatch(1)
        val configured = CountDownLatch(1)
        val openFailure = AtomicReference<String?>(null)
        val sessionFailure = AtomicReference<String?>(null)
        val disconnected = AtomicBoolean(false)

        val state = object : CameraDevice.StateCallback() {
            override fun onOpened(device: CameraDevice) {
                say("open ok")
                val surface = encoder.surface ?: return
                try {
                    device.createCaptureSession(
                        listOf(surface),
                        object : CameraCaptureSession.StateCallback() {
                            override fun onConfigured(session: CameraCaptureSession) {
                                say("session configured")
                                try {
                                    val req = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
                                    req.addTarget(surface)
                                    val range = mgr.getCameraCharacteristics(id)
                                        .get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                                        ?.firstOrNull { it.upper >= FPS && it.lower <= FPS }
                                        ?: Range(FPS, FPS)
                                    req.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, range)
                                    req.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                                    session.setRepeatingRequest(
                                        req.build(),
                                        object : CameraCaptureSession.CaptureCallback() {
                                            override fun onCaptureCompleted(
                                                s: CameraCaptureSession,
                                                r: CaptureRequest,
                                                result: android.hardware.camera2.TotalCaptureResult,
                                            ) {
                                                camFrames.incrementAndGet()
                                            }

                                            override fun onCaptureFailed(
                                                s: CameraCaptureSession,
                                                r: CaptureRequest,
                                                failure: android.hardware.camera2.CaptureFailure,
                                            ) {
                                                camErrors.incrementAndGet()
                                            }
                                        },
                                        handler,
                                    )
                                    say("repeating request: ${range.lower}-${range.upper} fps")
                                    configured.countDown()
                                } catch (t: Throwable) {
                                    sessionFailure.set("${t.javaClass.name}: ${t.message}")
                                    say("repeating request failed ${sessionFailure.get()}")
                                    configured.countDown()
                                }
                            }

                            override fun onConfigureFailed(session: CameraCaptureSession) {
                                sessionFailure.set("onConfigureFailed")
                                say("session configure failed")
                                configured.countDown()
                            }
                        },
                        handler,
                    )
                } catch (t: Throwable) {
                    sessionFailure.set("${t.javaClass.name}: ${t.message}")
                    say("createCaptureSession failed ${sessionFailure.get()}")
                    configured.countDown()
                }
                opened.countDown()
            }

            override fun onDisconnected(device: CameraDevice) {
                disconnected.set(true)
                say("disconnected by the camera service")
                device.close()
                opened.countDown()
                configured.countDown()
            }

            override fun onError(device: CameraDevice, error: Int) {
                openFailure.set("device error $error")
                say("device error $error")
                device.close()
                opened.countDown()
                configured.countDown()
            }
        }

        try {
            mgr.openCamera(id, state, handler)
        } catch (t: Throwable) {
            openFailure.set("${t.javaClass.name}: ${t.message}")
            say("open threw ${openFailure.get()}")
            encoder.stop()
            return
        }
        if (!opened.await(5, TimeUnit.SECONDS)) say("open: no callback within 5 s")
        if (!configured.await(5, TimeUnit.SECONDS)) say("session: not configured within 5 s")

        val started = SystemClock.elapsedRealtime()
        var lastCam = 0L
        var lastEnc = 0L
        for (i in 1..seconds) {
            Thread.sleep(1_000)
            val cam = camFrames.get()
            val enc = encoder.frames.get()
            say(
                "t=${i}s camFrames=$cam (+${cam - lastCam}) encFrames=$enc (+${enc - lastEnc}) " +
                    "key=${encoder.keyframes.get()} bytes=${encoder.bytes.get()} " +
                    "screen=${if (pm.isInteractive) "on" else "off"} " +
                    "keyguard=${if (km.isKeyguardLocked) "locked" else "unlocked"} " +
                    "camErrors=${camErrors.get()} disconnected=${disconnected.get()}",
            )
            lastCam = cam
            lastEnc = enc
            if (disconnected.get()) break
        }
        val elapsedMs = (SystemClock.elapsedRealtime() - started).coerceAtLeast(1)
        val gaps = synchronized(encoder.keyGapsMs) { encoder.keyGapsMs.toList() }
        say(
            "summary: ms=$elapsedMs camFps=${"%.1f".format(camFrames.get() * 1000.0 / elapsedMs)} " +
                "encFps=${"%.1f".format(encoder.frames.get() * 1000.0 / elapsedMs)} " +
                "keyframes=${encoder.keyframes.get()} keyGapsMs=${gaps.take(6)} " +
                "avgBytes=${encoder.bytes.get() / encoder.frames.get().coerceAtLeast(1)} " +
                "encoderFormat=${encoder.outputFormat ?: "none"} " +
                "drainError=${encoder.drainError ?: "none"} " +
                "camErrors=${camErrors.get()} sessionFailure=${sessionFailure.get() ?: "none"} " +
                "openFailure=${openFailure.get() ?: "none"}",
        )
        say("released")
        encoder.stop()
        thread.quitSafely()
    }

    // -------------------------------------------------------------------- P5

    /** Holds the camera without a session: the second client in the eviction test. */
    private fun open(seconds: Int, wanted: String?) {
        val base = systemContext() ?: return
        val shell = ShellContext(base)
        describe(shell, "shell context")
        val mgr = shellManager(shell)
        val id = wanted ?: mgr.cameraIdList.firstOrNull() ?: run {
            say("open: no cameras")
            return
        }
        val thread = HandlerThread("cam-hold").apply { start() }
        val latch = CountDownLatch(1)
        val outcome = AtomicReference("pending")
        val cb = object : CameraDevice.StateCallback() {
            override fun onOpened(device: CameraDevice) {
                outcome.set("opened")
                say("hold: open $id ok")
                latch.countDown()
            }

            override fun onDisconnected(device: CameraDevice) {
                outcome.set("disconnected")
                say("hold: disconnected")
                device.close()
                latch.countDown()
            }

            override fun onError(device: CameraDevice, error: Int) {
                outcome.set("error $error")
                say("hold: error $error")
                device.close()
                latch.countDown()
            }
        }
        try {
            mgr.openCamera(id, cb, Handler(thread.looper))
        } catch (t: Throwable) {
            say("hold: open $id threw ${t.javaClass.name}: ${t.message}")
            thread.quitSafely()
            return
        }
        latch.await(5, TimeUnit.SECONDS)
        say("hold: outcome=${outcome.get()} camera=$id")
        Thread.sleep(seconds * 1000L)
        say("hold: releasing after ${seconds}s (outcome=${outcome.get()})")
        thread.quitSafely()
    }

    private fun selftest() {
        val ctx = systemContext()
        if (ctx == null) {
            say("selftest: no context")
            return
        }
        say("selftest: context=${ctx.javaClass.name} pkg=${ctx.packageName} op=${ctx.opPackageName}")
        val shell = ShellContext(ctx)
        val mgr = runCatching { shellManager(shell) }
        say("selftest: cameraManager=${mgr.getOrNull()?.javaClass?.name} err=${mgr.exceptionOrNull()?.let { chain(it) }}")
        val ids = runCatching { mgr.getOrNull()?.cameraIdList }
        say("selftest: cameraIdList=${ids.getOrNull()?.joinToString(",")} err=${ids.exceptionOrNull()?.let { chain(it) }}")
    }

    private fun say(line: String) {
        println("cam: $line")
        System.out.flush()
    }
}
