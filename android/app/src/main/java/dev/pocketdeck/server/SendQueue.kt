package dev.pocketdeck.server

/**
 * Outbound send queue with the protocol's priority and backpressure rules:
 * JSON > keyframes/config > audio > delta frames, and no more than ~250 ms of queued
 * video per stream (deltas are dropped until the next keyframe, at which point
 * a sync frame is requested from the encoder). Audio has its own ~250 ms
 * budget; oldest packets are dropped first so the stream stays realtime.
 *
 * "250 ms" is enforced two ways: a byte budget (~250 ms at the 8 Mbps cap) and
 * the *video duration* between the oldest queued delta and the frame being
 * enqueued. The byte budget alone lets a low-bitrate stream queue seconds of
 * video (at 1 Mbps, 256 KB is two seconds), so the duration rule is what keeps
 * the promise for slow streams — and what makes the drop visible on devices
 * whose renderer produces few, large frames.
 *
 * Delta frames rotate between streams so a busy stream cannot starve a quiet
 * one. Bulk data (shared files) comes last, and its producer blocks while
 * [maxBulkBytes] are queued, so a large file is never held in memory and never
 * delays replies or video. Entries are pre-framed byte arrays ready for the
 * socket.
 *
 * Each entry also carries the monotonic µs it was enqueued at (delta frames
 * only; ISS-40's queue-delay metric) and its stream, so the writer can report
 * a frame's delivery without a lookup. The delta drop counters live here too:
 * a queue that is dropping still counts every discarded delta, and the session
 * reads them when it builds `stream.stats`.
 */
internal class SendQueue(
    private val maxDeltaBytesPerStream: Int = DEFAULT_MAX_DELTA_BYTES,
    private val maxDeltaDurationUs: Long = DEFAULT_MAX_DELTA_DURATION_US,
    private val maxBulkBytes: Int = DEFAULT_MAX_BULK_BYTES,
    private val maxAudioBytes: Int = DEFAULT_MAX_AUDIO_BYTES,
    private val nowUs: () -> Long = { 0L },
    private val onDeltaDrop: (stream: Int) -> Unit = {},
) {
    /** One queued frame: the bytes plus the stream and enqueue clock. */
    class Entry(val bytes: ByteArray, val stream: Int = 0, val enqueuedUs: Long = 0)

    private val lock = Object()

    private val json = ArrayDeque<Entry>()
    private val control = ArrayDeque<Entry>()
    private val audio = ArrayDeque<Entry>()
    private var audioBytes = 0
    private val deltas = HashMap<Int, ArrayDeque<Entry>>()
    private val deltaOrder = ArrayDeque<Int>()
    private val deltaBytes = HashMap<Int, Int>()
    private val deltaFirstPtsUs = HashMap<Int, Long>()
    private val dropping = HashSet<Int>()
    private val dropCounts = HashMap<Int, Int>()
    private val dropEpisodes = HashMap<Int, Int>()
    private val bulk = ArrayDeque<Entry>()
    private var bulkBytes = 0
    private var closed = false

    fun enqueueJson(bytes: ByteArray) = synchronized(lock) {
        json.addLast(Entry(bytes))
        lock.notifyAll()
    }

    /** Device-wide audio (Opus/AAC packets): after control, before video deltas. */
    fun enqueueAudio(bytes: ByteArray) = synchronized(lock) {
        audio.addLast(Entry(bytes))
        audioBytes += bytes.size
        while (audioBytes > maxAudioBytes && audio.isNotEmpty()) {
            audioBytes -= audio.removeFirst().bytes.size
        }
        lock.notifyAll()
    }

    fun clearAudio() = synchronized(lock) {
        audio.clear()
        audioBytes = 0
    }

    /**
     * Config frames and keyframes: high priority, and they clear a dropping
     * stream. They also discard the stream's queued deltas: control is served
     * first, so those deltas would otherwise reach the Mac *after* the new
     * config (a resize: old-size frames against the new format description).
     */
    fun enqueueControl(stream: Int, bytes: ByteArray) = synchronized(lock) {
        if (stream != 0) {
            dropping.remove(stream)
            discardDeltas(stream)
        }
        control.addLast(Entry(bytes, stream))
        lock.notifyAll()
    }

    fun enqueueDelta(stream: Int, ptsUs: Long, bytes: ByteArray) {
        var dropped = false
        synchronized(lock) {
            if (stream in dropping) {
                // Still waiting for the keyframe: this delta is discarded too.
                dropCounts[stream] = (dropCounts[stream] ?: 0) + 1
                return
            }
            val existing = deltas[stream]
            val q: ArrayDeque<Entry>
            if (existing == null) {
                q = ArrayDeque()
                deltas[stream] = q
                deltaOrder.addLast(stream)
            } else {
                q = existing
            }
            val used = deltaBytes[stream] ?: 0
            val firstPts = deltaFirstPtsUs[stream] ?: ptsUs
            if (used + bytes.size > maxDeltaBytesPerStream || ptsUs - firstPts > maxDeltaDurationUs) {
                // Stalled consumer: drop the backlog and ask for a fresh keyframe.
                val discarded = discardDeltas(stream) + 1
                dropCounts[stream] = (dropCounts[stream] ?: 0) + discarded
                dropEpisodes[stream] = (dropEpisodes[stream] ?: 0) + 1
                dropping.add(stream)
                dropped = stream != 0
                return@synchronized
            }
            q.addLast(Entry(bytes, stream, nowUs()))
            deltaBytes[stream] = used + bytes.size
            deltaFirstPtsUs[stream] = firstPts
            lock.notifyAll()
        }
        // The drop callback reaches the display (keyframe request, backpressure),
        // and a display busy opening another window can take seconds. Under this
        // lock it stopped the writer and every other stream with it; run it free.
        if (dropped) onDeltaDrop(stream)
    }

    /**
     * Lowest priority. Blocks while the bulk lane holds [maxBulkBytes] (one entry is
     * always accepted); false once the queue is closed.
     */
    fun enqueueBulk(bytes: ByteArray): Boolean = synchronized(lock) {
        while (!closed && bulkBytes > 0 && bulkBytes + bytes.size > maxBulkBytes) lock.wait()
        if (closed) return false
        bulk.addLast(Entry(bytes))
        bulkBytes += bytes.size
        lock.notifyAll()
        true
    }

    /** The deltas discarded and the drop episodes for [stream]; resets them. */
    fun takeDeltaStats(stream: Int): Pair<Int, Int> = synchronized(lock) {
        val dropped = dropCounts.remove(stream) ?: 0
        val episodes = dropEpisodes.remove(stream) ?: 0
        dropped to episodes
    }

    private fun discardDeltas(stream: Int): Int {
        val removed = deltas.remove(stream)?.size ?: 0
        deltaOrder.remove(stream)
        deltaBytes[stream] = 0
        deltaFirstPtsUs.remove(stream)
        return removed
    }

    /** Non-blocking dequeue; null when nothing is queued. */
    fun pollNow(): Entry? = synchronized(lock) { takeLocked() }

    /** Blocks until an entry is available, or returns null once [close] was called. */
    fun poll(): Entry? {
        synchronized(lock) {
            while (true) {
                takeLocked()?.let { return it }
                if (closed) return null
                lock.wait()
            }
        }
    }

    fun close() = synchronized(lock) {
        closed = true
        lock.notifyAll()
    }

    private fun takeLocked(): Entry? {
        json.removeFirstOrNull()?.let { return it }
        control.removeFirstOrNull()?.let { return it }
        audio.removeFirstOrNull()?.let {
            audioBytes -= it.bytes.size
            return it
        }
        val n = deltaOrder.size
        repeat(n) {
            val stream = deltaOrder.removeFirst()
            val q = deltas[stream] ?: return@repeat
            val entry = q.removeFirstOrNull()
            if (entry == null) {
                deltas.remove(stream)
                deltaBytes.remove(stream)
                deltaFirstPtsUs.remove(stream)
                return@repeat
            }
            deltaBytes[stream] = (deltaBytes[stream] ?: entry.bytes.size) - entry.bytes.size
            if (q.isEmpty()) {
                deltas.remove(stream)
                deltaBytes.remove(stream)
                deltaFirstPtsUs.remove(stream)
            } else {
                deltaOrder.addLast(stream)
            }
            return entry
        }
        val entry = bulk.removeFirstOrNull() ?: return null
        bulkBytes -= entry.bytes.size
        lock.notifyAll()
        return entry
    }

    companion object {
        const val DEFAULT_MAX_DELTA_BYTES = 256 * 1024 // ~250 ms at 8 Mbps

        /** The protocol's ~250 ms of queued video, independent of the bitrate. */
        const val DEFAULT_MAX_DELTA_DURATION_US = 250_000L

        const val DEFAULT_MAX_BULK_BYTES = 1024 * 1024

        /** ~250 ms of Opus at 64 kbps is 2 KB; 32 KB leaves headroom for AAC. */
        const val DEFAULT_MAX_AUDIO_BYTES = 32 * 1024
    }
}
