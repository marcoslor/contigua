package app.contigua.server

/**
 * A stream's recent queue delay: how long a delta waited between its enqueue
 * and the end of its socket write, over the last [windowUs].
 *
 * This is the early signal's input (PATH-47). It is separate from the 2 s
 * `stream.stats` ring because the controller must read it every window even
 * when the Mac never asked for stats, and a missing sample is not a calm link:
 * [p95Us] returns null when writes stopped (a drop episode), so the controller
 * ignores that window instead of counting it as recovery.
 *
 * Pure and clock-explicit: the caller passes the writer's monotonic clock.
 */
internal class QueueDelayMeter(
    private val windowUs: Long = WINDOW_US,
    private val minSamples: Int = MIN_SAMPLES,
) {
    private class Sample(val atUs: Long, val delayUs: Long, val bytes: Int)

    private val streams = HashMap<Int, ArrayDeque<Sample>>()

    /** One written video entry's delay and bytes; entries that never queued are not samples. */
    @Synchronized
    fun note(stream: Int, atUs: Long, delayUs: Long, bytes: Int = 0) {
        if (stream <= 0 || delayUs < 0 || delayUs > MAX_DELAY_US) return
        val queue = streams.getOrPut(stream) { ArrayDeque() }
        val last = queue.lastOrNull()
        // A backwards clock starts a new window rather than corrupting one.
        if (last != null && atUs < last.atUs) queue.clear()
        queue.addLast(Sample(atUs, delayUs, bytes.coerceAtLeast(0)))
        prune(queue, atUs)
    }

    /**
     * The nearest-rank p95 of the samples inside the window, or null when the
     * window has too few samples (a still screen, a drop episode, a pause).
     */
    @Synchronized
    fun p95Us(stream: Int, nowUs: Long): Long? = percentile(stream, nowUs, 95)

    /**
     * The median: the standing queue, with a stall every 2 s (10 % of the
     * samples) excluded from the tail. The controller's calm check reads it.
     */
    @Synchronized
    fun p50Us(stream: Int, nowUs: Long): Long? = percentile(stream, nowUs, 50)

    private fun percentile(stream: Int, nowUs: Long, pct: Int): Long? {
        val queue = streams[stream] ?: return null
        prune(queue, nowUs)
        if (queue.size < minSamples) return null
        val sorted = queue.map { it.delayUs }.sorted()
        return sorted[((sorted.size - 1) * pct / 100)]
    }

    /**
     * The link's pace from the newest run of entries that waited at least
     * [minWaitUs]: a shallow queue reads the app's own rate, so only a deep run
     * measures the link. Gaps longer than [maxGapUs] (a stall) start a new run,
     * and the span is the samples' own, never including the idle tail.
     * @return bits per second, or null under [minSpanUs] of dense samples.
     */
    @Synchronized
    fun deepRateBps(
        stream: Int,
        nowUs: Long,
        minWaitUs: Long = DEEP_WAIT_US,
        minSpanUs: Long = MIN_RATE_SPAN_US,
        maxGapUs: Long = MAX_RATE_GAP_US,
    ): Int? {
        val queue = streams[stream] ?: return null
        prune(queue, nowUs)
        val newest = queue.lastOrNull() ?: return null
        if (newest.delayUs < minWaitUs) return null
        if (nowUs - newest.atUs > RATE_STALE_US) return null
        var bytes = 0L
        var firstAtUs = newest.atUs
        var previousAtUs = newest.atUs
        for (sample in queue.asReversed()) {
            if (sample.delayUs < minWaitUs) break
            if (previousAtUs - sample.atUs > maxGapUs) break
            bytes += sample.bytes
            firstAtUs = sample.atUs
            previousAtUs = sample.atUs
        }
        val spanUs = newest.atUs - firstAtUs
        if (spanUs < minSpanUs || bytes <= 0) return null
        return (bytes * 8_000_000L / spanUs).coerceIn(0, Int.MAX_VALUE.toLong()).toInt()
    }

    /** The samples still inside the window (tests and the field log). */
    @Synchronized
    fun sampleCount(stream: Int, nowUs: Long): Int {
        val queue = streams[stream] ?: return 0
        prune(queue, nowUs)
        return queue.size
    }

    /** The stream is gone; its samples must not survive under a reused id. */
    @Synchronized
    fun forget(stream: Int) {
        streams.remove(stream)
    }

    private fun prune(queue: ArrayDeque<Sample>, nowUs: Long) {
        while (queue.isNotEmpty() && nowUs - queue.first().atUs > windowUs) {
            queue.removeFirst()
        }
    }

    companion object {
        /**
         * Two seconds: a 200 ms stall every 2 s is 10 % of the samples, above
         * the 5 % tail, so p95 sees the stall in every window instead of one
         * window in four. The controller reads it once a second.
         */
        const val WINDOW_US = 2_000_000L

        /** A 60 fps window holds 30; an 8-sample burst is still a measured stall. */
        const val MIN_SAMPLES = 8

        /** Longer than a stalled clock; such a sample is not a queue delay. */
        const val MAX_DELAY_US = 30_000_000L

        /**
         * The early signal's own threshold: a frame that waited 30 ms is
         * behind a standing queue, while a shallow queue reads the app's rate.
         * It is lower than the 100 ms p95 line because a crowded link's queue
         * sits in the 30–100 ms band between spikes, and the pacing run is what
         * the controller needs.
         */
        const val DEEP_WAIT_US = 30_000L

        /** A tenth of a second behind the link is enough for the early signal. */
        const val MIN_RATE_SPAN_US = 100_000L

        /** Gaps longer than three frames are a stall, not the link's pace. */
        const val MAX_RATE_GAP_US = 50_000L

        /** A run whose newest sample is older than this says nothing now. */
        const val RATE_STALE_US = 200_000L
    }
}
