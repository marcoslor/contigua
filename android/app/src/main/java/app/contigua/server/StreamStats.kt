package app.contigua.server

/**
 * One stream's counters for `stream.stats` (ISS-40): plain increments on paths
 * that already run, plus fixed-size rings for the encode-delay and QP
 * percentiles. The rings never allocate; a snapshot sorts a copy only when the
 * Mac asked for stats and a message is due. Pure Kotlin (no Android types), so
 * the JVM tests pin the counters and percentiles.
 */
internal class StreamStats(
    /** The stream id the one key-frame log line names. */
    private val stream: Int = 0,
    /** The field log's sink; the first 3 non-IDR key frames use it. */
    private val log: (String) -> Unit = {},
    /** The monotonic milliseconds `onSuspendStart`/`onSuspendEnd` use. */
    private val clockMs: () -> Long = { 0L },
) {
    private companion object {
        const val RING = 512
        /** A dequeue more than this after the capture pts is a clock change, not a delay. */
        const val MAX_ENCODE_US = 10_000_000L
        /** The first few non-IDR key frames go to the field log; the count continues. */
        const val KEY_LOG_LIMIT = 3
    }

    private var framesOut = 0L
    private var keyframesOut = 0L
    /** The stream's codec, set at each configure; it names the NAL types below. */
    var codec: VideoCodec = VideoCodec.Avc
    /** ISS-40 round 3: key-flagged buffers with and without a type-5 slice. */
    private var keyIdr = 0L
    private var keyNotIdr = 0L
    private var keyNotIdrLogged = 0
    private var keyframesRequested = 0L
    private var bytesOut = 0L
    private var framesSkipped = 0L
    private var targetBps = 0
    private var suspendedEpisodes = 0L
    private var suspendedMs = 0L
    /** Every closed episode's whole time, never reset by a snapshot. */
    private var totalSuspendedMs = 0L
    private var refined = 0L

    // The stream's whole life for the one line at close (ISS-40 round 2). A
    // 2 s snapshot never consumes these.
    private var totalOut = 0L
    private var totalSent = 0L
    private var totalSkipped = 0L
    private var totalBytes = 0L
    private var totalKeyframes = 0L
    private var totalKeyIdr = 0L
    private var totalKeyNotIdr = 0L

    /** WIN-66's record: the encoder's output counters over the stream's whole life. */
    val framesOutTotal: Long get() = totalOut
    val keyframesOutTotal: Long get() = totalKeyframes
    val bytesOutTotal: Long get() = totalBytes

    // QP's mean: the sum and count are enough, and unlike the rings they are
    // never capped, so the window's mean covers every frame.
    private var qpSum = 0L
    private var qpCount = 0L
    private var totalQpSum = 0L
    private var totalQpCount = 0L

    /** Q1: when the current suspend episode began, or null while flowing. */
    private var suspendStartMs: Long? = null
    /** How much of the open episode earlier snapshots already reported. */
    private var suspendCountedMs = 0L

    private val encode = LongRing(RING)
    private val qp = IntRing(RING)

    fun onFrame(key: Boolean, bytes: Int, encodeUs: Long?, qpValue: Int?,
                keyNalTypes: List<Int>? = null, codec: VideoCodec? = null) {
        framesOut++
        bytesOut += bytes
        totalOut++
        totalBytes += bytes
        // A forwarded buffer has bytes; a paused or skipped one is handed zero.
        if (bytes > 0) totalSent++
        val typeCodec = codec ?: this.codec
        if (key) {
            keyframesOut++
            totalKeyframes++
            // The flag on a buffer says "key"; only a type-5 slice says the
            // decoder can start there. Intra refresh flags recovery points.
            if (keyNalTypes != null) {
                if (isIdrAccessUnit(keyNalTypes, typeCodec)) {
                    keyIdr++
                    totalKeyIdr++
                } else {
                    keyNotIdr++
                    totalKeyNotIdr++
                    if (keyNotIdrLogged < KEY_LOG_LIMIT) {
                        keyNotIdrLogged++
                        log("stream $stream key nal=${keyNalTypes.joinToString(",")}")
                    }
                }
            }
        }
        encodeUs?.let { if (it in 0..MAX_ENCODE_US) encode.add(it) }
        qpValue?.let {
            qp.add(it)
            qpSum += it
            qpCount++
            totalQpSum += it
            totalQpCount++
        }
    }

    fun onKeyframeRequested() {
        keyframesRequested++
    }

    fun onSkipped() {
        framesSkipped++
        totalSkipped++
    }

    /** Q1: the encoder's input is suspended; one episode per rising edge. */
    fun onSuspendStart(nowMs: Long) {
        if (suspendStartMs == null) {
            suspendStartMs = nowMs
            suspendedEpisodes++
        }
    }

    /** Q1: what is left of the episode lands in the window that saw it end. */
    fun onSuspendEnd(nowMs: Long) {
        val start = suspendStartMs ?: return
        val elapsed = (nowMs - start).coerceAtLeast(0)
        suspendedMs += (elapsed - suspendCountedMs).coerceAtLeast(0)
        totalSuspendedMs += elapsed
        suspendStartMs = null
        suspendCountedMs = 0
    }

    /** T1: one refined frame was sent for a still period. */
    fun onRefined() {
        refined++
    }

    fun setTarget(bps: Int) {
        targetBps = bps
    }

    /** The window's numbers; `reset` starts the next window at zero. */
    fun snapshot(reset: Boolean = true, nowMs: Long = clockMs()): EncoderStats {
        // An episode still open counts what it has run so far; the next
        // snapshot starts from this point, so no span is counted twice.
        val openMs = openSuspendMs(nowMs)
        val out = EncoderStats(
            frames = framesOut,
            keyframes = keyframesOut,
            keyIdr = keyIdr,
            keyNotIdr = keyNotIdr,
            keyframesRequested = keyframesRequested,
            bytes = bytesOut,
            framesSkipped = framesSkipped,
            targetBps = targetBps,
            encodeP50 = encode.percentile(0.50),
            encodeP95 = encode.percentile(0.95),
            qpP50 = qp.percentile(0.50),
            qpP95 = qp.percentile(0.95),
            suspendedEpisodes = suspendedEpisodes,
            suspendedMs = suspendedMs + openMs,
            refined = refined,
            codec = codec,
            qpAvg = if (qpCount > 0) qpSum.toDouble() / qpCount else null,
        )
        if (reset) {
            framesOut = 0
            keyframesOut = 0
            keyIdr = 0
            keyNotIdr = 0
            keyframesRequested = 0
            bytesOut = 0
            framesSkipped = 0
            suspendedEpisodes = 0
            suspendedMs = 0
            if (suspendStartMs != null) suspendCountedMs += openMs
            refined = 0
            qpSum = 0
            qpCount = 0
            encode.clear()
            qp.clear()
        }
        return out
    }

    /**
     * The one closed-token line at stream close: encoder output buffers, the
     * frames actually sent, the max-fps drops and the bytes sent, over the
     * stream's whole life. It is how a CBR freeze is told apart from a stalled
     * encoder: `out` stays high while `sent` does not follow.
     */
    fun totalsLine(stream: Int, secs: Double, nowMs: Long = clockMs()): String =
        "stream $stream totals: out=$totalOut sent=$totalSent skipped=$totalSkipped " +
            "bytes=$totalBytes susp_ms=" + totalsSuspendedMs(nowMs) +
            " key_idr=$totalKeyIdr key_not_idr=$totalKeyNotIdr" +
            " secs=" + String.format(java.util.Locale.US, "%.1f", secs) +
            " codec=${codec.token} qp_avg=" + (if (totalQpCount > 0) {
                String.format(java.util.Locale.US, "%.1f", totalQpSum.toDouble() / totalQpCount)
            } else {
                "-"
            })

    /** The lifetime suspension time, with an episode still open counted so far. */
    private fun totalsSuspendedMs(nowMs: Long): Long {
        val start = suspendStartMs ?: return totalSuspendedMs
        return totalSuspendedMs + (nowMs - start).coerceAtLeast(0)
    }

    /** The open episode's unreported time: the whole episode is in the totals. */
    private fun openSuspendMs(nowMs: Long): Long {
        val start = suspendStartMs ?: return 0
        val elapsed = (nowMs - start).coerceAtLeast(0)
        return (elapsed - suspendCountedMs).coerceAtLeast(0)
    }
}

/** One encoder's window counters, before the session adds its queue counters. */
data class EncoderStats(
    val frames: Long,
    val keyframes: Long,
    val keyframesRequested: Long,
    val bytes: Long,
    val framesSkipped: Long,
    val targetBps: Int,
    val encodeP50: Long?,
    val encodeP95: Long?,
    val qpP50: Int?,
    val qpP95: Int?,
    val suspendedEpisodes: Long = 0,
    val suspendedMs: Long = 0,
    val refined: Long = 0,
    /** Key-flagged buffers with a type-5 slice and without one. */
    val keyIdr: Long = 0,
    val keyNotIdr: Long = 0,
    /** The codec whose NAL types the counts above used. */
    val codec: VideoCodec = VideoCodec.Avc,
    /** The mean of this window's frame QPs; null when none reported one. */
    val qpAvg: Double? = null,
)

/**
 * The session side of one stream's stats: deltas the send queue discarded and
 * the queue delay of the frames that did reach the socket. Locked because the
 * writer thread reports a written frame and the session thread builds the
 * message.
 */
internal class SendStats {
    private val lock = Any()
    private val queue = LongRing(1024)

    fun onWritten(us: Long) = synchronized(lock) {
        if (us in 0..MAX_QUEUE_US) queue.add(us)
    }

    /** The window's queue percentiles plus the queue's drop counts; resets. */
    fun snapshot(deltasDropped: Int, dropEpisodes: Int,
                 dropGapMs: Long = 0): SendSnapshot = synchronized(lock) {
        val out = SendSnapshot(deltasDropped, dropEpisodes,
                               queue.percentile(0.50), queue.percentile(0.95),
                               dropGapMs)
        queue.clear()
        out
    }

    private companion object {
        /** A queue delay over this is a stalled clock or a stalled link, skip it. */
        const val MAX_QUEUE_US = 30_000_000L
    }
}

internal data class SendSnapshot(
    val deltasDropped: Int,
    val dropEpisodes: Int,
    val queueP50: Long?,
    val queueP95: Long?,
    val dropGapMs: Long = 0,
)

/**
 * The audio path's realtime measurement (R4): how long an encoded packet waits
 * from `enqueueAudio` until its last byte is handed to the socket, plus the
 * packets the realtime budget discarded. One ring of 20 ms packets covers 5 s.
 */
internal class AudioWaitStats {
    private val lock = Any()
    private val waits = LongRing(256)
    private var dropped = 0

    fun note(us: Long) = synchronized(lock) {
        if (us in 0..MAX_WAIT_US) waits.add(us)
    }

    fun dropped(count: Int) = synchronized(lock) {
        dropped += count
    }

    fun snapshot(): AudioWaitSnapshot = synchronized(lock) {
        val out = AudioWaitSnapshot(waits.percentile(0.50), waits.percentile(0.95),
                                    waits.max(), waits.samples, dropped)
        waits.clear()
        dropped = 0
        out
    }

    private companion object {
        /** A wait over this is a stalled clock or a stalled link, not a sample. */
        const val MAX_WAIT_US = 30_000_000L
    }
}

internal data class AudioWaitSnapshot(
    val p50Us: Long?,
    val p95Us: Long?,
    val maxUs: Long?,
    val samples: Int,
    val dropped: Int,
) {
    /** One closed-token field log line; numbers only. */
    fun line(): String = "audio] wait_p50=${ms(p50Us)} wait_p95=${ms(p95Us)}" +
        " wait_max=${ms(maxUs)} n=$samples dropped=$dropped"

    private fun ms(us: Long?): String =
        if (us == null) "-" else String.format(java.util.Locale.ROOT, "%.1f", us / 1000.0)
}

/**
 * The `stream.stats` message body. Keys are documented in PROTOCOL.md; a
 * value with no measurement is omitted (`-` on the Mac's log line).
 */
internal object StreamStatsWire {
    fun message(stream: Int, windowMs: Long, encoder: EncoderStats,
                send: SendSnapshot, tcp: TCPCounterSample? = null,
                noFrame: NoFrameEpisode? = null): Map<String, Any?> {
        val out = linkedMapOf<String, Any?>(
            "t" to "stream.stats",
            "stream" to stream,
            "windowMs" to windowMs,
            "codec" to encoder.codec.token,
            "frames" to encoder.frames,
            "kf" to encoder.keyframes,
            "keyIdr" to encoder.keyIdr,
            "keyNotIdr" to encoder.keyNotIdr,
            "kfReq" to encoder.keyframesRequested,
            "bytes" to encoder.bytes,
            "drop" to send.deltasDropped,
            "dropEp" to send.dropEpisodes,
            "dropGapMs" to send.dropGapMs,
            "skip" to encoder.framesSkipped,
            "susp" to encoder.suspendedEpisodes,
            "suspMs" to encoder.suspendedMs,
            "refine" to encoder.refined,
            "targetBps" to encoder.targetBps,
        )
        encoder.encodeP50?.let { out["encP50"] = it }
        encoder.encodeP95?.let { out["encP95"] = it }
        send.queueP50?.let { out["queueP50"] = it }
        send.queueP95?.let { out["queueP95"] = it }
        encoder.qpP50?.let { out["qpP50"] = it }
        encoder.qpP95?.let { out["qpP95"] = it }
        encoder.qpAvg?.let { out["qpAvg"] = it }
        tcp?.retransSegs?.let { out["retrans"] = it }
        tcp?.timeouts?.let { out["rto"] = it }
        tcp?.lostRetransmit?.let { out["lost_retrans"] = it }
        // WIN-66: one episode state per message, while it has one to send.
        noFrame?.let { out["noFrame"] = it.wire() }
        return out
    }

    /**
     * The close path's message (WIN-66): the 2 s tick cannot come again for a
     * stream that is gone, so its ended episode rides alone with no counters.
     */
    fun episodeMessage(stream: Int, codec: VideoCodec, windowMs: Long,
                       episode: NoFrameEpisode): Map<String, Any?> = linkedMapOf(
        "t" to "stream.stats",
        "stream" to stream,
        "windowMs" to windowMs,
        "codec" to codec.token,
        "noFrame" to episode.wire(),
    )
}

/**
 * ISS-40's QP sample: one line per stream after its 30th output buffer, with
 * the last ten raw `KEY_VIDEO_QP_AVERAGE` values and the output format's own
 * key names containing "qp" (names only). The reviewer reads it on the real
 * phone; the stats counters said a QP of 1-2 while scrolling, which the
 * sample can confirm or deny. Pure Kotlin, so K1 pins the text.
 */
internal class QpSampleProbe {
    private companion object {
        const val BUFFERS = 30
        const val VALUES = 10
    }

    private val values = ArrayDeque<Int>()
    private var seen = 0

    /** True while this stream has not logged its sample. */
    var collecting = true
        private set

    /** One output buffer; true on the buffer that completes the sample. */
    fun note(qp: Int?): Boolean {
        if (!collecting) return false
        seen++
        if (qp != null) {
            values.addLast(qp)
            if (values.size > VALUES) values.removeFirst()
        }
        if (seen < BUFFERS) return false
        collecting = false
        return true
    }

    fun line(stream: Int, formatKeys: Set<String>): String {
        val keys = formatKeys.filter { it.contains("qp", ignoreCase = true) }.sorted()
        val shown = if (values.isEmpty()) "-" else values.joinToString(",")
        val names = if (keys.isEmpty()) "-" else keys.joinToString(",")
        return "stream $stream qp sample: key=video-qp-average values=$shown qp_keys=$names"
    }
}

/** Fixed-capacity ring of longs; overwrites the oldest. */
internal class LongRing(private val capacity: Int) {
    private val values = LongArray(capacity)
    private var head = 0
    private var size = 0

    /** Samples currently held (0..capacity). */
    val samples: Int get() = size

    fun add(value: Long) {
        values[head] = value
        head = (head + 1) % capacity
        if (size < capacity) size++
    }

    fun clear() {
        head = 0
        size = 0
    }

    /** Nearest-rank p50/p95; nil when empty. Sorts a copy, never the ring. */
    fun percentile(fraction: Double): Long? {
        if (size == 0) return null
        val copy = LongArray(size)
        for (index in 0 until size) {
            copy[index] = values[(head - size + index + capacity) % capacity]
        }
        copy.sort()
        val rank = maxOf(0, minOf(size - 1, Math.ceil(fraction * size).toInt() - 1))
        return copy[rank]
    }

    /** The largest sample, or nil when empty. */
    fun max(): Long? {
        if (size == 0) return null
        var largest = Long.MIN_VALUE
        for (index in 0 until size) {
            val value = values[(head - size + index + capacity) % capacity]
            if (value > largest) largest = value
        }
        return largest
    }
}

/** Fixed-capacity ring of ints, for QP. */
internal class IntRing(private val capacity: Int) {
    private val values = IntArray(capacity)
    private var head = 0
    private var size = 0

    fun add(value: Int) {
        values[head] = value
        head = (head + 1) % capacity
        if (size < capacity) size++
    }

    fun clear() {
        head = 0
        size = 0
    }

    fun percentile(fraction: Double): Int? {
        if (size == 0) return null
        val copy = IntArray(size)
        for (index in 0 until size) {
            copy[index] = values[(head - size + index + capacity) % capacity]
        }
        copy.sort()
        val rank = maxOf(0, minOf(size - 1, Math.ceil(fraction * size).toInt() - 1))
        return copy[rank]
    }
}
