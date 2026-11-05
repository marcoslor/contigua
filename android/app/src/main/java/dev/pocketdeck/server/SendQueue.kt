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
/** A stream's delta counters since the previous snapshot, plus its drop-gap sum. */
internal data class DeltaStats(val dropped: Int, val episodes: Int, val gapMs: Long = 0)

internal class SendQueue(
    private val maxDeltaBytesPerStream: Int = DEFAULT_MAX_DELTA_BYTES,
    private val maxDeltaDurationUs: Long = DEFAULT_MAX_DELTA_DURATION_US,
    private val maxBulkBytes: Int = DEFAULT_MAX_BULK_BYTES,
    private val maxAudioBytes: Int = DEFAULT_MAX_AUDIO_BYTES,
    private val nowUs: () -> Long = { 0L },
    /** Q1's suspend clock, the same monotonic milliseconds as the session tick. */
    private val nowMs: () -> Long = { nowUs() / 1000 },
    private val onDeltaDrop: (stream: Int) -> Unit = {},
    /**
     * Q1/Q2: a stream's queue budget and overflow policy, read once when its
     * first delta is queued. The default is today's 250 ms drop policy.
     */
    private val policyFor: (stream: Int) -> QueuePolicy =
        { QueuePolicy.today(maxDeltaBytesPerStream, maxDeltaDurationUs) },
    /** Q1: the queue overflowed under `overflow=suspend`; lower the bitrate. */
    private val onOverflow: (stream: Int) -> Unit = {},
    /**
     * Q1: this stream's suspend state may have changed. The session reads
     * [isSuspended] and applies it, so an apply that ran late still applies the
     * latest state rather than a stale edge.
     */
    private val onSuspendChanged: (stream: Int) -> Unit = { _ -> },
    private val log: (String) -> Unit = {},
) {
    /** One queued frame: the bytes plus the stream, enqueue clock and capture pts. */
    class Entry(val bytes: ByteArray, val stream: Int = 0, val enqueuedUs: Long = 0,
                val ptsUs: Long = -1)

    private val lock = Object()

    private val json = ArrayDeque<Entry>()
    private val control = ArrayDeque<Entry>()
    private val audio = ArrayDeque<Entry>()
    private var audioBytes = 0
    private val deltas = HashMap<Int, ArrayDeque<Entry>>()
    private val deltaOrder = ArrayDeque<Int>()
    private val deltaBytes = HashMap<Int, Int>()
    private val deltaFirstPtsUs = HashMap<Int, Long>()
    private val deltaLastPtsUs = HashMap<Int, Long>()
    private val policies = HashMap<Int, QueuePolicy>()
    private val overflowStates = HashMap<Int, OverflowState>()
    /** When each suspended stream's episode began; Q1's tick deadline. */
    private val suspendSinceMs = HashMap<Int, Long>()
    /** Streams whose encoder must resume; performed outside the lock. */
    private val pendingResumes = ArrayList<Int>()
    private val dropping = HashSet<Int>()
    private val dropCounts = HashMap<Int, Int>()
    private val dropEpisodes = HashMap<Int, Int>()
    /** The pts of the last frame the writer sent, per stream. */
    private val lastSentPtsUs = HashMap<Int, Long>()
    /** The last sent pts before the open drop episode's first discarded delta. */
    private val dropStartPtsUs = HashMap<Int, Long>()
    /** A drop episode's pts span in ms, measured when flow resumes. */
    private val dropGapMs = HashMap<Int, Long>()
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
     * A suspended stream resumes: its backlog is gone.
     *
     * [ptsUs] is the keyframe's capture time, or -1 for a config or JSON. The
     * first frame sent after a drop episode is usually this keyframe, so its
     * pts closes the episode's gap.
     */
    fun enqueueControl(stream: Int, bytes: ByteArray, ptsUs: Long = -1) {
        var changed = false
        synchronized(lock) {
            if (stream != 0) {
                dropping.remove(stream)
                discardDeltas(stream)
                val before = overflowStates[stream]
                if (before != null && before != OverflowState.Flowing) {
                    changed = setOverflowState(
                        stream, overflowStep(before, OverflowEvent.Control))
                }
            }
            control.addLast(Entry(bytes, stream, ptsUs = ptsUs))
            lock.notifyAll()
        }
        if (changed) onSuspendChanged(stream)
    }

    fun enqueueDelta(stream: Int, ptsUs: Long, bytes: ByteArray) {
        var dropped = false
        var overflow = false
        var suspendChanged = false
        synchronized(lock) {
            if (stream in dropping) {
                // Still waiting for the keyframe: this delta is discarded too.
                dropCounts[stream] = (dropCounts[stream] ?: 0) + 1
                return
            }
            // Read the queue switch only when this stream's first delta is
            // actually queued; never per frame.
            val policy = policyOf(stream)
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
            val overBytes = used + bytes.size > policy.maxBytes
            val overDuration = ptsUs - firstPts > policy.maxDurationUs
            if ((overBytes || overDuration) && policy.overflow == StreamStrategy.Overflow.Suspend) {
                val before = overflowStates[stream] ?: OverflowState.Flowing
                val step = overflowStep(before, OverflowEvent.Pressure(used + bytes.size > policy.hardBytes))
                suspendChanged = setOverflowState(stream, step)
                for (action in step.actions) {
                    when (action) {
                        OverflowAction.SuspendEncoder, OverflowAction.ResumeEncoder -> Unit
                        OverflowAction.LowerBitrate -> overflow = true
                        OverflowAction.DropAndKeyframe -> {
                            noteDropStarted(stream)
                            val discarded = discardDeltas(stream) + 1
                            dropCounts[stream] = (dropCounts[stream] ?: 0) + discarded
                            dropEpisodes[stream] = (dropEpisodes[stream] ?: 0) + 1
                            dropping.add(stream)
                            dropped = stream != 0
                        }
                    }
                }
                if (step.state == OverflowState.FallbackDropped) return@synchronized
            } else if (overBytes || overDuration) {
                // Stalled consumer: drop the backlog and ask for a fresh keyframe.
                noteDropStarted(stream)
                val discarded = discardDeltas(stream) + 1
                dropCounts[stream] = (dropCounts[stream] ?: 0) + discarded
                dropEpisodes[stream] = (dropEpisodes[stream] ?: 0) + 1
                dropping.add(stream)
                dropped = stream != 0
                return@synchronized
            }
            q.addLast(Entry(bytes, stream, nowUs(), ptsUs))
            deltaBytes[stream] = used + bytes.size
            deltaFirstPtsUs[stream] = firstPts
            deltaLastPtsUs[stream] = ptsUs
            lock.notifyAll()
        }
        // The callbacks reach the display (keyframe request, backpressure,
        // codec parameters), and a display busy opening another window can
        // take seconds. Under this lock it stopped the writer and every other
        // stream with it; run it free.
        if (suspendChanged) onSuspendChanged(stream)
        if (dropped) onDeltaDrop(stream)
        if (overflow) onOverflow(stream)
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

    /** The deltas discarded, the drop episodes and their pts-gap sum; resets them. */
    fun takeDeltaStats(stream: Int): DeltaStats = synchronized(lock) {
        val dropped = dropCounts.remove(stream) ?: 0
        val episodes = dropEpisodes.remove(stream) ?: 0
        val gap = dropGapMs.remove(stream) ?: 0
        DeltaStats(dropped, episodes, gap)
    }

    /** The stream is gone: no pending episode may pair with a reused id. */
    fun forget(stream: Int) = synchronized(lock) {
        lastSentPtsUs.remove(stream)
        dropStartPtsUs.remove(stream)
        dropGapMs.remove(stream)
        overflowStates.remove(stream)
        suspendSinceMs.remove(stream)
    }

    private fun discardDeltas(stream: Int): Int {
        val removed = deltas.remove(stream)?.size ?: 0
        deltaOrder.remove(stream)
        deltaBytes[stream] = 0
        deltaFirstPtsUs.remove(stream)
        deltaLastPtsUs.remove(stream)
        return removed
    }

    /** Non-blocking dequeue; null when nothing is queued. */
    fun pollNow(): Entry? {
        val entry = synchronized(lock) { takeLocked() }
        flushResumes()
        return entry
    }

    /** Blocks until an entry is available, or returns null once [close] was called. */
    fun poll(): Entry? {
        val entry = synchronized(lock) { awaitLocked() }
        flushResumes()
        return entry
    }

    private fun awaitLocked(): Entry? {
        while (true) {
            takeLocked()?.let { return it }
            if (closed) return null
            lock.wait()
        }
    }

    /** The suspended encoders a dequeue brought below half their budget. */
    private fun flushResumes() {
        val streams = synchronized(lock) {
            if (pendingResumes.isEmpty()) return
            pendingResumes.toList().also { pendingResumes.clear() }
        }
        for (stream in streams) onSuspendChanged(stream)
    }

    fun close() = synchronized(lock) {
        closed = true
        lock.notifyAll()
    }

    private fun takeLocked(): Entry? {
        val entry = takeLockedEntry() ?: return null
        noteSent(entry)
        return entry
    }

    private fun takeLockedEntry(): Entry? {
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
                deltaLastPtsUs.remove(stream)
                return@repeat
            }
            deltaBytes[stream] = (deltaBytes[stream] ?: entry.bytes.size) - entry.bytes.size
            if (q.isEmpty()) {
                deltas.remove(stream)
                deltaBytes.remove(stream)
                deltaFirstPtsUs.remove(stream)
                deltaLastPtsUs.remove(stream)
            } else {
                // The oldest queued frame is now this one: the duration rule
                // must not keep measuring from a frame that already left.
                deltaFirstPtsUs[stream] = q.first().ptsUs
                deltaOrder.addLast(stream)
            }
            maybeResume(stream)
            return entry
        }
        val entry = bulk.removeFirstOrNull() ?: return null
        bulkBytes -= entry.bytes.size
        lock.notifyAll()
        return entry
    }

    /** A frame is about to leave for the socket; the drop gap is measured here. */
    private fun noteSent(entry: Entry) {
        if (entry.ptsUs < 0) return
        val stream = entry.stream
        val start = dropStartPtsUs.remove(stream)
        if (start != null) {
            val gapUs = (entry.ptsUs - start - FRAME_INTERVAL_US).coerceAtLeast(0)
            dropGapMs[stream] = (dropGapMs[stream] ?: 0) + (gapUs + 500) / 1000
        }
        lastSentPtsUs[stream] = entry.ptsUs
    }

    /** The first delta a drop discards starts the episode's gap at the last sent frame. */
    private fun noteDropStarted(stream: Int) {
        if (stream == 0 || dropStartPtsUs.containsKey(stream)) return
        lastSentPtsUs[stream]?.let { dropStartPtsUs[stream] = it }
    }

    /** The budget and policy for [stream], read once at its first delta. */
    private fun policyOf(stream: Int): QueuePolicy =
        policies.getOrPut(stream) { policyFor(stream) }

    /** Applies [step]; true when the state, not just the event, changed. */
    private fun setOverflowState(stream: Int, step: OverflowStep): Boolean {
        val before = overflowStates[stream] ?: OverflowState.Flowing
        if (step.state == OverflowState.Flowing) overflowStates.remove(stream)
        else overflowStates[stream] = step.state
        if (step.state == OverflowState.Suspended) {
            if (before != OverflowState.Suspended) suspendSinceMs[stream] = nowMs()
        } else {
            suspendSinceMs.remove(stream)
        }
        if (before == step.state) return false
        log("stream $stream overflow: ${before.wire} --${step.event}--> ${step.state.wire}")
        return true
    }

    /** Q1: the machine's current state, read under the queue lock. */
    fun isSuspended(stream: Int): Boolean = synchronized(lock) {
        overflowStates[stream] == OverflowState.Suspended
    }

    /**
     * Q1's safety net, fed by the session's existing ticker (no new timer): a
     * suspended stream resumes when its backlog is under half, and one second
     * after the suspend began it resumes whatever the backlog says. The state
     * is applied afterwards, outside the lock.
     */
    fun tick(nowMs: Long) {
        val resumed = ArrayList<Int>()
        val timeouts = ArrayList<Int>()
        synchronized(lock) {
            for (stream in overflowStates.keys.toList()) {
                if (overflowStates[stream] != OverflowState.Suspended) continue
                val since = suspendSinceMs[stream] ?: nowMs
                val step = overflowStep(
                    OverflowState.Suspended,
                    OverflowEvent.Tick(nowMs, since, backlogUnderHalf(stream)),
                )
                if (!setOverflowState(stream, step)) continue
                resumed.add(stream)
                if (step.event == "timeout") timeouts.add(stream)
            }
        }
        for (stream in resumed) onSuspendChanged(stream)
        for (stream in timeouts) log("stream $stream overflow: suspend timeout")
    }

    /** Q1: when the next suspended stream's timeout falls due, or null. */
    fun nextSuspendDeadlineMs(): Long? = synchronized(lock) {
        overflowStates.keys.mapNotNull { stream ->
            if (overflowStates[stream] != OverflowState.Suspended) return@mapNotNull null
            suspendSinceMs[stream]?.plus(SUSPEND_TIMEOUT_MS)
        }.minOrNull()
    }

    /** Q1: a dequeue brought this stream's backlog below half its budget. */
    private fun maybeResume(stream: Int) {
        if (overflowStates[stream] != OverflowState.Suspended) return
        if (!backlogUnderHalf(stream)) return
        val step = overflowStep(OverflowState.Suspended, OverflowEvent.Drained)
        if (setOverflowState(stream, step)) pendingResumes.add(stream)
    }

    /**
     * Q1's drained rule. An absent or empty backlog is zero bytes and zero
     * span: after the last delta left, there is nothing left to wait for (the
     * per-stream maps are gone by then, and the old early return stranded the
     * encoder).
     */
    private fun backlogUnderHalf(stream: Int): Boolean {
        val policy = policyOf(stream)
        val queued = deltas[stream]
        val empty = queued == null || queued.isEmpty()
        val used = if (empty) 0 else deltaBytes[stream] ?: 0
        val first = if (empty) 0L else deltaFirstPtsUs[stream] ?: 0L
        val last = if (empty) 0L else deltaLastPtsUs[stream] ?: 0L
        return used <= policy.maxBytes / 2 && last - first <= policy.maxDurationUs / 2
    }

    companion object {
        const val DEFAULT_MAX_DELTA_BYTES = 256 * 1024 // ~250 ms at 8 Mbps

        /** The protocol's ~250 ms of queued video, independent of the bitrate. */
        const val DEFAULT_MAX_DELTA_DURATION_US = 250_000L

        /** One frame at 60 fps: the drop gap is a span of missing frames, not of time. */
        const val FRAME_INTERVAL_US = 16_667L

        const val DEFAULT_MAX_BULK_BYTES = 1024 * 1024

        /** ~250 ms of Opus at 64 kbps is 2 KB; 32 KB leaves headroom for AAC. */
        const val DEFAULT_MAX_AUDIO_BYTES = 32 * 1024
    }
}
