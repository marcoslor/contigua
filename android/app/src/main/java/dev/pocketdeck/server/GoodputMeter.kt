package dev.pocketdeck.server

/**
 * The video bytes a stream actually got out of the send queue in the recent
 * window (P4's fallback arm). The TCP sender's queue drain rate is the only
 * throughput signal available without TCP_INFO, and while the queue is
 * backlogged it is the link's rate: the kernel accepts bytes at the rate the
 * path can carry them.
 *
 * Pure and clock-explicit so the policy test can drive a shaped link: note
 * each written entry with the session's monotonic µs, then ask for the rate at
 * the moment a drop happens. A window shorter than [MIN_SPAN_US] says nothing
 * (nil), so the first burst of a just-opened stream cannot fake a cap.
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
        if (queue.isNotEmpty() && nowUs < queue.last().atUs) queue.clear() // a clock jump
        queue.addLast(Sample(nowUs, bytes))
    }

    /**
     * Bits per second over the samples still inside the window, or nil when
     * the stream has less than [MIN_SPAN_US] of evidence.
     */
    @Synchronized
    fun rateBps(stream: Int, nowUs: Long): Int? {
        val queue = streams[stream] ?: return null
        while (queue.isNotEmpty() && nowUs - queue.first().atUs > windowUs) queue.removeFirst()
        if (queue.isEmpty()) return null
        val spanUs = nowUs - queue.first().atUs
        if (spanUs < MIN_SPAN_US) return null
        var bytes = 0L
        for (sample in queue) bytes += sample.bytes
        val bps = bytes * 8_000_000L / spanUs
        return bps.coerceIn(0, Int.MAX_VALUE.toLong()).toInt()
    }

    companion object {
        const val WINDOW_US = 3_000_000L
        const val MIN_SPAN_US = 500_000L
    }
}
