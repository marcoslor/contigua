package dev.pocketdeck.server

import java.util.Random

/**
 * The rate controller's proof rig: a deterministic link under the real send
 * queue, goodput meter, bitrate policy and encoder loop.
 *
 * The encoder follows the key it is told (with ±noise; a keyframe is 2–4
 * deltas), the writer paces each entry's bytes at the link's capacity, and the
 * queue, its drop rule and the adaptation are the production classes on a
 * virtual clock. One profile is a crowded 2.4 GHz channel (a cap, 0.5 % loss as
 * one resend's delay, a 200 ms stall every 2 s); another steps 20 → 3 → 20
 * Mbit/s. A [Hook] sees the same samples the writer gives the controller, so
 * the early signal and the ladder run through the same rig as the "after".
 *
 * This is a test source: no Android types, no codecs, no wall clock, so a run
 * is exact and a few simulated minutes cost milliseconds.
 */
internal class LinkSim(
    private val name: String,
    private val capacityBps: (nowUs: Long) -> Long,
    private val seconds: Int = 120,
    private val targetBps: Int = 8_000_000,
    private val overshoot: Int = 1,
    private val lossPermille: Int = 0,
    private val resendDelayUs: Long = 20_000,
    private val spikeUs: Long = 200_000,
    private val spikeEveryUs: Long = 2_000_000,
    private val firstSpikeUs: Long = 1_000_000,
    private val fps: Int = 60,
    private val keyEveryUs: Long = 10_000_000,
    private val seed: Long = 7,
    private val warmupUs: Long = 3_000_000,
    private val hook: Hook? = null,
) {
    /** The controller and ladder under test, fed the writer's own samples. */
    interface Hook {
        /**
         * One 500 ms window: the writer's delay p95, the link's newest goodput,
         * the stream's believed and full target bitrates, and whether the belief
         * sits at its floor. The result carries the actions the caller applies.
         */
        fun window(
            nowMs: Long,
            delayP95Us: Long?,
            delayP50Us: Long?,
            linkBps: Int?,
            believedBps: Int,
            atFloor: Boolean,
            fullTargetBps: Int,
        ): Result

        data class Result(val lowerBps: Int? = null, val ladderTargetBps: Int? = null)

        /** The send queue dropped deltas: the drop rule owns this episode. */
        fun drop(nowMs: Long) {}
    }

    private var nowUs = 0L
    private val queue = SendQueue(
        maxDeltaBytesPerStream = 256 * 1024,
        maxDeltaDurationUs = 250_000,
        nowUs = { nowUs },
        nowMs = { nowUs / 1000 },
        linkBpsFor = { stream -> link.rateBps(stream, nowUs) },
        onDeltaDrop = { onDeltaDrop() },
    )
    private val link = GoodputMeter()
    private val delayMeter = QueueDelayMeter()
    private val quality = QualityAdaptation()
    private val correction = EncoderCorrection()
    private val encoderOutput = GoodputMeter(
        windowUs = 1_000_000L,
        minSpanUs = 50_000L,
        sampleGapUs = 1_000_000L,
    )
    private val random = Random(seed)
    private var nextFrameUs = 0L
    private var nextKeyUs = keyEveryUs
    private var keyPending = false
    private var appliedKeyBps = 0
    private var lastBelievedBps = 0
    private var lastSampleAtMs = 0L
    private var inFlight: SendQueue.Entry? = null
    private var remainingBytes = 0
    private var lossUntilUs = 0L
    private var stalledDuringWrite = false
    private var nextWindowAtUs = 2_000_000L

    private val delays = ArrayList<Pair<Long, Long>>()
    /** Delays of writes that never overlapped an injected stall or a resend. */
    private val standingDelays = ArrayList<Long>()
    private val targets = ArrayList<Pair<Long, Int>>()
    var episodes = 0
        private set
    var droppedDeltas = 0
        private set
    var streamingSecs = 0.0
        private set
    var lowestTargetBps = Int.MAX_VALUE
        private set
    var finalTargetBps = 0
        private set
    var finalDecoderBps = 0
        private set

    /** The p95 queue delay over the whole run after the warmup, in ms. */
    var p95Ms = 0.0
        private set
    /** The delay p95 outside the link's own withholding (the queue the sender owns). */
    var standingP95Ms = 0.0
        private set
    var maxMs = 0.0
        private set

    /** Median target while the link is at its low step (sim seconds 15–75). */
    var lowPhaseTargetBps = 0
        private set

    init {
        quality.setTarget(targetBps)
        appliedKeyBps = keyBps()
        lastBelievedBps = quality.bitrate
    }

    private fun capacity(now: Long): Long {
        if (now >= firstSpikeUs && spikeUs > 0 && spikeEveryUs > 0 &&
            (now - firstSpikeUs) % spikeEveryUs < spikeUs
        ) {
            return 0
        }
        return capacityBps(now)
    }

    private fun keyBps(): Int {
        val factor = overshoot.coerceAtLeast(1).toLong()
        val uncorrected = (quality.bitrate.toLong() * factor)
            .coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
        return correction.keyFor(nowUs / 1000, quality.bitrate, uncorrected)
    }

    private fun onDeltaDrop() {
        episodes++
        hook?.drop(nowUs / 1000)
        val measured = link.rateBps(1, nowUs)
        val encoded = queue.encoderBps(1)
        val keyBefore = appliedKeyBps
        quality.onDrop(nowUs / 1000, measured)
        if (encoded != null && encoded > 0) {
            correction.sample(nowUs / 1000, encoded, keyBefore)
        }
        keyPending = true
        appliedKeyBps = keyBps()
    }

    private fun frameBytes(): Int {
        // The encoder produces the key it is told: 60 fps of deltas plus a key
        // frame that is 2–4 deltas, with a deterministic ±10 % of noise.
        val perDelta = (appliedKeyBps.toLong() / 8 / fps).coerceAtLeast(1)
        val noise = 90 + random.nextInt(21)
        return (perDelta * noise / 100).coerceAtLeast(1).toInt()
    }

    private fun keyFrameBytes(): Int {
        val delta = frameBytes()
        val factor = 2 + random.nextInt(3)
        return delta * factor
    }

    fun run(): LinkSim {
        val endUs = seconds * 1_000_000L
        while (nowUs < endUs) {
            if (nowUs >= nextFrameUs) {
                nextFrameUs += 1_000_000L / fps
                val keyFrame = keyPending || nowUs >= nextKeyUs
                if (nowUs >= nextKeyUs) nextKeyUs += keyEveryUs
                if (keyFrame) {
                    keyPending = false
                    queue.enqueueControl(1, ByteArray(keyFrameBytes()), nowUs)
                } else {
                    val bytes = frameBytes()
                    encoderOutput.note(1, bytes, nowUs)
                    queue.enqueueDelta(1, nowUs, ByteArray(bytes))
                }
                val stats = queue.takeDeltaStats(1)
                droppedDeltas += stats.dropped
            }
            write()
            quality.maybeRecover(nowUs / 1000)
            if (quality.bitrate != lastBelievedBps) {
                lastBelievedBps = quality.bitrate
                appliedKeyBps = keyBps()
            }
            sampleCorrection()
            sampleWindow()
            val target = quality.bitrate
            lowestTargetBps = minOf(lowestTargetBps, target)
            finalTargetBps = target
            finalDecoderBps = target
            if (nowUs % 1_000_000L == 0L) targets.add(nowUs to target)
            nowUs += 1_000L
        }
        streamingSecs = (endUs - warmupUs) / 1_000_000.0
        finish()
        return this
    }

    /** One writer step: bytes drain at the current capacity; completion samples the run. */
    private fun write() {
        var entry = inFlight
        if (entry != null) {
            if (nowUs < lossUntilUs) {
                stalledDuringWrite = true
                return
            }
            val bps = capacity(nowUs)
            if (bps <= 0) stalledDuringWrite = true
            if (bps > 0) remainingBytes -= (bps / 8000).toInt().coerceAtLeast(0)
            if (remainingBytes <= 0) {
                // A lost final segment is one resend's delay before the bytes count.
                if (lossPermille > 0 && lossUntilUs == 0L &&
                    random.nextInt(1000) < lossPermille
                ) {
                    lossUntilUs = nowUs + resendDelayUs
                    return
                }
                complete(entry, nowUs)
                inFlight = null
                lossUntilUs = 0L
                entry = null
            }
        }
        if (entry == null && inFlight == null) {
            val next = queue.pollNow() ?: return
            inFlight = next
            remainingBytes = next.bytes.size
            lossUntilUs = 0L
            stalledDuringWrite = false
            if (remainingBytes <= 0) {
                complete(next, nowUs)
                inFlight = null
            }
        }
    }

    private fun complete(entry: SendQueue.Entry, atUs: Long) {
        val stream = entry.stream
        link.note(stream, entry.bytes.size, atUs,
                  limited = entry.enqueuedUs > 0 &&
                      atUs - entry.enqueuedUs >= GoodputMeter.BACKLOG_WAIT_US)
        if (entry.ptsUs >= 0 && entry.enqueuedUs > 0) {
            val wait = atUs - entry.enqueuedUs
            delayMeter.note(stream, atUs, wait, entry.bytes.size)
            if (atUs >= warmupUs) delays.add(atUs to wait)
            if (atUs >= warmupUs && !stalledDuringWrite) standingDelays.add(wait)
        }
    }

    private fun sampleCorrection() {
        val atMs = nowUs / 1000
        if (atMs - lastSampleAtMs < EncoderCorrection.SAMPLE_INTERVAL_MS) return
        lastSampleAtMs = atMs
        val output = encoderOutput.rateBps(1, nowUs)
        if (correction.sample(atMs, output, appliedKeyBps)) appliedKeyBps = keyBps()
    }

    /** One window of queue-delay samples every 500 ms. */
    private fun sampleWindow() {
        val hook = hook ?: return
        if (nowUs < nextWindowAtUs) return
        nextWindowAtUs = nowUs + 1_000_000L
        val p95 = delayMeter.p95Us(1, nowUs)
        val p50 = delayMeter.p50Us(1, nowUs)
        // The link's pace from the newest deep run (PATH-47's own reading).
        val linkBps = delayMeter.deepRateBps(1, nowUs)
        val result = hook.window(
            nowUs / 1000,
            p95,
            p50,
            linkBps,
            quality.bitrate,
            quality.atFloor,
            targetBps,
        )
        if (result.lowerBps != null && quality.lowerTo(nowUs / 1000, result.lowerBps) != null) {
            lastBelievedBps = quality.bitrate
            appliedKeyBps = keyBps()
        }
        if (result.ladderTargetBps != null) {
            quality.setTarget(result.ladderTargetBps, restart = false)
            lastBelievedBps = quality.bitrate
            appliedKeyBps = keyBps()
        }
    }

    private fun finish() {
        val xs = delays.map { it.second }.sorted()
        p95Ms = if (xs.isEmpty()) 0.0 else xs[((xs.size - 1) * 0.95).toInt()] / 1000.0
        val standing = standingDelays.sorted()
        standingP95Ms = if (standing.isEmpty()) 0.0
                         else standing[((standing.size - 1) * 0.95).toInt()] / 1000.0
        maxMs = (xs.maxOrNull() ?: 0L) / 1000.0
        val low = targets.filter { it.first in 15_000_000L until 75_000_000L }
            .map { it.second }.sorted()
        lowPhaseTargetBps = if (low.isEmpty()) 0 else low[low.size / 2]
    }

    fun summary(): String =
        "sim $name: p95=${"%.1f".format(p95Ms)} ms standing95=${"%.1f".format(standingP95Ms)} ms " +
            "max=${"%.1f".format(maxMs)} ms " +
            "episodes=$episodes dropped=$droppedDeltas lowest=${lowestTargetBps / 1000} kbps " +
            "lowPhaseTarget=${lowPhaseTargetBps / 1000} kbps final=${finalTargetBps / 1000} kbps"

    /** The target trace, one line per second: for the baseline record. */
    fun trace(): String = targets.joinToString(" ") { "${it.first / 1_000_000}:${it.second / 1000}" }
}
