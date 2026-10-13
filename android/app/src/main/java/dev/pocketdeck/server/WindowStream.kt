package dev.pocketdeck.server

import android.content.Context
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.view.Surface
import dev.pocketdeck.proto.Frames
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

/**
 * One VirtualDisplay whose surface is a MediaCodec H.264 encoder input. The
 * encoded output is pushed straight into the session's send queue.
 */
internal class WindowStream(
    private val ctx: Context,
    val stream: Int,
    private val sink: VideoSink,
    private val log: (String) -> Unit,
) {

    private companion object {
        const val MIME = "video/avc"
        const val FPS = 60
        const val I_FRAME_INTERVAL_S = 10
        const val MAX_BITRATE = 8_000_000
        const val MIN_BITRATE = 500_000

        const val VIRTUAL_DISPLAY_CONFIG = "android.hardware.display.VirtualDisplayConfig"

        /** `MediaFormat.KEY_MAX_FPS_TO_ENCODER`, kept as a string: some builds' encoders reject it. */
        const val KEY_MAX_FPS = "max-fps-to-encoder"

        // @hide DisplayManager flags, verified against AOSP. Deliberately absent:
        // the system-decorations flag (bit 9) and the device display-group flag
        // (bit 15). The first adds a SystemUI nav bar and poisons One UI's back
        // gesture; the second would tie the VD to the panel's power state and
        // freeze it while the phone is locked.
        const val FLAG_SECURE = 1 shl 2
        const val FLAG_AUTO_MIRROR = 1 shl 4
        const val FLAG_CAN_SHOW_WITH_INSECURE_KEYGUARD = 1 shl 5
        const val FLAG_SUPPORTS_TOUCH = 1 shl 6
        const val FLAG_ROTATES_WITH_CONTENT = 1 shl 7
        const val FLAG_DESTROY_CONTENT_ON_REMOVAL = 1 shl 8
        const val FLAG_SHOULD_SHOW_SYSTEM_DECORATIONS = 1 shl 9
        const val FLAG_TRUSTED = 1 shl 10
        const val FLAG_OWN_DISPLAY_GROUP = 1 shl 11
        const val FLAG_ALWAYS_UNLOCKED = 1 shl 12
        const val FLAG_TOUCH_FEEDBACK_DISABLED = 1 shl 13
        const val FLAG_OWN_FOCUS = 1 shl 14
        const val FLAG_DEVICE_DISPLAY_GROUP = 1 shl 15
        const val FLAG_STEAL_TOP_FOCUS_DISABLED = 1 shl 16
    }

    @Volatile private var vd: VirtualDisplay? = null
    @Volatile private var encoder: MediaCodec? = null
    @Volatile private var drainThread: Thread? = null
    @Volatile private var released = false
    @Volatile private var paused = false
    @Volatile private var width = 0
    @Volatile private var height = 0

    /** The density last asked for by the Mac; redraw nudges are offsets from it. */
    @Volatile private var baseDpi = 0

    /** An encoder built for the next attach, and the one it replaces. */
    private var prepared: Prepared? = null
    private var previous: MediaCodec? = null
    private var limits = EncoderLimits()
    private var caps: MediaCodecInfo.VideoCapabilities? = null

    private class Prepared(val codec: MediaCodec, val surface: Surface)

    private val guard = RedrawGuard()
    private val sequencer = ResizeSequencer(object : ResizeSteps {
        override fun fit(w: Int, h: Int): IntSize = fitToEncoder(w, h)
        override fun prepare(size: IntSize): IntSize? = prepareEncoder(size.w, size.h)
        override fun resizeDisplay(size: IntSize, dpi: Int) = applyDisplaySize(size, dpi)
        override fun attachPrepared() = swapInPrepared()
        override fun releasePrevious() = releasePreviousEncoder()
    })

    /** Live bitrate policy: computed target or `window.quality`, drops and recovery. */
    private val quality = QualityAdaptation()

    /** Explicit `window.quality` bitrate; null means "computed from the pixels". */
    @Volatile private var requestedBitrate: Int? = null

    /** `window.quality` fps cap; frames above it are dropped before queueing. */
    @Volatile private var maxFps: Int? = null

    /** Encoder pts of the last frame actually queued, for the fps cap. */
    @Volatile private var lastForwardedUs = -1L

    private var appliedBitrate = 0

    @Volatile private var displayIdValue = -1

    val displayId: Int get() = displayIdValue
    val size: IntSize get() = IntSize(width, height)

    fun start(w: Int, h: Int, dpi: Int): Int {
        baseDpi = dpi
        val size = checkNotNull(prepareEncoder(w, h)) { "no encoder for ${w}x$h" }
        val next = prepared!!
        prepared = null
        val created = createDisplay(size.w, size.h, dpi, next.surface)
        val display = created.display
        displayIdValue = display.display.displayId
        vd = display
        encoder = next.codec
        startDrain(next.codec)
        hideIme(displayIdValue)
        val requested = flags()
        log("stream $stream vd=$displayIdValue ${size.w}x${size.h} dpi=$dpi path=${created.path}")
        log("stream $stream vd=$displayIdValue requested flags=0x${requested.toString(16)} (${virtualFlagNames(requested)})")
        log("stream $stream vd=$displayIdValue ${DisplayProbe.describe(displayIdValue)}")
        return displayIdValue
    }

    @Synchronized
    fun resize(w: Int, h: Int, dpi: Int) {
        if (released) return
        val result = sequencer.resize(w, h, dpi, paused, IntSize(width, height))
        when (result.outcome) {
            ResizeSequencer.Outcome.RESIZED, ResizeSequencer.Outcome.DISPLAY_ONLY ->
                log("stream $stream resize ${result.size.w}x${result.size.h} dpi=$dpi" +
                    if (result.size.w != w || result.size.h != h) " (asked ${w}x$h)" else "")
            ResizeSequencer.Outcome.KEPT ->
                log("stream $stream resize ${w}x$h refused by the encoder; staying at ${width}x$height")
        }
    }

    @Synchronized
    fun pause() {
        if (paused) return
        paused = true
        detachEncoder()
    }

    @Synchronized
    fun resume() {
        if (!paused || released) return
        paused = false
        val result = sequencer.resume(width, height, baseDpi, IntSize(width, height))
        if (result.outcome == ResizeSequencer.Outcome.KEPT) {
            log("stream $stream resume: no encoder for ${width}x$height")
        }
    }

    fun requestKeyframe() {
        val codec = encoder ?: return
        runCatching {
            val params = Bundle()
            params.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            codec.setParameters(params)
        }
    }

    /** Runtime quality: bitrate target in bps and/or an fps cap (both optional). */
    fun setQuality(bitrate: Int?, maxFps: Int?) {
        // A Mac may repeat a value; only a real change is logged and applied.
        if (maxFps != null && maxFps > 0 && maxFps != this.maxFps) {
            this.maxFps = maxFps
            log(
                "stream $stream quality: maxFps=$maxFps " +
                    "(encoder cap at the next configure; frames above it are dropped)",
            )
        }
        if (bitrate != null && bitrate > 0 && bitrate != requestedBitrate) {
            requestedBitrate = bitrate
            val target = quality.setTarget(bitrate)
            log("stream $stream quality: target bitrate ${mbps(target)} (${bitrate} bps requested)")
            applyBitrate()
        }
    }

    /**
     * The session dropped delta frames for this stream: take 25% off the bitrate
     * (floor 1 Mbps). Recovery happens in the drain loop, 10% every 5 s without
     * a drop, back up to the target.
     */
    fun onBackpressure() {
        val bps = quality.onDrop(SystemClock.elapsedRealtime()) ?: return
        log("stream $stream backpressure: bitrate -> ${mbps(bps)} (-25%)")
        applyBitrate()
    }

    @Synchronized
    fun close() {
        released = true
        detachEncoder()
        runCatching { prepared?.codec?.release() }
        prepared = null
        runCatching { vd?.release() }
        vd = null
        displayIdValue = -1
    }

    // ------------------------------------------------------------------

    /**
     * Builds the next encoder (configured, input surface made, started) at the
     * size the codec will actually take. Leaves the current stream untouched.
     */
    private fun prepareEncoder(w: Int, h: Int): IntSize? {
        val codec = try {
            MediaCodec.createEncoderByType(MIME)
        } catch (e: Throwable) {
            log("stream $stream: no H.264 encoder: ${e.message}")
            return null
        }
        try {
            learnLimits(codec)
            val size = fitToEncoder(w, h)
            configure(codec, size.w, size.h)
            val surface = codec.createInputSurface()
            codec.start()
            width = size.w
            height = size.h
            prepared = Prepared(codec, surface)
            return size
        } catch (e: Throwable) {
            log("stream $stream: encoder for ${w}x$h failed: ${e.message}")
            runCatching { codec.release() }
            return null
        }
    }

    private fun learnLimits(codec: MediaCodec) {
        val found = runCatching { codec.codecInfo.getCapabilitiesForType(MIME).videoCapabilities }.getOrNull() ?: return
        caps = found
        limits = EncoderLimits(
            maxW = found.supportedWidths.upper,
            maxH = found.supportedHeights.upper,
            align = maxOf(found.widthAlignment, found.heightAlignment),
        )
    }

    private fun fitToEncoder(w: Int, h: Int): IntSize {
        val known = caps
        return EncoderSizes.fit(w, h, limits) { sw, sh -> known?.isSizeSupported(sw, sh) ?: true }
    }

    private fun applyDisplaySize(size: IntSize, dpi: Int) {
        width = size.w
        height = size.h
        baseDpi = dpi
        runCatching { vd?.resize(size.w, size.h, dpi) }
            .onFailure { log("stream $stream: VirtualDisplay.resize failed: ${it.message}") }
    }

    /** Points the display at the prepared encoder; the old one is released afterwards. */
    private fun swapInPrepared() {
        val next = prepared ?: return
        prepared = null
        previous = encoder
        encoder = next.codec
        runCatching { vd?.setSurface(next.surface) }
            .onFailure { log("stream $stream: VirtualDisplay.setSurface failed: ${it.message}") }
        guard.onAttached(SystemClock.elapsedRealtime())
        startDrain(next.codec)
    }

    private fun releasePreviousEncoder() {
        val codec = previous ?: return
        previous = null
        runCatching { codec.stop() }
        runCatching { codec.release() }
    }

    private fun detachEncoder() {
        val codec = encoder
        encoder = null
        runCatching { vd?.setSurface(null) }
        if (codec != null) {
            runCatching { codec.stop() }
            runCatching { codec.release() }
        }
    }

    /**
     * No frame arrived after an attach, so the app has nothing to redraw: change
     * the density by one dpi, which every app answers with a relayout and draw.
     */
    private fun nudgeRedraw(codec: MediaCodec, offset: Int) {
        synchronized(this) {
            if (released || encoder !== codec) return
            log("stream $stream: no frame since the encoder attached, redraw nudge ${guard.nudgeCount} (dpi=${baseDpi + offset})")
            runCatching { vd?.resize(width, height, baseDpi + offset) }
        }
    }

    private fun configure(codec: MediaCodec, w: Int, h: Int) {
        // The bitrate target: an explicit window.quality request wins, otherwise
        // it is computed from the pixels (~0.12 bpp·fps).
        quality.setTarget(requestedBitrate ?: bitrateFor(w, h))
        val format = MediaFormat.createVideoFormat(MIME, w, h)
        format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
        format.setInteger(MediaFormat.KEY_BIT_RATE, quality.bitrate)
        format.setInteger(MediaFormat.KEY_FRAME_RATE, FPS)
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, I_FRAME_INTERVAL_S)
        format.setInteger(MediaFormat.KEY_PRIORITY, 0) // realtime
        format.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
        format.setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
        runCatching { format.setInteger(MediaFormat.KEY_LATENCY, 1) }
        // Where the encoder supports the key it caps the frame rate itself;
        // where it does not, the drain loop drops frames above the cap.
        maxFps?.let { runCatching { format.setInteger(KEY_MAX_FPS, it) } }
        appliedBitrate = quality.bitrate
        try {
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        } catch (e: Throwable) {
            if (!format.containsKey(KEY_MAX_FPS)) throw e
            log("stream $stream: encoder refused $KEY_MAX_FPS=$maxFps; dropping frames instead")
            format.removeKey(KEY_MAX_FPS)
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        }
    }

    private fun bitrateFor(w: Int, h: Int): Int {
        // ~0.12 bpp·fps, capped at 8 Mbps.
        val bits = w.toLong() * h.toLong() * FPS * 120 / 1000
        return bits.coerceIn(MIN_BITRATE.toLong(), MAX_BITRATE.toLong()).toInt()
    }

    private fun flags(): Int =
        DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC or
            DisplayManager.VIRTUAL_DISPLAY_FLAG_PRESENTATION or
            DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY or
            FLAG_SUPPORTS_TOUCH or
            FLAG_ROTATES_WITH_CONTENT or
            FLAG_DESTROY_CONTENT_ON_REMOVAL or
            FLAG_TRUSTED or
            FLAG_OWN_DISPLAY_GROUP or
            FLAG_ALWAYS_UNLOCKED or
            FLAG_TOUCH_FEEDBACK_DISABLED or
            FLAG_OWN_FOCUS

    /** Names for the requested flags, so the server log shows what we asked for. */
    private fun virtualFlagNames(f: Int): String {
        val set = ArrayList<String>()
        if (f and DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC != 0) set.add("PUBLIC")
        if (f and DisplayManager.VIRTUAL_DISPLAY_FLAG_PRESENTATION != 0) set.add("PRESENTATION")
        if (f and FLAG_SECURE != 0) set.add("SECURE")
        if (f and FLAG_AUTO_MIRROR != 0) set.add("AUTO_MIRROR")
        if (f and DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY != 0) set.add("OWN_CONTENT_ONLY")
        if (f and FLAG_CAN_SHOW_WITH_INSECURE_KEYGUARD != 0) set.add("CAN_SHOW_WITH_INSECURE_KEYGUARD")
        if (f and FLAG_SUPPORTS_TOUCH != 0) set.add("SUPPORTS_TOUCH")
        if (f and FLAG_ROTATES_WITH_CONTENT != 0) set.add("ROTATES_WITH_CONTENT")
        if (f and FLAG_DESTROY_CONTENT_ON_REMOVAL != 0) set.add("DESTROY_CONTENT_ON_REMOVAL")
        if (f and FLAG_SHOULD_SHOW_SYSTEM_DECORATIONS != 0) set.add("SHOULD_SHOW_SYSTEM_DECORATIONS")
        if (f and FLAG_TRUSTED != 0) set.add("TRUSTED")
        if (f and FLAG_OWN_DISPLAY_GROUP != 0) set.add("OWN_DISPLAY_GROUP")
        if (f and FLAG_ALWAYS_UNLOCKED != 0) set.add("ALWAYS_UNLOCKED")
        if (f and FLAG_TOUCH_FEEDBACK_DISABLED != 0) set.add("TOUCH_FEEDBACK_DISABLED")
        if (f and FLAG_OWN_FOCUS != 0) set.add("OWN_FOCUS")
        if (f and FLAG_DEVICE_DISPLAY_GROUP != 0) set.add("DEVICE_DISPLAY_GROUP")
        if (f and FLAG_STEAL_TOP_FOCUS_DISABLED != 0) set.add("STEAL_TOP_FOCUS_DISABLED")
        return set.joinToString("|")
    }

    private fun displayManager(): DisplayManager {
        val ctor = DisplayManager::class.java.getDeclaredConstructor(Context::class.java)
        ctor.isAccessible = true
        return ctor.newInstance(ctx)
    }

    /**
     * Prefer `createVirtualDisplay(VirtualDisplayConfig, …)`: it lets us set
     * `ignoreActivitySizeRestrictions` (SDK ≥ 36) so apps that declare a fixed
     * size/orientation still fill whatever size the Mac window is. Everything is
     * reflective so it compiles regardless of which constructors the build's SDK
     * exposes; any failure falls back to the classic call. The path is logged
     * with the display's group: a fallback that loses flags would show up here.
     */
    private fun createDisplay(w: Int, h: Int, dpi: Int, surface: Surface): Created {
        val config = buildConfig(w, h, dpi, surface)
        if (config != null) {
            val dm = displayManager()
            val method = dm.javaClass.methods.firstOrNull {
                it.name == "createVirtualDisplay" &&
                    it.parameterTypes.isNotEmpty() &&
                    it.parameterTypes[0].name == VIRTUAL_DISPLAY_CONFIG
            }
            if (method != null) {
                val args = arrayOfNulls<Any?>(method.parameterTypes.size)
                args[0] = config
                runCatching { method.invoke(dm, *args) as? VirtualDisplay }.getOrNull()?.let {
                    return Created(it, "VirtualDisplayConfig")
                }
            }
        }
        val classic = displayManager().createVirtualDisplay("pocketdeck-$stream", w, h, dpi, surface, flags())
        return Created(classic, "classic")
    }

    private class Created(val display: VirtualDisplay, val path: String)

    private fun buildConfig(w: Int, h: Int, dpi: Int, surface: Surface): Any? = runCatching {
        val builderClass = Class.forName("android.hardware.display.VirtualDisplayConfig\$Builder")
        val ctor = builderClass.getDeclaredConstructor(
            String::class.java,
            Int::class.javaPrimitiveType,
            Int::class.javaPrimitiveType,
            Int::class.javaPrimitiveType,
        )
        ctor.isAccessible = true
        val builder = ctor.newInstance("pocketdeck-$stream", w, h, dpi)
        builderClass.getMethod("setFlags", Int::class.javaPrimitiveType).invoke(builder, flags())
        builderClass.getMethod("setSurface", Surface::class.java).invoke(builder, surface)
        if (Build.VERSION.SDK_INT >= 36) {
            runCatching {
                builderClass.getMethod("setIgnoreActivitySizeRestrictions", Boolean::class.javaPrimitiveType)
                    .invoke(builder, true)
            }
        }
        builderClass.getMethod("build").invoke(builder)
    }.getOrNull()

    private fun hideIme(displayId: Int) {
        runCatching {
            val wm = Hidden.proxy("android.view.IWindowManager", "window") ?: return
            val m = Hidden.method(
                Hidden.iface("android.view.IWindowManager"),
                "setDisplayImePolicy",
                Hidden.T_INT,
                Hidden.T_INT,
            ) ?: return
            m.invoke(wm, displayId, IME_POLICY_HIDE)
        }
    }

    private fun startDrain(codec: MediaCodec) {
        drainThread = Thread({ drain(codec) }, "pocketdeck-drain-$stream").also { it.start() }
    }

    private fun drain(codec: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        while (!released && encoder === codec) {
            val idx = try {
                codec.dequeueOutputBuffer(info, 10_000)
            } catch (_: Throwable) {
                break
            }
            guard.poll(SystemClock.elapsedRealtime())?.let { nudgeRedraw(codec, it) }
            // Bitrate recovery rides on the drain loop: no extra timer, and it
            // only grows the bitrate when the stream is alive anyway.
            quality.maybeRecover(SystemClock.elapsedRealtime())?.let { bps ->
                log("stream $stream quality: bitrate recovered to ${mbps(bps)} (+10%)")
                applyBitrate()
            }
            if (idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                readCsd(codec.outputFormat)?.let { sink.onConfig(stream, Frames.CODEC_H264, width, height, it) }
                continue
            }
            if (idx < 0) continue
            try {
                val buf = codec.getOutputBuffer(idx)
                if (buf != null && info.size > 0 && (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
                    if (encoder !== codec) {
                        // Switched away mid-buffer: its size is no longer the stream's.
                    } else if (dropForFps(info.presentationTimeUs)) {
                        // Above the fps cap: never queued, so the socket sees less.
                    } else {
                        buf.position(info.offset)
                        buf.limit(info.offset + info.size)
                        val data = ByteArray(info.size)
                        buf.get(data)
                        val key = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
                        sink.onFrame(stream, info.presentationTimeUs, key, data)
                        guard.onFrame(SystemClock.elapsedRealtime())?.let {
                            log("stream $stream first frame ${it}ms after the encoder attached (nudges=${guard.nudgeCount})")
                        }
                    }
                }
            } catch (_: Throwable) {
            } finally {
                runCatching { codec.releaseOutputBuffer(idx, false) }
            }
        }
    }

    /** @return true when the frame is above the fps cap and must not be queued. */
    private fun dropForFps(ptsUs: Long): Boolean {
        val cap = maxFps ?: return false
        val previous = lastForwardedUs
        if (previous < 0 || ptsUs <= previous) { // fresh stream or a restarted pts base
            lastForwardedUs = ptsUs
            return false
        }
        if (ptsUs - previous < 1_000_000L / cap) return true
        lastForwardedUs = ptsUs
        return false
    }

    /** Applies the current bitrate through `setParameters`; logs each change once. */
    private fun applyBitrate() {
        val bps = quality.bitrate
        if (bps == appliedBitrate) return
        val codec = encoder
        val ok = codec != null && runCatching {
            val params = Bundle()
            params.putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, bps)
            codec.setParameters(params)
            true
        }.getOrDefault(false)
        appliedBitrate = bps
        log("stream $stream bitrate ${mbps(bps)}${if (ok) " (live)" else " (encoder not running)"}")
    }

    private fun mbps(bps: Int): String = "%.1f Mbps".format(bps / 1_000_000.0)

    private fun readCsd(format: MediaFormat): ByteArray? {
        val csd0 = runCatching { format.getByteBuffer("csd-0") }.getOrNull() ?: return null
        val out = ByteArrayOutputStream()
        out.write(dupBytes(csd0))
        runCatching { format.getByteBuffer("csd-1") }.getOrNull()?.let { out.write(dupBytes(it)) }
        return out.toByteArray()
    }

    private fun dupBytes(buf: ByteBuffer): ByteArray {
        val dup = buf.duplicate()
        val bytes = ByteArray(dup.remaining())
        dup.get(bytes)
        return bytes
    }
}

/** Owns every [WindowStream] and exposes them to the session as a [DisplayLayer]. */
internal class AndroidDisplayLayer(
    private val ctx: Context,
    private val log: (String) -> Unit,
) : DisplayLayer {

    private val streams = HashMap<Int, WindowStream>()

    override fun open(stream: Int, w: Int, h: Int, dpi: Int, sink: VideoSink): Int = synchronized(streams) {
        streams.remove(stream)?.close()
        val ws = WindowStream(ctx, stream, sink, log)
        val id = ws.start(w, h, dpi)
        streams[stream] = ws
        id
    }

    override fun size(stream: Int): IntSize = synchronized(streams) {
        streams[stream]?.size ?: IntSize(0, 0)
    }

    override fun resize(stream: Int, w: Int, h: Int, dpi: Int) {
        synchronized(streams) { streams[stream] }?.resize(w, h, dpi)
    }

    override fun pause(stream: Int) {
        synchronized(streams) { streams[stream] }?.pause()
    }

    override fun resume(stream: Int) {
        synchronized(streams) { streams[stream] }?.resume()
    }

    override fun requestKeyframe(stream: Int) {
        synchronized(streams) { streams[stream] }?.requestKeyframe()
    }

    override fun setQuality(stream: Int, bitrate: Int?, maxFps: Int?) {
        synchronized(streams) { streams[stream] }?.setQuality(bitrate, maxFps)
    }

    override fun onBackpressure(stream: Int) {
        synchronized(streams) { streams[stream] }?.onBackpressure()
    }

    override fun close(stream: Int) {
        synchronized(streams) { streams.remove(stream) }?.close()
    }
}
