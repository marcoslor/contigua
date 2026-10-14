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
 * delays replies or video. Entries are pre-framed byte arrays ready for the socket.
 */
internal class SendQueue(
    private val maxDeltaBytesPerStream: Int = DEFAULT_MAX_DELTA_BYTES,
    private val maxDeltaDurationUs: Long = DEFAULT_MAX_DELTA_DURATION_US,
    private val maxBulkBytes: Int = DEFAULT_MAX_BULK_BYTES,
    private val maxAudioBytes: Int = DEFAULT_MAX_AUDIO_BYTES,
    private val onDeltaDrop: (stream: Int) -> Unit = {},
) {
    private val lock = Object()

    private val json = ArrayDeque<ByteArray>()
    private val control = ArrayDeque<ByteArray>()
    private val audio = ArrayDeque<ByteArray>()
    private var audioBytes = 0
    private val deltas = HashMap<Int, ArrayDeque<ByteArray>>()
    private val deltaOrder = ArrayDeque<Int>()
    private val deltaBytes = HashMap<Int, Int>()
    private val deltaFirstPtsUs = HashMap<Int, Long>()
    private val dropping = HashSet<Int>()
    private val bulk = ArrayDeque<ByteArray>()
    private var bulkBytes = 0
    private var closed = false

    fun enqueueJson(bytes: ByteArray) = synchronized(lock) {
        json.addLast(bytes)
        lock.notifyAll()
    }

    /** Device-wide audio (Opus/AAC packets): after control, before video deltas. */
    fun enqueueAudio(bytes: ByteArray) = synchronized(lock) {
        audio.addLast(bytes)
        audioBytes += bytes.size
        while (audioBytes > maxAudioBytes && audio.isNotEmpty()) {
            audioBytes -= audio.removeFirst().size
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
        control.addLast(bytes)
        lock.notifyAll()
    }

    fun enqueueDelta(stream: Int, ptsUs: Long, bytes: ByteArray) = synchronized(lock) {
        if (stream in dropping) return
        val existing = deltas[stream]
        val q: ArrayDeque<ByteArray>
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
            discardDeltas(stream)
            dropping.add(stream)
            if (stream != 0) onDeltaDrop(stream)
            return
        }
        q.addLast(bytes)
        deltaBytes[stream] = used + bytes.size
        deltaFirstPtsUs[stream] = firstPts
        lock.notifyAll()
    }

    /**
     * Lowest priority. Blocks while the bulk lane holds [maxBulkBytes] (one entry is
     * always accepted); false once the queue is closed.
     */
    fun enqueueBulk(bytes: ByteArray): Boolean = synchronized(lock) {
        while (!closed && bulkBytes > 0 && bulkBytes + bytes.size > maxBulkBytes) lock.wait()
        if (closed) return false
        bulk.addLast(bytes)
        bulkBytes += bytes.size
        lock.notifyAll()
        true
    }

    private fun discardDeltas(stream: Int) {
        deltas.remove(stream)?.clear()
        deltaOrder.remove(stream)
        deltaBytes[stream] = 0
        deltaFirstPtsUs.remove(stream)
    }

    /** Non-blocking dequeue; null when nothing is queued. */
    fun pollNow(): ByteArray? = synchronized(lock) { takeLocked() }

    /** Blocks until an entry is available, or returns null once [close] was called. */
    fun poll(): ByteArray? {
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

    private fun takeLocked(): ByteArray? {
        json.removeFirstOrNull()?.let { return it }
        control.removeFirstOrNull()?.let { return it }
        audio.removeFirstOrNull()?.let {
            audioBytes -= it.size
            return it
        }
        val n = deltaOrder.size
        repeat(n) {
            val stream = deltaOrder.removeFirst()
            val q = deltas[stream] ?: return@repeat
            val bytes = q.removeFirstOrNull()
            if (bytes == null) {
                deltas.remove(stream)
                deltaBytes.remove(stream)
                deltaFirstPtsUs.remove(stream)
                return@repeat
            }
            deltaBytes[stream] = (deltaBytes[stream] ?: bytes.size) - bytes.size
            if (q.isEmpty()) {
                deltas.remove(stream)
                deltaBytes.remove(stream)
                deltaFirstPtsUs.remove(stream)
            } else {
                deltaOrder.addLast(stream)
            }
            return bytes
        }
        val bytes = bulk.removeFirstOrNull() ?: return null
        bulkBytes -= bytes.size
        lock.notifyAll()
        return bytes
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
