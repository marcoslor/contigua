package dev.pocketdeck.server

/**
 * Outbound send queue with the protocol's priority and backpressure rules:
 * JSON > keyframes/config > delta frames, and no more than ~250 ms of queued
 * video per stream (deltas are dropped until the next keyframe, at which point
 * a sync frame is requested from the encoder).
 *
 * Delta frames rotate between streams so a busy stream cannot starve a quiet
 * one. Entries are pre-framed byte arrays ready for the socket.
 */
internal class SendQueue(
    private val maxDeltaBytesPerStream: Int = DEFAULT_MAX_DELTA_BYTES,
    private val onDeltaDrop: (stream: Int) -> Unit = {},
) {
    private val lock = Object()

    private val json = ArrayDeque<ByteArray>()
    private val control = ArrayDeque<ByteArray>()
    private val deltas = HashMap<Int, ArrayDeque<ByteArray>>()
    private val deltaOrder = ArrayDeque<Int>()
    private val deltaBytes = HashMap<Int, Int>()
    private val dropping = HashSet<Int>()
    private var closed = false

    fun enqueueJson(bytes: ByteArray) = synchronized(lock) {
        json.addLast(bytes)
        lock.notifyAll()
    }

    /** Config frames and keyframes: high priority, and they clear a dropping stream. */
    fun enqueueControl(stream: Int, bytes: ByteArray) = synchronized(lock) {
        if (stream != 0) dropping.remove(stream)
        control.addLast(bytes)
        lock.notifyAll()
    }

    fun enqueueDelta(stream: Int, bytes: ByteArray) = synchronized(lock) {
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
        if (used + bytes.size > maxDeltaBytesPerStream) {
            // Stalled consumer: drop the backlog and ask for a fresh keyframe.
            q.clear()
            deltas.remove(stream)
            deltaOrder.remove(stream)
            deltaBytes[stream] = 0
            dropping.add(stream)
            if (stream != 0) onDeltaDrop(stream)
            return
        }
        q.addLast(bytes)
        deltaBytes[stream] = used + bytes.size
        lock.notifyAll()
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
        val n = deltaOrder.size
        repeat(n) {
            val stream = deltaOrder.removeFirst()
            val q = deltas[stream] ?: return@repeat
            val bytes = q.removeFirstOrNull()
            if (bytes == null) {
                deltas.remove(stream)
                deltaBytes.remove(stream)
                return@repeat
            }
            deltaBytes[stream] = (deltaBytes[stream] ?: bytes.size) - bytes.size
            if (q.isEmpty()) {
                deltas.remove(stream)
                deltaBytes.remove(stream)
            } else {
                deltaOrder.addLast(stream)
            }
            return bytes
        }
        return null
    }

    companion object {
        const val DEFAULT_MAX_DELTA_BYTES = 256 * 1024 // ~250 ms at 8 Mbps
    }
}
