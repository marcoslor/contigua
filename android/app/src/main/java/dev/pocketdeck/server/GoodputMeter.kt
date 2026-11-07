package dev.pocketdeck.server

/**
 * The video bytes a stream actually got out of the send queue in the recent
 * contiguous run (P4's fallback arm). The TCP sender's queue drain rate is the
 * only throughput signal available without TCP_INFO, and while the queue is
 * backlogged it is the link's rate: the kernel accepts bytes at the rate the
 * path can carry them.
 *
 * Pure and clock-explicit so the policy test can drive a shaped link: note
 * each written entry with the session's monotonic µs, then ask for the rate at
 * the moment a drop happens.
 *
 * A run ends at a gap longer than [SAMPLE_GAP_US]: a static screen at 2 fps
 * writes two frames 500 ms apart, and averaging that idle gap into the next
 * scroll would report the idle rate as the link's. The run must also span at
 * least [MIN_SPAN_US], so the first frames after a keyframe cannot fake a cap.
 * Samples older than [WINDOW_US] are pruned on every note, so an idle stream
 * holds at most three seconds of entries.
 */
internal class GoodputMeter(
    private val windowUs: Long = WINDOW_US,
) {
    private class Sample(val atUs: Long, val bytes: Int)

    private val streams = HashMap<Int, ArrayDeque<Sample>>()

    /** One entry's bytes left the writer for this stream at [nowUs]. */
    @Synchronized
    fun note(stream: Int, bytes: Int, nowUs: Long) {
        if (stream <= 0 || bytes <= 0) return
        val queue = streams.getOrPut(stream) { ArrayDeque() }
        val last = queue.lastOrNull()
        // A backwards clock, or a gap long enough to be idle, starts a new run.
        if (last != null && (nowUs < last.atUs || nowUs - last.atUs > SAMPLE_GAP_US)) {
            queue.clear()
        }
        queue.addLast(Sample(nowUs, bytes))
        prune(queue, nowUs)
    }

    /**
     * Bits per second over the samples still inside the window, or nil when
     * the stream has less than [MIN_SPAN_US] of current evidence or its last
     * sample is already stale.
     */
    @Synchronized
    fun rateBps(stream: Int, nowUs: Long): Int? {
        val queue = streams[stream] ?: return null
        prune(queue, nowUs)
        if (queue.isEmpty()) return null
        if (nowUs - queue.last().atUs > SAMPLE_GAP_US) return null
        val spanUs = nowUs - queue.first().atUs
        if (spanUs < MIN_SPAN_US) return null
        var bytes = 0L
        for (sample in queue) bytes += sample.bytes
        val bps = bytes * 8_000_000L / spanUs
        return bps.coerceIn(0, Int.MAX_VALUE.toLong()).toInt()
    }

    /** The stream is gone; its samples must not survive under a reused id. */
    @Synchronized
    fun forget(stream: Int) {
        streams.remove(stream)
    }

    /** Test seam: the samples a stream holds, for the pruning check. */
    @Synchronized
    fun sampleCount(stream: Int): Int = streams[stream]?.size ?: 0

    private fun prune(queue: ArrayDeque<Sample>, nowUs: Long) {
        while (queue.isNotEmpty() && nowUs - queue.first().atUs > windowUs) {
            queue.removeFirst()
        }
    }

    companion object {
        const val WINDOW_US = 3_000_000L
        /** A 0.3 s backlogged burst is enough to measure; 0.2 s is not. */
        const val MIN_SPAN_US = 250_000L
        /** Longer than two frame intervals at 60 fps; shorter than 2 fps idle. */
        const val SAMPLE_GAP_US = 200_000L
    }
}
