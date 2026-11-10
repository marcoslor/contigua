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
 * encoded output is pushed straight into the session's send queue. Started
 * with [startMirror] the display mirrors the phone's own screen instead
 * (docs/design/phone-mirror.md).
 */
internal class WindowStream(
    private val ctx: Context,
    val stream: Int,
    private val sink: VideoSink,
    private val log: (String) -> Unit,
    /** The codecs the Mac said it decodes; the arm's HEVC needs it. */
    private val macCodecs: () -> Set<VideoCodec> = { setOf(VideoCodec.Avc) },
) {

    private companion object {
        const val MIME = StreamFormat.MIME

        const val VIRTUAL_DISPLAY_CONFIG = "android.hardware.display.VirtualDisplayConfig"

        /** The process's one HEVC encoder state (WIN-59), probed at most once. */
        private val hevcState = HevcCodecState(::probeHevcEncoder)

        /** The one probe behind [hevcState]; its result outlives the codec. */
        private fun probeHevcEncoder(): HevcCodecState.Probe {
            val probe = runCatching { MediaCodec.createEncoderByType(VideoCodec.Hevc.mime) }
                .getOrNull() ?: return HevcCodecState.Probe.Missing
            return try {
                val info = probe.codecInfo
                val caps = runCatching {
                    info.getCapabilitiesForType(VideoCodec.Hevc.mime).videoCapabilities
                }.getOrNull()
                val hardware = runCatching {
                    EncoderHardware.isHardware(
                        name = info.name,
                        sdk = Build.VERSION.SDK_INT,
                        hardwareAccelerated = if (Build.VERSION.SDK_INT >= 29) {
                            info.isHardwareAccelerated
                        } else {
                            null
                        },
                    )
                }.getOrDefault(false)
                if (!hardware) {
                    HevcCodecState.Probe.Software
                } else {
                    HevcCodecState.Probe.Hardware { w, h ->
                        caps?.isSizeSupported(w, h) == true
                    }
                }
            } finally {
                runCatching { probe.release() }
            }
        }

        /** The encoder type's capabilities, probed once per process (see [probedCapabilities]). */
        @Volatile private var probed: MediaCodecInfo.VideoCapabilities? = null

        /**
         * The capabilities of the encoder every stream builds, from one probe
         * encoder created and released at once. A failed probe is tried again
         * on the next ask; the result is a plain object that outlives the codec.
         */
        fun probedCapabilities(): MediaCodecInfo.VideoCapabilities? {
            probed?.let { return it }
            val probe = runCatching { MediaCodec.createEncoderByType(MIME) }.getOrNull() ?: return null
            return try {
                runCatching { probe.codecInfo.getCapabilitiesForType(MIME).videoCapabilities }
                    .getOrNull()?.also { probed = it }
            } finally {
                runCatching { probe.release() }
            }
        }

        const val DEFAULT_DISPLAY = 0

        /** How often the mirror checks display 0 for a rotation or size change. */
        const val ROTATION_POLL_MS = 300L

        /** Bounded wait for a drain thread before its codec is stopped and released. */
        const val DRAIN_JOIN_MS = 250L

        /** How often the drain's freeze hook reads its debug property. */
        const val FREEZE_CHECK_MS = 500L

        /** T1: no new encoded picture for this long is a still stream. */
        const val REFINE_STILL_MS = 300L

        /** `debug.pocketdeck.swap_surfaces=1`: the old surface swaps, for A/B on a device. */
        const val SWAP_SURFACES = "debug.pocketdeck.swap_surfaces"

        /** `debug.pocketdeck.vd_panel_group=1`: the VD joins display 0's group (the One UI shape). */
        const val VD_PANEL_GROUP = "debug.pocketdeck.vd_panel_group"

        // The flags a window asks for live in WindowDisplayFlags (pure, pinned
        // by the JVM test). Deliberately absent from that set: the
        // system-decorations flag (bit 9) adds a SystemUI nav bar and poisons
        // One UI's back gesture, and the device display-group flag (bit 15) ties
        // the VD to the panel's power state and freezes it while the phone is
        // locked. Bit 15 exists only behind VD_PANEL_GROUP, which reproduces
        // that freeze on the emulator.
    }

    @Volatile private var vd: VirtualDisplay? = null
    @Volatile private var encoder: MediaCodec? = null
    @Volatile private var drainThread: Thread? = null
    @Volatile private var width = 0
    @Volatile private var height = 0

    /** The stream's closed phases, encoder slots and input controls (`encoder:` log lines). */
    private val encoderLifecycle = EncoderLifecycle(stream) { log(it) }

    private val released: Boolean get() = encoderLifecycle.state.released

    private val paused: Boolean get() = encoderLifecycle.state.paused

    private val encoderSuspended: Boolean get() = encoderLifecycle.state.suspended

    /** The last build's fitted size, for the sequencer's `prepare` answer. */
    private var builtSize: IntSize? = null

    /** Set by an `Attach`/`Swap` action so `attachPrepared` can answer the sequencer. */
    private var attachedInPlan = false

    /** The last display's creation path and requested rate, for the open's log line. */
    private var lastDisplayPath = ""
    private var lastDisplayRate: Float? = null

    /** Where the picture sits in the frame of the size above (window.content). */
    @Volatile private var picture = IntRect(0, 0, 0, 0)

    /** The density last asked for by the Mac; redraw nudges are offsets from it. */
    @Volatile private var baseDpi = 0

    /** An encoder built for the next attach, and the one it replaces. */
    private var prepared: Prepared? = null
    private var previous: MediaCodec? = null
    private var limits = EncoderLimits()
    private var caps: MediaCodecInfo.VideoCapabilities? = null

    /** [started] is false for a codec configured for [persistent]: it starts when attached. */
    private class Prepared(
        val codec: MediaCodec,
        val surface: Surface,
        val kind: VideoCodec,
        val started: Boolean = true,
    )

    /** The codec the current encoder runs; set when its drain starts. */
    @Volatile private var videoCodec = VideoCodec.Avc

    /**
     * The display's one input surface for its whole life (app windows only).
     * Every encoder attaches to it in turn, so the display's surface never
     * changes after creation. On the SM-S936B (Android 16) a
     * `VirtualDisplay.setSurface` leaves SurfaceFlinger's re-created display
     * powered off until the next power change of its group: the stream stayed
     * black after a resize or a resume until the phone was woken by hand.
     * Null: a mirror, a refused persistent surface, or
     * `debug.pocketdeck.swap_surfaces=1` — the encoder's own surface is swapped
     * in as before.
     */
    @Volatile private var persistent: Surface? = null

    /** The codec config last sent, re-sent on resume (the encoder kept running). */
    @Volatile private var lastCsd: ByteArray? = null

    private val guard = RedrawGuard()

    /**
     * The picture's heartbeat: a live stream may not stay silent for a second
     * (PHONE-21). The drain thread feeds it the encoder's clock and performs
     * the one action it returns. Its own lock, never `this`: a resize can hold
     * the stream's monitor for the whole encoder rebuild.
     */
    private var heartbeatModel = IdleFrameWatchdogModel()
    private val heartbeatLock = Any()

    /** What the display already shows, so a repeat asks for nothing. */
    private val ledger = ResizeLedger()

    private val sequencer = ResizeSequencer(object : ResizeSteps {
        override fun fit(w: Int, h: Int): IntSize = fitToEncoder(w, h)
        override fun prepare(size: IntSize): IntSize? = buildPrepared(size)
        override fun resizeDisplay(size: IntSize, dpi: Int) = applyDisplaySize(size, dpi)
        override fun attachPrepared(): Boolean = attachInPrepared()
        override fun releasePrevious() {
            releasePreviousCodec()
        }
    })

    /** Live bitrate policy: computed target or `window.quality`, drops and recovery. */
    private val quality = QualityAdaptation()

    /**
     * PATH-47/48: one machine for the early delay signal and the rung. The
     * rung it reports is the one the encoder runs at; a rebuild is asynchronous
     * (the frame writer must not wait a second for a resize), and a `kept`
     * answer returns the rung to where it was.
     */
    private val rateControl = RateControl()
    private val rateLock = Any()
    private var rateState = RateControlState()
    private val rungLock = Any()
    private var pendingRung: RateControlAction.Scale? = null
    private var rungThread: Thread? = null

    /**
     * The inner loop: the codec key follows the believed bitrate through the
     * encoder's measured gain, so a VBR encoder cannot outrun the link while
     * the outer loop is already at its floor.
     */
    private val correction = EncoderCorrection()

    /** The encoder's delta output, measured on this stream's drain thread. */
    private val encoderOutput = GoodputMeter(
        windowUs = 1_000_000L,
        minSpanUs = 500_000L,
        sampleGapUs = 1_000_000L,
    )

    private var lastEncoderSampleAtMs = 0L
    @Volatile private var lastCorrectionState = EncoderCorrection.State.Unmeasured

    /** A fresh encoder's IDR can answer the Mac's first key request. */
    private val keyGate = KeyRequestGate()

    /** `stream.stats` counters (ISS-40); rings fill only while the Mac asked. */
    private val stats = StreamStats(
        stream = stream,
        log = log,
        clockMs = { SystemClock.elapsedRealtime() },
    )
    @Volatile private var statsWanted = false

    /** When this stream's encoder first existed; the closing line's `secs`. */
    private val startedAtMs = SystemClock.elapsedRealtime()

    /** ISS-40's one-off QP sample after this stream's 30th output buffer. */
    private val qpSample = QpSampleProbe()

    /** The codec supports per-output-buffer statistics (KEY_VIDEO_QP_AVERAGE). */
    private var encodingStatistics = false

    /** The switches this encoder was configured with (read once per configure). */
    @Volatile private var strategy = StreamStrategy.DEFAULT

    /** T1: still refinement's machine, and the last time a *new* picture was encoded. */
    private val refineLock = Any()
    @Volatile private var refineModel = RefineModel()
    @Volatile private var lastDistinctMs = 0L
    private var lastOutputSize = -1

    /** Explicit `window.quality` bitrate; null means "computed from the pixels". */
    @Volatile private var requestedBitrate: Int? = null

    /** `window.quality` fps cap; frames above it are dropped before queueing. */
    @Volatile private var maxFps: Int? = null

    /** Encoder pts of the last frame actually queued, for the fps cap. */
    @Volatile private var lastForwardedUs = -1L

    private var appliedBitrate = 0

    @Volatile private var displayIdValue = -1

    /** Mirror only: display 0's last seen size and the Mac's window box. */
    @Volatile private var mirrorScreen: IntSize? = null
    @Volatile private var mirrorBox = IntSize(0, 0)
    @Volatile private var rotationThread: Thread? = null

    val displayId: Int get() = displayIdValue
    val size: IntSize get() = IntSize(width, height)

    /** What normalized input maps over: display 0 itself for a mirror. */
    val inputSize: IntSize get() = mirrorScreen ?: size

    /**
     * Mirrors display 0 at its aspect inside w×h. The VD is display 0's mirror,
     * so nothing is launched on it and the phone's screen is left as it is.
     */
    fun startMirror(w: Int, h: Int): IntSize {
        val screen = checkNotNull(DisplayProbe.logicalSize(DEFAULT_DISPLAY)) { "display 0 size unknown" }
        mirrorScreen = screen
        mirrorBox = MirrorFit.turnBox(IntSize(w, h), screen)
        performLifecycle(
            encoderLifecycle.dispatch(
                EncoderEvent.Open(DisplayPhase.Mirror, mirrorFrame(mirrorBox, screen)),
            ),
        )
        checkNotNull(vd) { "no encoder for mirror" }
        rotationThread = Thread({ watchRotation() }, "pocketdeck-mirror-$stream").also { it.start() }
        log("stream $stream mirror of display 0 (${screen.w}x${screen.h}) at ${width}x$height")
        ledger.remember(ResizeRequest(mirrorBox.w, mirrorBox.h, baseDpi))
        return IntSize(width, height)
    }

    /**
     * `DisplayManager.createVirtualDisplay(name, w, h, displayIdToMirror, surface)`,
     * hidden, Android 14+. Shell holds CAPTURE_VIDEO_OUTPUT, which it needs.
     */
    private fun createMirror(w: Int, h: Int, surface: Surface): VirtualDisplay {
        val method = DisplayManager::class.java.getMethod(
            "createVirtualDisplay",
            String::class.java,
            Int::class.javaPrimitiveType,
            Int::class.javaPrimitiveType,
            Int::class.javaPrimitiveType,
            Surface::class.java,
        )
        return method.invoke(null, "pocketdeck-mirror-$stream", w, h, DEFAULT_DISPLAY, surface) as VirtualDisplay
    }

    /** Follows display 0's rotation: the stream turns with it and a new VIDEO_CONFIG goes out. */
    private fun watchRotation() {
        while (!released) {
            try {
                Thread.sleep(ROTATION_POLL_MS)
            } catch (_: InterruptedException) {
                return
            }
            val now = DisplayProbe.logicalSize(DEFAULT_DISPLAY) ?: continue
            if (now == mirrorScreen) continue
            log("stream $stream: display 0 is now ${now.w}x${now.h}")
            synchronized(this) {
                if (released) return
                mirrorScreen = now
                mirrorBox = MirrorFit.turnBox(mirrorBox, now)
                resizeLocked(mirrorBox.w, mirrorBox.h, baseDpi)
                ledger.remember(ResizeRequest(mirrorBox.w, mirrorBox.h, baseDpi))
            }
        }
    }

    fun start(w: Int, h: Int, dpi: Int): Int {
        baseDpi = dpi
        performLifecycle(
            encoderLifecycle.dispatch(EncoderEvent.Open(DisplayPhase.Virtual, IntSize(w, h))),
        )
        checkNotNull(vd) { "no encoder for ${w}x$h" }
        hideIme(displayIdValue)
        val requested = flags()
        log("stream $stream vd=$displayIdValue ${width}x$height dpi=$dpi path=$lastDisplayPath" +
            (DisplayRate.displayToken(lastDisplayRate)?.let { " $it" } ?: ""))
        log("stream $stream vd=$displayIdValue requested flags=0x${requested.toString(16)} (${virtualFlagNames(requested)})")
        log("stream $stream vd=$displayIdValue ${DisplayProbe.describe(displayIdValue)}")
        // What a repeat is measured against is the request as it was asked, not
        // the size the encoder fitted it to.
        ledger.remember(ResizeRequest(w, h, baseDpi))
        return displayIdValue
    }

    @Synchronized
    fun resize(w: Int, h: Int, dpi: Int): ResizeOutcome {
        if (released) return ResizeOutcome.KEPT
        val screen = mirrorScreen
        val box: IntSize
        val effectiveDpi: Int
        if (screen == null) {
            box = IntSize(w, h)
            effectiveDpi = dpi
        } else {
            box = MirrorFit.turnBox(IntSize(w, h), screen)
            effectiveDpi = baseDpi
        }
        val request = ResizeRequest(box.w, box.h, effectiveDpi)
        when (ledger.need(request)) {
            ResizeNeed.SAME -> {
                log("stream $stream resize ${box.w}x${box.h} dpi=$effectiveDpi is already shown")
                return ResizeOutcome.SAME
            }
            ResizeNeed.DENSITY -> {
                // Same pixels, new density: no encoder rebuild, so no re-attach
                // and no lost frame (the 10-27 burst).
                val scaled = ladderBox(request, rateSnapshot().rung)
                sequencer.densityOnly(IntSize(width, height), scaled.third)
                ledger.settle(request, ResizeOutcome.DENSITY)
                log("stream $stream density ${width}x$height dpi=$effectiveDpi (encoder kept)")
                return ResizeOutcome.DENSITY
            }
            ResizeNeed.FULL -> Unit
        }
        val scaled = ladderBox(request, rateSnapshot().rung)
        val outcome = resizeLocked(scaled.first, scaled.second, scaled.third)
        // The asked box, not the fitted one: a repeat of the same request is a
        // no-op even when the encoder shrank it (docs/PROTOCOL.md `window.resize`).
        ledger.settle(request, outcome)
        return outcome
    }

    private fun resizeLocked(boxW: Int, boxH: Int, dpi: Int): ResizeOutcome {
        // With one surface for life the encoder keeps running while paused, so
        // a resize then is a normal one.
        val result = sequencer.resize(boxW, boxH, dpi, paused && persistent == null, IntSize(width, height))
        when (result.outcome) {
            ResizeSequencer.Outcome.RESIZED, ResizeSequencer.Outcome.DISPLAY_ONLY ->
                log("stream $stream resize ${result.size.w}x${result.size.h} dpi=$dpi" +
                    if (result.size.w != boxW || result.size.h != boxH) " (asked ${boxW}x$boxH)" else "")
            ResizeSequencer.Outcome.KEPT ->
                log("stream $stream resize ${boxW}x$boxH refused by the encoder; staying at ${result.size.w}x${result.size.h}")
            ResizeSequencer.Outcome.DENSITY_ONLY -> Unit
        }
        return when (result.outcome) {
            ResizeSequencer.Outcome.RESIZED, ResizeSequencer.Outcome.DISPLAY_ONLY -> ResizeOutcome.RESIZED
            ResizeSequencer.Outcome.KEPT -> ResizeOutcome.KEPT
            ResizeSequencer.Outcome.DENSITY_ONLY -> ResizeOutcome.DENSITY
        }
    }

    /**
     * Stops sending frames. With one surface for life the display keeps its
     * surface and the encoder keeps running (the drain drops its output), so
     * a resume never re-points the display; the display stops drawing on its
     * own when its group sleeps (the session releases its wake lock).
     */
    @Synchronized
    fun pause() {
        if (paused || released) return
        heartbeat(IdleFrameWatchdogEvent.Pause)
        performLifecycle(encoderLifecycle.dispatch(EncoderEvent.Pause))
    }

    @Synchronized
    fun resume() {
        if (!paused || released) return
        lastDistinctMs = SystemClock.elapsedRealtime()
        heartbeat(IdleFrameWatchdogEvent.Resume(SystemClock.elapsedRealtime()))
        performLifecycle(encoderLifecycle.dispatch(EncoderEvent.Resume))
    }

    /** The drop rule's request: the IDR before the dropped deltas answers nothing. */
    fun requestKeyframeAfterDrop() {
        keyGate.onDeltasDropped()
        requestKeyframe()
    }

    fun requestKeyframe() {
        stats.onKeyframeRequested()
        val codec = encoder ?: return
        when (val request = keyGate.onRequest(SystemClock.elapsedRealtime())) {
            is KeyRequestGate.KeyRequest.Satisfied ->
                log("stream $stream key request: satisfied by idr ${request.idrAgoMs} ms ago")
            KeyRequestGate.KeyRequest.Send -> requestSyncFrame(codec)
        }
    }

    /**
     * Q1: the send queue passed its budget, so stop taking input at the
     * encoder's surface. The encoder keeps running and the reference chain
     * stays intact; the display keeps composing and the next frame after a
     * resume is a tiny delta, not a keyframe.
     */
    fun setEncoderSuspend(suspended: Boolean) {
        performLifecycle(encoderLifecycle.dispatch(EncoderEvent.Suspend(suspended)))
    }

    /** `PARAMETER_KEY_SUSPEND` 1/0; false when the codec has no such control. */
    private fun applySuspend(codec: MediaCodec, suspended: Boolean): Boolean = runCatching {
        val params = Bundle()
        params.putInt(MediaCodec.PARAMETER_KEY_SUSPEND, if (suspended) 1 else 0)
        codec.setParameters(params)
        true
    }.getOrDefault(false)

    /** `stream.stats` on/off: only the ring buffers change, never the stream. */
    fun setStatsWanted(on: Boolean) {
        statsWanted = on
    }

    /** The counters since the last call (the session resets each 2 s window). */
    fun statsSnapshot(reset: Boolean): EncoderStats = stats.snapshot(reset)

    /** The stream's lifetime line, logged once by the session when it closes. */
    fun totalsLine(): String =
        stats.totalsLine(stream, (SystemClock.elapsedRealtime() - startedAtMs) / 1000.0)

    /** `setParameters(PARAMETER_KEY_REQUEST_SYNC_FRAME)` on a known encoder. */
    private fun requestSyncFrame(codec: MediaCodec) {
        runCatching {
            val params = Bundle()
            params.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            codec.setParameters(params)
        }
    }

    /**
     * Feeds the picture's heartbeat and performs its one action. Runs on the
     * drain thread: a `still` therefore proves that loop and the session alive.
     */
    private fun heartbeat(event: IdleFrameWatchdogEvent) {
        synchronized(heartbeatLock) {
            val before = heartbeatModel
            val step = idleFrameWatchdogTransition(heartbeatModel, event)
            heartbeatModel = step.model
            for (action in step.actions) {
                when (action) {
                    IdleFrameWatchdogAction.SendStill -> {
                        sink.onStill(stream)
                        log("stream $stream heartbeat: still ${step.model.stills}")
                    }
                }
            }
            if (step.model.state != before.state) {
                log("stream $stream heartbeat: ${before.state.wire} --${event.wire}--> ${step.model.state.wire}")
            }
        }
    }

    /** The per-stream still count, a fact only (`window.still` messages sent). */
    private fun logStillCount() {
        synchronized(heartbeatLock) {
            log("stream $stream heartbeat: stills=${heartbeatModel.stills}")
        }
    }

    /** Runtime quality: bitrate target in bps and/or an fps cap (both optional). */
    fun setQuality(bitrate: Int?, maxFps: Int?) {
        var explicit = false
        // A Mac may repeat a value; only a real change is logged and applied.
        if (maxFps != null && maxFps > 0 && maxFps != this.maxFps) {
            this.maxFps = maxFps
            explicit = true
            log(
                "stream $stream quality: maxFps=$maxFps " +
                    "(encoder cap at the next configure; frames above it are dropped)",
            )
        }
        if (bitrate != null && bitrate > 0 && bitrate != requestedBitrate) {
            requestedBitrate = bitrate
            val target = quality.setTarget(bitrate)
            resetCorrection()
            explicit = true
            log("stream $stream quality: target bitrate ${mbps(target)} (${bitrate} bps requested)")
            applyBitrate()
        }
        // PATH-48: an explicit quality ends the pixel ladder; the person asked
        // for a bitrate/fps, so the stream goes back to the Mac's own pixels.
        if (explicit) cancelLadder()
    }

    /**
     * The session dropped delta frames for this stream: take 25% off the bitrate
     * (floor 1 Mbps). Recovery happens in the drain loop, 10% every 5 s without
     * a drop, up to the target. [measuredBps] is the writer's recent goodput; it
     * caps recovery at 85% of what the link actually carried, so a slow TCP
     * fallback cannot climb back to the target and refill the queue.
     */
    fun onBackpressure(measuredBps: Int? = null, encodedBps: Int? = null) {
        val now = SystemClock.elapsedRealtime()
        // The drop rule owns this episode: the early signal waits two seconds
        // before it may lower again, so the two loops cannot double-adapt.
        val drop = synchronized(rateLock) {
            val step = rateControl.step(rateState, RateControlEvent.Drop(now))
            rateState = step.state
            step
        }
        drop.line?.let { log("stream $stream $it") }
        // The key that produced the measured output is the one the codec ran
        // with; the quality drop below has not reached the codec yet.
        val keyBefore = appliedBitrate.takeIf { it > 0 } ?: encoderBitrate(quality.bitrate)
        val bps = quality.onDrop(now, measuredBps)
        if (encodedBps != null && encodedBps > 0) {
            // The queue's meter spans the key that was running; the next drain
            // sample comes from this stream's own delta meter.
            correction.sample(now, encodedBps, keyBefore)
        }
        if (bps != null) {
            log("stream $stream backpressure: bitrate -> ${mbps(bps)} (-25%, encoder ${mbps(encoderBitrate(bps))})")
        }
        if (measuredBps != null) {
            log("stream $stream quality: recovery cap ${mbps(quality.ceilingBps)} " +
                "(measured ${mbps(measuredBps)})")
        }
        logCorrectionState("drop")
        applyBitrate()
    }

    /**
     * PATH-47/48: the writer's queue-delay window and the link's newest deep
     * reading. The machine may lower the belief or choose a rung; the actions
     * run here and every phase/rung change is logged.
     */
    fun onQueueDelay(nowMs: Long, delayP95Us: Long, delayP50Us: Long, linkBps: Int?) {
        if (!quality.enabled || released) return
        val step = synchronized(rateLock) {
            val next = rateControl.step(
                rateState,
                RateControlEvent.Window(
                    nowMs = nowMs,
                    delayP95Us = delayP95Us,
                    delayP50Us = delayP50Us,
                    linkBps = linkBps,
                    believedBps = quality.bitrate,
                    // A mirror's display is the phone's own screen: its size is
                    // not the window's to step. The bitrate signal still applies.
                    atFloor = quality.atFloor && mirrorScreen == null,
                    early = StreamDebug.rateControlEnabled(),
                    ladder = StreamDebug.ladderEnabled(),
                ),
            )
            rateState = next.state
            next
        }
        step.line?.let { log("stream $stream $it") }
        when (val action = step.action) {
            is RateControlAction.LowerTo -> {
                val moved = quality.lowerTo(nowMs, action.bps)
                if (moved != null) {
                    log("stream $stream ratectl: target ${mbps(moved)} (before the drop rule)")
                    applyBitrate()
                }
            }
            is RateControlAction.Scale -> requestRung(action)
            RateControlAction.None -> Unit
        }
    }

    /** PATH-48: an explicit quality or a disabled ladder ends the rung. */
    private fun cancelLadder() {
        val step = synchronized(rateLock) {
            if (rateState.rung == LadderRung.Full) return
            val next = rateControl.step(rateState, RateControlEvent.Quality)
            rateState = next.state
            next
        }
        step.line?.let { log("stream $stream $it") }
        (step.action as? RateControlAction.Scale)?.let { requestRung(it) }
    }

    /** The belief and rung the encoder should be built with. */
    private fun rateSnapshot(): RateControlState = synchronized(rateLock) { rateState }

    /**
     * A ladder step rebuilds the encoder, which can take a second: it runs on
     * its own thread, and a newer rung replaces a queued one so the last word
     * wins.
     */
    private fun requestRung(step: RateControlAction.Scale) {
        synchronized(rungLock) {
            pendingRung = step
            if (rungThread?.isAlive == true) return
            rungThread = Thread({
                while (true) {
                    val next = synchronized(rungLock) {
                        pendingRung.also { pendingRung = null }
                    } ?: break
                    applyRung(next)
                }
            }, "pocketdeck-ladder-$stream").also { it.start() }
        }
    }

    /**
     * Rebuilds at the rung's share of the Mac's asked box through the existing
     * resize sequencer (`Prepare`/`Attach`), so a failed swap answers `kept`
     * (WIN-6) and the rung returns to where it was. The ledger keeps the Mac's
     * request: a repeat of it is still a no-op and the next step scales the
     * same box again.
     */
    private fun applyRung(step: RateControlAction.Scale) {
        var box: ResizeRequest? = null
        var outcome = ResizeOutcome.KEPT
        synchronized(this) {
            if (!released && mirrorScreen == null) {
                val asked = ledger.requested()
                if (asked != null) {
                    box = asked
                    val scaled = ladderBox(asked, step.to)
                    outcome = resizeLocked(scaled.first, scaled.second, scaled.third)
                }
            }
        }
        val asked = box
        if (asked == null || outcome == ResizeOutcome.KEPT) {
            val failed = synchronized(rateLock) {
                val next = rateControl.step(
                    rateState,
                    RateControlEvent.RungFailed(step.from, step.to, SystemClock.elapsedRealtime()),
                )
                rateState = next.state
                next
            }
            failed.line?.let { log("stream $stream $it") }
            log("stream $stream ladder: ${step.from.wire} --kept--> ${step.from.wire}" +
                (asked?.let { " (asked ${it.w}x${it.h})" } ?: " (no asked box)"))
            return
        }
        log("stream $stream ladder: ${step.from.wire} --step--> ${step.to.wire}" +
            " pixels=${width}x$height dpi=$baseDpi (asked ${asked.w}x${asked.h})" +
            " base ${step.baseBps / 1000} kbps")
        // The failure above can race a newer step; the success needs no event:
        // the rung the machine already holds is the one just built.
    }

    /** The Mac's asked box at [rung]'s pixel and density scale. */
    private fun ladderBox(asked: ResizeRequest, rung: LadderRung): Triple<Int, Int, Int> {
        val scale = rung.scale
        return Triple(
            maxOf(16, (asked.w * scale).toInt()),
            maxOf(16, (asked.h * scale).toInt()),
            maxOf(1, (asked.dpi * scale).toInt()),
        )
    }

    /** The rung's bitrate ceiling: the floor the ladder engaged at, scaled by pixels. */
    private fun ladderTargetFor(computedBps: Int, state: RateControlState): Int {
        if (state.rung == LadderRung.Full || state.baseBps <= 0) return computedBps
        val scaled = (state.baseBps.toLong() * state.rung.scale * state.rung.scale).toInt()
        return minOf(computedBps, maxOf(RateControl.MIN_BPS, scaled))
    }

    @Synchronized
    fun close() {
        if (released) return
        val actions = encoderLifecycle.dispatch(EncoderEvent.Release)
        heartbeat(IdleFrameWatchdogEvent.Close)
        refine(RefineEvent.Close, SystemClock.elapsedRealtime())
        logStillCount()
        rotationThread?.interrupt()
        rotationThread = null
        synchronized(rungLock) {
            pendingRung = null
            rungThread = null
        }
        performLifecycle(actions)
    }

    // ------------------------------------------------------------------

    /**
     * Builds the next encoder (configured, input surface made, started) at the
     * size the codec will actually take. Leaves the current stream untouched.
     *
     * The strategy is read once per configure here, and the codec choice is the
     * pure decision of WIN-59: HEVC is the default, but a Mac that cannot
     * decode it or an encoder that cannot take the size falls back to H.264
     * with one reason line. A HEVC encoder that fails to build is retired for
     * the process and the same stream is rebuilt with H.264 once.
     */
    private fun prepareEncoder(want: IntSize): IntSize? {
        val (w, h) = want
        val strategy = StreamStrategy.read()
        this.strategy = strategy
        val chosenSize = if (mirrorScreen != null) want else fitToEncoder(w, h)
        val ready = CodecPreparation.prepare(
            strategy = strategy,
            macCodecs = macCodecs(),
            size = chosenSize,
            state = hevcState,
            label = "${w}x$h",
            create = { kind -> MediaCodec.createEncoderByType(kind.mime) },
            build = { codec, kind ->
                learnLimits(codec, kind)
                configure(codec, chosenSize.w, chosenSize.h, strategy, kind)
                val shared = persistent
                if (shared != null) {
                    // Started when attached: one codec at a time on the surface.
                    Prepared(codec, shared, kind, started = false)
                } else {
                    val surface = codec.createInputSurface()
                    codec.start()
                    Prepared(codec, surface, kind)
                }
            },
            release = { runCatching { it.release() } },
            log = { log("stream $stream $it") },
            stateLog = log,
        ) ?: return null
        width = chosenSize.w
        height = chosenSize.h
        picture = pictureOf(chosenSize)
        prepared = ready.built
        return chosenSize
    }

    private fun learnLimits(codec: MediaCodec, kind: VideoCodec) {
        val found = runCatching {
            codec.codecInfo.getCapabilitiesForType(kind.mime).videoCapabilities
        }.getOrNull() ?: return
        adoptLimits(found)
    }

    private fun adoptLimits(found: MediaCodecInfo.VideoCapabilities) {
        caps = found
        limits = EncoderLimits(
            maxW = found.supportedWidths.upper,
            maxH = found.supportedHeights.upper,
            widthAlign = found.widthAlignment,
            heightAlign = found.heightAlignment,
        )
    }

    /**
     * The codec's limits before this stream's encoder is built: a mirror's
     * frame and an app window's first size are fitted with them, so the first
     * frame already has the codec's own alignment, not the 16 px default
     * (ISS-39). The probe runs once per process.
     */
    private fun ensureLimits() {
        if (caps != null) return
        val found = probedCapabilities() ?: return
        adoptLimits(found)
    }

    private fun fitToEncoder(w: Int, h: Int): IntSize {
        val screen = mirrorScreen
        if (screen != null) return mirrorFrame(IntSize(w, h), screen)
        ensureLimits()
        val known = caps
        return EncoderSizes.fit(w, h, limits) { sw, sh -> known?.isSizeSupported(sw, sh) ?: true }
    }

    /** A mirror's frame for the Mac's box: the nearest one the codec takes at its own alignment. */
    private fun mirrorFrame(box: IntSize, screen: IntSize): IntSize {
        ensureLimits()
        val known = caps
        return MirrorFrame.pick(box, screen, IntSize(limits.widthAlign, limits.heightAlign),
            limits.maxW, limits.maxH) { sw, sh -> known?.isSizeSupported(sw, sh) ?: true }
    }

    /** Where the picture sits in a frame of [size]: the whole frame, or the screen's rect for a mirror. */
    private fun pictureOf(size: IntSize): IntRect =
        mirrorScreen?.let { MirrorFrame.contentIn(size, it) } ?: IntRect(0, 0, size.w, size.h)

    private fun applyDisplaySize(size: IntSize, dpi: Int) {
        width = size.w
        height = size.h
        baseDpi = dpi
        // A mirror's projection is fixed when it is created; it is rebuilt at
        // the new size when the prepared encoder is attached.
        if (mirrorScreen != null) return
        runCatching { vd?.resize(size.w, size.h, dpi) }
            .onFailure { log("stream $stream: VirtualDisplay.resize failed: ${it.message}") }
    }

    /** The sequencer's `prepare`: the machine decides whether a build is legal here. */
    private fun buildPrepared(size: IntSize): IntSize? {
        builtSize = null
        performLifecycle(encoderLifecycle.dispatch(EncoderEvent.Prepare(size)))
        return builtSize
    }

    /** The sequencer's `attachPrepared`: false when no encoder ended attached. */
    private fun attachInPrepared(): Boolean {
        if (prepared == null) return false
        attachedInPlan = false
        performLifecycle(encoderLifecycle.dispatch(EncoderEvent.Attach))
        return attachedInPlan
    }

    /** The sequencer's `releasePrevious`: the swap's old codec goes now. */
    private fun releasePreviousCodec() {
        performLifecycle(encoderLifecycle.dispatch(EncoderEvent.ReleasePrevious))
    }

    /**
     * Performs the machine's actions in order; an action that reports an outcome
     * dispatches it before the next action, so a refused start's rebuild runs
     * inside the same plan.
     */
    private fun performLifecycle(actions: List<EncoderAction>) {
        val pending = ArrayDeque<EncoderAction>()
        for (action in actions) pending.addLast(action)
        while (pending.isNotEmpty()) {
            val outcome = performLifecycleAction(pending.removeFirst()) ?: continue
            val next = encoderLifecycle.dispatch(outcome)
            next.asReversed().forEach { pending.addFirst(it) }
        }
    }

    private fun performLifecycleAction(action: EncoderAction): EncoderEvent? = when (action) {
        EncoderAction.CreateSurface -> {
            persistent = createPersistentSurface()
            EncoderEvent.SurfaceReady(persistent != null)
        }
        is EncoderAction.Build -> {
            builtSize = prepareEncoder(action.size)
            val next = prepared
            if (builtSize == null || next == null) {
                EncoderEvent.BuildFailed
            } else {
                EncoderEvent.Built(next.started, action.attach)
            }
        }
        EncoderAction.StartPrepared -> {
            val next = prepared
            if (next != null && startOnPersistent(next.codec, next.kind)) {
                EncoderEvent.Started
            } else {
                EncoderEvent.StartRefused(IntSize(width, height))
            }
        }
        EncoderAction.DropSurface -> {
            dropPersistent()
            null
        }
        is EncoderAction.CreateDisplay -> {
            val next = prepared ?: return null
            if (action.display == DisplayPhase.Mirror) {
                vd = createMirror(width, height, next.surface)
                displayIdValue = DEFAULT_DISPLAY
                lastDisplayPath = "mirror"
                lastDisplayRate = null
            } else {
                val created = createDisplay(width, height, baseDpi, next.surface)
                vd = created.display
                displayIdValue = created.display.display.displayId
                lastDisplayPath = created.path
                lastDisplayRate = created.rate
            }
            EncoderEvent.Created
        }
        EncoderAction.AttachFresh -> {
            val next = prepared ?: return null
            prepared = null
            encoder = next.codec
            EncoderEvent.Installed(startDrain(next.codec, next.kind))
        }
        is EncoderAction.Attach -> {
            val next = prepared ?: return null
            prepared = null
            if (!action.persistent) pointDisplayAt(next.surface)
            guard.onAttached(SystemClock.elapsedRealtime())
            encoder = next.codec
            attachedInPlan = true
            EncoderEvent.Installed(startDrain(next.codec, next.kind))
        }
        EncoderAction.Swap -> {
            val next = prepared ?: return null
            prepared = null
            val old = encoder
            previous = old
            encoder = next.codec
            pointDisplayAt(next.surface)
            guard.onAttached(SystemClock.elapsedRealtime())
            attachedInPlan = true
            EncoderEvent.Swapped(startDrain(next.codec, next.kind), previous = old != null)
        }
        EncoderAction.DetachOld -> {
            // The surface takes one codec at a time: the old one goes first.
            val old = encoder
            encoder = null
            if (old != null) {
                waitForDrain()
                runCatching { old.stop() }
                runCatching { old.release() }
            }
            null
        }
        EncoderAction.Detach -> {
            detachEncoder()
            null
        }
        EncoderAction.ReleasePrepared -> {
            runCatching { prepared?.codec?.release() }
            prepared = null
            null
        }
        EncoderAction.ReleasePreviousCodec -> {
            releasePreviousEncoder()
            null
        }
        EncoderAction.ReleaseDisplay -> {
            runCatching { vd?.release() }
            vd = null
            displayIdValue = -1
            null
        }
        EncoderAction.ReleaseSurface -> {
            runCatching { persistent?.release() }
            persistent = null
            null
        }
        EncoderAction.ResendConfig -> {
            lastCsd?.let { sink.onConfig(stream, videoCodec.wire, width, height, it, picture) }
            null
        }
        EncoderAction.RequestKey -> {
            requestKeyframe()
            null
        }
        EncoderAction.Nudge -> {
            // The app may have nothing new to draw: the redraw guard nudges it.
            guard.onAttached(SystemClock.elapsedRealtime())
            null
        }
        EncoderAction.Rebuild -> {
            val result = sequencer.resume(width, height, baseDpi, IntSize(width, height))
            if (result.outcome == ResizeSequencer.Outcome.KEPT) {
                log("stream $stream resume: no encoder for ${width}x$height")
            }
            null
        }
        is EncoderAction.ApplySuspend -> {
            val codec = encoder ?: return null
            val ok = applySuspend(codec, action.suspended)
            if (!ok) {
                log("stream $stream overflow: suspend ${if (action.suspended) "on" else "off"} refused by the encoder")
            } else {
                val now = SystemClock.elapsedRealtime()
                if (action.suspended) {
                    stats.onSuspendStart(now)
                    refine(RefineEvent.Suspend, now)
                } else {
                    stats.onSuspendEnd(now)
                    lastDistinctMs = now
                }
                log("stream $stream overflow: ${if (action.suspended) "suspended" else "resumed"}")
            }
            EncoderEvent.SuspendApplied(action.suspended, ok)
        }
    }

    /** A mirror's projection is fixed at creation: point it by rebuilding it; else setSurface. */
    private fun pointDisplayAt(surface: Surface) {
        if (mirrorScreen != null) {
            runCatching { vd?.release() }
            vd = runCatching { createMirror(width, height, surface) }
                .onFailure { log("stream $stream: mirror rebuild failed: ${it.message}") }.getOrNull()
        } else {
            runCatching { vd?.setSurface(surface) }
                .onFailure { log("stream $stream: VirtualDisplay.setSurface failed: ${it.message}") }
        }
    }

    private fun createPersistentSurface(): Surface? {
        if (Hidden.systemProperty(SWAP_SURFACES) == "1") {
            log("stream $stream: $SWAP_SURFACES=1, swapping encoder surfaces")
            return null
        }
        return runCatching { MediaCodec.createPersistentInputSurface() }
            .onFailure { log("stream $stream: no persistent input surface (${it.message}); swapping encoder surfaces") }
            .getOrNull()
    }

    /** Attaches a configured codec to [persistent] and starts it; false if the codec refuses. */
    private fun startOnPersistent(codec: MediaCodec, kind: VideoCodec): Boolean {
        val shared = persistent ?: return false
        return try {
            codec.setInputSurface(shared)
            codec.start()
            true
        } catch (e: Throwable) {
            if (kind == VideoCodec.Hevc) {
                // The probe said HEVC works; this start says no. Retire it and
                // let the rebuild below choose H.264, which writes the reason.
                hevcState.configureFailed(log)
            }
            log("stream $stream: encoder refused the persistent input surface (${e.message}); swapping encoder surfaces")
            runCatching { codec.release() }
            false
        }
    }

    /** Back to swapping the encoder's own surface in (the display keeps working). */
    private fun dropPersistent() {
        val shared = persistent ?: return
        persistent = null
        runCatching { shared.release() }
    }

    private fun releasePreviousEncoder() {
        val codec = previous ?: return
        previous = null
        // The old codec's drain thread is not `drainThread` any more (the swap
        // named the new one); it exits on `encoder === codec` by itself.
        runCatching { codec.stop() }
        runCatching { codec.release() }
    }

    /**
     * Bounded wait for the drain thread before its codec is stopped and
     * released: `MediaCodec.release()` while the loop is in
     * `dequeueOutputBuffer` is not safe. Never joins itself (teardown from a
     * drain-thread callback): the `encoder` identity check already ends it.
     */
    private fun waitForDrain() {
        val t = drainThread ?: return
        if (t === Thread.currentThread()) return
        runCatching { t.join(DRAIN_JOIN_MS) }
    }

    private fun detachEncoder() {
        val codec = encoder
        encoder = null
        runCatching { vd?.setSurface(null) }
        if (codec != null) {
            waitForDrain()
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
            // A mirror has no app to relayout; display 0 draws when it changes.
            if (released || encoder !== codec || mirrorScreen != null) return
            log("stream $stream: no frame since the encoder attached, redraw nudge ${guard.nudgeCount} (dpi=${baseDpi + offset})")
            runCatching { vd?.resize(width, height, baseDpi + offset) }
        }
    }

    private fun configure(codec: MediaCodec, w: Int, h: Int, strategy: StreamStrategy,
                          kind: VideoCodec) {
        // The switches are read once per configure (open, resize, encoder
        // rebuild): a bench sets the properties and then opens a window. Never
        // per frame. The caller read it before choosing the codec.
        this.strategy = strategy
        quality.enabled = strategy.quality
        this.videoCodec = kind
        // The bitrate target: an explicit window.quality request wins, otherwise
        // it is computed from the pixels (~0.12 bpp·fps, capped by cap_kbps).
        // While the ladder is active the rebuild keeps the link's belief (the
        // pixels changed, not the link) and the rung's scaled ceiling applies.
        val rate = rateSnapshot()
        val computedTarget = requestedBitrate ?: strategy.bitrateFor(w, h)
        if (rate.rung == LadderRung.Full) {
            quality.setTarget(computedTarget)
        } else {
            quality.setTarget(ladderTargetFor(computedTarget, rate), restart = false)
        }
        // A new encoder or a resize: no gain measured for this key yet.
        resetCorrection()
        if (strategy.overshoot != StreamStrategy.DEFAULT_OVERSHOOT) {
            log("stream $stream: encoder overshoot ${strategy.overshoot}x the target")
        }
        if (StreamDebug.ignoreRepeatFrame()) {
            log("stream $stream: ${StreamDebug.IGNORE_REPEAT}=1, no repeat-previous-frame heartbeat")
        }
        val caps = runCatching { codec.codecInfo.getCapabilitiesForType(kind.mime) }.getOrNull()
        val cbrSupported = caps?.encoderCapabilities
            ?.isBitrateModeSupported(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR) == true
        val intraRefreshSupported = caps
            ?.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_IntraRefresh) == true
        val lowLatencySupported = caps
            ?.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency) == true
        // The strategy line is written before the display exists, so the
        // builder method's presence is the fallback signal; an invocation that
        // still throws is named by createDisplay's classic line.
        val vdRateSupported = strategy.vdRate <= 0 || refreshRateMethodExists()
        // Per-frame average QP rides each output buffer's format, but only
        // when the codec declares the feature; asking elsewhere fails configure.
        encodingStatistics = caps
            ?.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_EncodingStatistics) == true
        val plan = StreamFormat.build(
            w = w,
            h = h,
            bitrateBps = encoderBitrate(quality.bitrate),
            strategy = strategy,
            cbrSupported = cbrSupported,
            intraRefreshSupported = intraRefreshSupported,
            repeatPreviousFrame = !StreamDebug.ignoreRepeatFrame(),
            maxFps = maxFps,
            encodingStatistics = encodingStatistics,
            lowLatencySupported = lowLatencySupported,
            codec = kind,
        )
        val format = plan.format
        stats.setTarget(quality.bitrate)
        appliedBitrate = encoderBitrate(quality.bitrate)
        try {
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        } catch (e: Throwable) {
            if (!format.containsKey(StreamFormat.KEY_MAX_FPS)) throw e
            log("stream $stream: encoder refused ${StreamFormat.KEY_MAX_FPS}=$maxFps; dropping frames instead")
            format.removeKey(StreamFormat.KEY_MAX_FPS)
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        }
        synchronized(refineLock) { refineModel = RefineModel() }
        log("stream $stream strategy: ${strategy.describe(plan.applied.copy(vdRate = vdRateSupported))}")
    }

    private fun flags(): Int {
        // The panel-group knob is a debug build's stand-in for One UI; it swaps
        // only the display-group bits inside the pure set.
        val panelGroup = dev.pocketdeck.BuildConfig.DEBUG &&
            Hidden.systemProperty(VD_PANEL_GROUP) == "1"
        return WindowDisplayFlags.requested(panelGroup)
    }

    /** Names for the requested flags, so the server log shows what we asked for. */
    private fun virtualFlagNames(f: Int): String = WindowDisplayFlags.names(f)

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
        val rate = DisplayRate.requested(strategy.vdRate, refreshRateMethodExists())
        val config = buildConfig(w, h, dpi, surface, rate)
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
                    return Created(it, "VirtualDisplayConfig", rate)
                }
            }
        }
        val classic = displayManager().createVirtualDisplay("pocketdeck-$stream", w, h, dpi, surface, flags())
        DisplayRate.classicUnsupported(strategy.vdRate)?.let { log("stream $stream $it") }
        return Created(classic, "classic", null)
    }

    private class Created(
        val display: VirtualDisplay,
        val path: String,
        /** The refresh rate the builder was given, or null when not requested. */
        val rate: Float? = null,
    )

    /** API 36's `VirtualDisplayConfig.Builder.setRequestedRefreshRate`, if this build has it. */
    private fun refreshRateMethodExists(): Boolean = runCatching {
        Class.forName("android.hardware.display.VirtualDisplayConfig\$Builder")
            .getMethod("setRequestedRefreshRate", Float::class.javaPrimitiveType)
    }.isSuccess

    private fun buildConfig(w: Int, h: Int, dpi: Int, surface: Surface, rate: Float?): Any? = runCatching {
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
        if (rate != null) {
            builderClass.getMethod("setRequestedRefreshRate", Float::class.javaPrimitiveType)
                .invoke(builder, rate)
        }
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
            val wm = Hidden.proxy("android.view.IWindowManager", "window")
            if (wm == null) {
                val missing = "hidden api missing: IWindowManager"
                if (Hidden.firstTime(missing)) log(missing)
                return
            }
            val m = Hidden.method(
                Hidden.iface("android.view.IWindowManager"),
                "setDisplayImePolicy",
                Hidden.T_INT,
                Hidden.T_INT,
            )
            if (m == null) {
                val missing = "hidden api missing: IWindowManager.setDisplayImePolicy"
                if (Hidden.firstTime(missing)) log(missing)
                return
            }
            m.invoke(wm, displayId, IME_POLICY_HIDE)
        }
    }

    /** Starts the drain; returns whether the new codec stayed suspended (Q1). */
    private fun startDrain(codec: MediaCodec, kind: VideoCodec): Boolean {
        videoCodec = kind
        stats.codec = kind
        // A new encoder's first IDR may already answer the Mac's request.
        keyGate.reset()
        heartbeat(IdleFrameWatchdogEvent.Live(SystemClock.elapsedRealtime()))
        // A rebuild while the queue was suspended must not restart a flowing
        // encoder: re-apply the input stop to the new codec.
        var stillSuspended = encoderSuspended
        if (stillSuspended && !applySuspend(codec, true)) {
            stillSuspended = false
            stats.onSuspendEnd(SystemClock.elapsedRealtime())
        }
        lastOutputSize = -1
        lastDistinctMs = SystemClock.elapsedRealtime()
        drainThread = Thread({ drain(codec, kind) }, "pocketdeck-drain-$stream").also { it.start() }
        return stillSuspended
    }

    /**
     * T1: feed the refinement machine. The still signal is "no encoded frame
     * with a new size for 300 ms": repeats of an unchanged picture keep the
     * same size, which is the only input-silence signal an encoder exposes
     * (its Surface input is not readable). An encoder that sends nothing at all
     * is covered by the same rule after the heartbeat's first second.
     */
    private fun maybeRefine(now: Long) {
        if (!strategy.refine || encoderSuspended || paused) return
        if (now - lastDistinctMs >= REFINE_STILL_MS) refine(RefineEvent.Still, now)
        if (refineModel.state == RefineState.Refining) refine(RefineEvent.Tick(now), now)
    }

    /** One encoded frame for the refinement machine, and its size as the proof. */
    private fun noteRefineFrame(now: Long, key: Boolean, size: Int) {
        if (!strategy.refine) return
        val previous = lastOutputSize
        val changed = key || size != previous
        lastOutputSize = size
        if (changed) lastDistinctMs = now
        if (key && refineModel.state == RefineState.Refining) {
            log("stream $stream refine: frame $size bytes (previous $previous)")
        }
        refine(RefineEvent.Frame(key, changed), now)
    }

    private fun refine(event: RefineEvent, now: Long) {
        val actions: List<RefineAction>
        synchronized(refineLock) {
            val before = refineModel
            val step = refineStep(before, event, now)
            refineModel = step.model
            if (step.model.state != before.state) {
                log("stream $stream refine: ${before.state.wire} --${step.event}--> ${step.model.state.wire}")
            }
            actions = step.actions
        }
        for (action in actions) {
            when (action) {
                RefineAction.RaiseBitrate -> {
                    val target = quality.bitrate
                    val raised = minOf(target.toLong() * 3, strategy.capBps.toLong()).toInt()
                    stats.onRefined()
                    setLiveBitrate(raised, "refine")
                }
                RefineAction.RequestSync -> encoder?.let { requestSyncFrame(it) }
                RefineAction.RestoreBitrate -> setLiveBitrate(quality.bitrate, "refine done")
            }
        }
    }

    /** A bitrate for the refined frame only; the adaptation's target is untouched. */
    private fun setLiveBitrate(bps: Int, reason: String) {
        val codec = encoder ?: return
        val encoderBps = encoderBitrate(bps)
        // The refined key is not the correction's key: do not measure it.
        encoderOutput.forget(stream)
        lastEncoderSampleAtMs = SystemClock.elapsedRealtime()
        val ok = runCatching {
            val params = Bundle()
            params.putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, encoderBps)
            codec.setParameters(params)
            true
        }.getOrDefault(false)
        log("stream $stream bitrate ${mbps(encoderBps)} ($reason${if (ok) "" else ", encoder not running"})")
    }

    /**
     * What the codec is told: the believed bitrate through the encoder's
     * measured gain, never above the uncorrected key (arm A's overshoot times
     * the target).
     */
    private fun encoderBitrate(bps: Int): Int {
        val factor = strategy.overshoot.coerceAtLeast(1).toLong()
        val uncorrected = (bps.toLong() * factor).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
        return correction.keyFor(SystemClock.elapsedRealtime(), bps, uncorrected)
    }

    /** A new target, encoder restart or resize: no gain is known for the new key. */
    private fun resetCorrection() {
        val before = correction.state
        correction.reset()
        encoderOutput.forget(stream)
        lastEncoderSampleAtMs = 0
        if (before != correction.state) {
            log("stream $stream encoder loop: ${before.wire} --reset--> ${correction.state.wire}")
            lastCorrectionState = correction.state
        }
    }

    /** The field log's one line per state change of the inner loop. */
    private fun logCorrectionState(event: String) {
        val now = correction.state
        if (now == lastCorrectionState) return
        log("stream $stream encoder loop: ${lastCorrectionState.wire} --$event--> ${now.wire}")
        lastCorrectionState = now
    }

    /**
     * One gain sample a second from the encoder's delta output, then the key
     * follows the believed bitrate. Runs on the drain thread.
     */
    private fun maybeTrackEncoder(nowMs: Long) {
        if (nowMs - lastEncoderSampleAtMs < EncoderCorrection.SAMPLE_INTERVAL_MS) return
        lastEncoderSampleAtMs = nowMs
        val output = encoderOutput.rateBps(stream, nowMs * 1_000)
        if (correction.sample(nowMs, output, appliedBitrate)) {
            logCorrectionState("sample")
            applyBitrate()
        }
    }

    private fun drain(codec: MediaCodec, kind: VideoCodec) {
        val info = MediaCodec.BufferInfo()
        // WIN-63: one per encoder, so its first format always goes out.
        val configChange = ConfigChange()
        var nextFreezeCheckMs = 0L
        var frozen = false
        while (!released && encoder === codec) {
            val polled = SystemClock.elapsedRealtime()
            if (!frozen && polled >= nextFreezeCheckMs) {
                nextFreezeCheckMs = polled + FREEZE_CHECK_MS
                frozen = StreamDebug.freezeDrain()
                if (frozen) log("stream $stream: ${StreamDebug.FREEZE_DRAIN}=1, drain frozen (a stuck encoder)")
            }
            if (frozen) {
                try {
                    Thread.sleep(FREEZE_CHECK_MS)
                } catch (_: InterruptedException) {
                    break
                }
                continue
            }
            val idx = try {
                codec.dequeueOutputBuffer(info, 10_000)
            } catch (e: Throwable) {
                log("stream $stream drain ended: ${e.javaClass.simpleName}")
                break
            }
            val now = SystemClock.elapsedRealtime()
            // Poll only when no picture buffer was ready: the machine is about
            // encoder output, not the loop's cadence.
            if (idx < 0 && encoder === codec) heartbeat(IdleFrameWatchdogEvent.Tick(now))
            maybeRefine(now)
            guard.poll(now)?.let { nudgeRedraw(codec, it) }
            // Bitrate recovery rides on the drain loop: no extra timer, and it
            // only grows the bitrate when the stream is alive anyway.
            quality.maybeRecover(now)?.let { bps ->
                log("stream $stream quality: bitrate recovered to ${mbps(bps)} (+10%)")
                applyBitrate()
            }
            // The inner loop samples the encoder's own delta output once a
            // second and re-applies the key when the gain moved.
            maybeTrackEncoder(now)
            if (idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                readCsd(codec.outputFormat)?.let {
                    lastCsd = it
                    // Per-frame statistics change the format with the same
                    // parameter sets: only a real change reaches the Mac.
                    val rect = picture
                    if (configChange.shouldSend(kind.wire, width, height, rect, it)) {
                        sink.onConfig(stream, kind.wire, width, height, it, rect)
                    }
                }
                continue
            }
            if (idx < 0) continue
            try {
                val buf = codec.getOutputBuffer(idx)
                if (buf != null && info.size > 0 && (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
                    val key = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
                    // The flag says "key"; the NAL types say whether the
                    // decoder can start there (intra refresh flags otherwise).
                    val keyNalTypes = if (key) {
                        buf.position(info.offset)
                        buf.limit(info.offset + info.size)
                        nalTypes(buf, info.size, kind)
                    } else null
                    // Delta output only: a periodic key would read as a gain
                    // spike in the one-second window.
                    if (!key) encoderOutput.note(stream, info.size, now * 1_000)
                    // The encoder path's clock: Surface input pts are
                    // CLOCK_MONOTONIC microseconds, as System.nanoTime is.
                    val encodeUs = if (statsWanted) {
                        (System.nanoTime() / 1_000 - info.presentationTimeUs)
                            .takeIf { it in 0..10_000_000L }
                    } else null
                    val qp = if ((statsWanted || qpSample.collecting) && encodingStatistics) {
                        readQp(codec, idx)
                    } else {
                        null
                    }
                    if (qpSample.collecting && qpSample.note(qp)) {
                        // The format's own names, never its values: the reviewer
                        // needs to know whether a QP key exists on this codec.
                        val keys = runCatching { codec.getOutputFormat(idx).keys }
                            .getOrDefault(emptySet())
                        log(qpSample.line(stream, keys))
                    }
                    val statsQp = if (statsWanted) qp else null
                    if (encoder !== codec) {
                        // Switched away mid-buffer: its size is no longer the stream's.
                    } else if (paused) {
                        // Paused with the encoder kept running: nothing goes out.
                        stats.onFrame(key, 0, encodeUs, statsQp, keyNalTypes, kind)
                    } else {
                        heartbeat(IdleFrameWatchdogEvent.Frame(now, key))
                        noteRefineFrame(now, key, info.size)
                        val skipped = dropForFps(info.presentationTimeUs)
                        if (skipped) stats.onSkipped()
                        stats.onFrame(key, if (skipped) 0 else info.size, encodeUs, statsQp,
                                      keyNalTypes, kind)
                        if (!skipped) {
                            val data = ByteArray(info.size)
                            buf.get(data)
                            if (key && keyNalTypes != null && isIdrAccessUnit(keyNalTypes, kind)) {
                                keyGate.onIdr(now)
                            }
                            sink.onFrame(stream, info.presentationTimeUs, key, data)
                            guard.onFrame(SystemClock.elapsedRealtime())?.let {
                                log("stream $stream first frame ${it}ms after the encoder attached (nudges=${guard.nudgeCount})")
                            }
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
        val bps = encoderBitrate(quality.bitrate)
        logCorrectionState("key")
        stats.setTarget(quality.bitrate)
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

    /** `KEY_VIDEO_QP_AVERAGE` from this output buffer's format, if present. */
    private fun readQp(codec: MediaCodec, index: Int): Int? = runCatching {
        val format = codec.getOutputFormat(index)
        if (format.containsKey(MediaFormat.KEY_VIDEO_QP_AVERAGE)) {
            format.getInteger(MediaFormat.KEY_VIDEO_QP_AVERAGE)
        } else {
            null
        }
    }.getOrNull()

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

/**
 * The stream table behind [AndroidDisplayLayer]. Every insert hands back the
 * value it displaced, so the caller closes it outside the lock: a silent
 * overwrite leaked an encoder, a virtual display and its drain thread. Pure
 * Kotlin (no Android types), so a JVM test pins the ownership rule.
 */
internal class StreamTable<V> {
    private val map = HashMap<Int, V>()

    fun get(stream: Int): V? = synchronized(map) { map[stream] }

    /** Inserts [value]; returns what the same stream id held before, if anything. */
    fun put(stream: Int, value: V): V? = synchronized(map) { map.put(stream, value) }

    /** Removes the stream; the caller owns (and closes) what comes back. */
    fun take(stream: Int): V? = synchronized(map) { map.remove(stream) }

    /** A snapshot of the values, for a session-wide setting (stats on/off). */
    fun values(): List<V> = synchronized(map) { map.values.toList() }
}

/**
 * Owns every [WindowStream] and exposes them to the session as a [DisplayLayer].
 *
 * The `streams` lock only ever guards the map itself: an open build, an encoder
 * or VD start/stop and a close take seconds, and holding the map across them
 * made every other stream's keyframe request and backpressure note wait (the
 * field log: one window opening stalled all output). Build or detach the stream
 * first, then swap it into the map in one short step.
 */
internal class AndroidDisplayLayer(
    private val ctx: Context,
    private val log: (String) -> Unit,
) : DisplayLayer {

    private val streams = StreamTable<WindowStream>()
    @Volatile private var statsOn = false
    /** The codecs the Mac's hello said it decodes; HEVC only arrives here on request. */
    @Volatile private var macCodecs: Set<VideoCodec> = setOf(VideoCodec.Avc)

    override fun setMacCodecs(codecs: Set<VideoCodec>) {
        macCodecs = codecs
    }

    override fun open(stream: Int, w: Int, h: Int, dpi: Int, sink: VideoSink): Int {
        take(stream)?.close()
        val ws = WindowStream(ctx, stream, sink, log, macCodecs = { macCodecs })
            .also { it.setStatsWanted(statsOn) }
        // start() can throw after it created the persistent surface and an
        // encoder; close what it built before the session sees the failure.
        val id = try {
            ws.start(w, h, dpi)
        } catch (e: Throwable) {
            ws.close()
            throw e
        }
        // The map holds the finished stream from here; a later open for the same
        // id first takes it out and closes it outside the lock. Nothing is ever
        // overwritten silently.
        put(stream, ws)
        return id
    }

    override fun openMirror(stream: Int, w: Int, h: Int, sink: VideoSink): IntSize {
        take(stream)?.close()
        val ws = WindowStream(ctx, stream, sink, log, macCodecs = { macCodecs })
            .also { it.setStatsWanted(statsOn) }
        val size = try {
            ws.startMirror(w, h)
        } catch (e: Throwable) {
            ws.close()
            throw e
        }
        put(stream, ws)
        return size
    }

    override fun size(stream: Int): IntSize = get(stream)?.inputSize ?: IntSize(0, 0)

    override fun resize(stream: Int, w: Int, h: Int, dpi: Int): ResizeOutcome =
        get(stream)?.resize(w, h, dpi) ?: ResizeOutcome.KEPT

    override fun pause(stream: Int) {
        get(stream)?.pause()
    }

    override fun resume(stream: Int) {
        get(stream)?.resume()
    }

    override fun requestKeyframe(stream: Int) {
        get(stream)?.requestKeyframe()
    }

    override fun requestKeyframeAfterDrop(stream: Int) {
        get(stream)?.requestKeyframeAfterDrop()
    }

    override fun setQuality(stream: Int, bitrate: Int?, maxFps: Int?) {
        get(stream)?.setQuality(bitrate, maxFps)
    }

    override fun onBackpressure(stream: Int, measuredBps: Int?, encodedBps: Int?) {
        get(stream)?.onBackpressure(measuredBps, encodedBps)
    }

    override fun onQueueDelay(stream: Int, delayP95Us: Long, delayP50Us: Long, linkBps: Int?) {
        get(stream)?.onQueueDelay(SystemClock.elapsedRealtime(), delayP95Us, delayP50Us, linkBps)
    }

    override fun setEncoderSuspend(stream: Int, suspended: Boolean) {
        get(stream)?.setEncoderSuspend(suspended)
    }

    override fun close(stream: Int) {
        take(stream)?.close()
    }

    private fun get(stream: Int): WindowStream? = streams.get(stream)

    /** Inserts, then closes anything it displaced outside the lock. */
    private fun put(stream: Int, ws: WindowStream) {
        streams.put(stream, ws)?.close()
    }

    /** Removes the stream from the map; the caller closes it outside the lock. */
    override fun setStatsEnabled(on: Boolean) {
        statsOn = on
        for (stream in streams.values()) stream.setStatsWanted(on)
    }

    override fun statsSnapshot(stream: Int, nowUs: Long, reset: Boolean): EncoderStats? =
        get(stream)?.statsSnapshot(reset)

    override fun totalsLine(stream: Int): String? = get(stream)?.totalsLine()

    private fun take(stream: Int): WindowStream? = streams.take(stream)
}
