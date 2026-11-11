package app.contigua.server

import app.contigua.proto.Frames

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
     * The measured link rate for this stream (the writer's goodput), or null
     * when it is not known. The overrun budget scales with it; without it the
     * encoder's own measured output is used, then the believed target.
     */
    private val linkBpsFor: (stream: Int) -> Int? = { null },
    /** The stream's codec for the drop line's NAL types (AVC unless HEVC is on). */
    private val codecFor: (stream: Int) -> VideoCodec = { VideoCodec.Avc },
    /**
     * Q1: this stream's suspend state may have changed. The session reads
     * [isSuspended] and applies it, so an apply that ran late still applies the
     * latest state rather than a stale edge.
     */
    private val onSuspendChanged: (stream: Int) -> Unit = { _ -> },
    private val log: (String) -> Unit = {},
    /**
     * A drop episode is still waiting for its key [KEY_RETRY_MS] after the
     * last request: ask again (the first request can be lost or answered by
     * nothing, and without a key the window stays frozen).
     */
    private val onKeyRetry: (stream: Int) -> Unit = {},
) {
    /** When each dropping stream last asked for its key (the drop or a retry). */
    private val keyAskedAtMs = HashMap<Int, Long>()

    /** One queued frame: the bytes plus the stream, enqueue clock and capture pts. */
    class Entry(val bytes: ByteArray, override val stream: Int = 0, val enqueuedUs: Long = 0,
                override val ptsUs: Long = -1, val key: Boolean = false,
                val audio: Boolean = false) : DeltaItem {
        override val sizeBytes: Int get() = bytes.size
    }

    /**
     * R4: a large video frame yields one ≤16 KiB wire chunk per dequeue. The
     * first chunk takes the frame's lane; the rest wait behind audio, so an
     * audio packet never waits behind more than one chunk.
     */
    class Chunked(
        val chunks: List<ByteArray>,
        override val stream: Int,
        val originalBytes: Int,
        override val ptsUs: Long,
        val key: Boolean,
        val enqueuedUs: Long,
        var next: Int,
    ) : DeltaItem {
        override val sizeBytes: Int get() = originalBytes
    }

    /** A per-stream delta queue item: a whole frame or a chunked one. */
    sealed interface DeltaItem {
        val stream: Int
        val ptsUs: Long
        val sizeBytes: Int
    }

    private val lock = Object()

    /**
     * R4: the Mac's hello asked for VIDEO_CHUNK fragments. Set once before any
     * window opens; an older Mac that does not ask keeps whole VIDEO_FRAMEs.
     */
    @Volatile
    var videoChunks: Boolean = false

    private val json = ArrayDeque<Entry>()
    private val control = ArrayDeque<Entry>()
    private val audio = ArrayDeque<Entry>()
    private var audioBytes = 0
    private var audioDropped = 0
    /** R4: keyframe remainders, after audio and before the delta lanes. */
    private val chunked = ArrayDeque<Chunked>()
    private val deltas = HashMap<Int, ArrayDeque<DeltaItem>>()
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
    /** The largest key frame's size against the byte budget, one line per new max. */
    private val keyMaxBytes = HashMap<Int, Int>()
    /** The overrun budget per stream; see [BudgetState]. */
    private val budgets = HashMap<Int, BudgetState>()
    /** The encoder's own output rate, measured from the frames it enqueues. */
    private val encodedRate = GoodputMeter(windowUs = 1_000_000L, minSpanUs = 50_000L)

    /**
     * The encoder's measured output for [stream] over the recent run, or null
     * without a sample. The closed loop on the key reads it when a drop happens;
     * it counts every encoded frame, including the ones the queue discards.
     */
    fun encoderBps(stream: Int): Int? = encodedRate.rateBps(stream, nowUs())

    /** The pts of the last frame the writer sent, per stream. */
    private val lastSentPtsUs = HashMap<Int, Long>()
    /** The last sent pts before the open drop episode's first discarded delta. */
    private val dropStartPtsUs = HashMap<Int, Long>()
    /** A drop episode's pts span in ms, measured when flow resumes. */
    private val dropGapMs = HashMap<Int, Long>()
    /** Each stream's open drop episode: what it dropped and when it began. */
    private val dropStates = HashMap<Int, DropEpisode>()
    private val bulk = ArrayDeque<Entry>()
    private var bulkBytes = 0
    private var closed = false

    fun enqueueJson(bytes: ByteArray) = synchronized(lock) {
        json.addLast(Entry(bytes))
        lock.notifyAll()
    }

    /** Device-wide audio (Opus/AAC packets): after control, before video deltas. */
    fun enqueueAudio(bytes: ByteArray, enqueuedUs: Long = 0) = synchronized(lock) {
        audio.addLast(Entry(bytes, enqueuedUs = enqueuedUs, audio = true))
        audioBytes += bytes.size
        while (audioBytes > maxAudioBytes && audio.isNotEmpty()) {
            audioBytes -= audio.removeFirst().bytes.size
            audioDropped += 1
        }
        lock.notifyAll()
    }

    /** Audio packets discarded by the realtime budget since the last read. */
    fun takeAudioDropped(): Int = synchronized(lock) {
        val dropped = audioDropped
        audioDropped = 0
        dropped
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
        var keyLog: String? = null
        var budgetLog: String? = null
        synchronized(lock) {
            if (stream != 0) {
                dropping.remove(stream)
                keyAskedAtMs.remove(stream)
                discardDeltas(stream)
                discardChunked(stream)
                // The discarded deltas were the ones the old key's credit was
                // paying for; a new control entry starts a fresh budget.
                noteDrainedIfEmpty(stream)
                val before = overflowStates[stream]
                if (before != null && before != OverflowState.Flowing) {
                    changed = setOverflowState(
                        stream, overflowStep(before, OverflowEvent.Control))
                }
            }
            // A video key frame is the only control entry with a pts; config
            // and JSON entries carry -1 and must not close a drop episode.
            val chunks = if (videoChunks && ptsUs >= 0) Frames.chunkVideoFrame(bytes) else null
            if (chunks != null) {
                // The first chunk keeps control priority; the rest wait behind
                // audio, so one large keyframe cannot starve the audio lane.
                control.addLast(Entry(chunks.first(), stream, ptsUs = ptsUs, key = true))
                chunked.addLast(Chunked(chunks, stream, bytes.size, ptsUs, key = true,
                                        enqueuedUs = nowUs(), next = 1))
            } else {
                control.addLast(Entry(bytes, stream, ptsUs = ptsUs, key = ptsUs >= 0))
            }
            if (stream != 0 && ptsUs >= 0) {
                // The whole key frame counts against the budget, chunked or not.
                encodedRate.note(stream, bytes.size, nowUs())
                val policy = policyOf(stream)
                val rate = rateBpsFor(stream, policy)
                val before = budgetOf(stream)
                val step = budgetStep(before, BudgetEvent.KeyQueued(bytes.size, rate))
                budgets[stream] = step.state
                if (step.transition) {
                    budgetLog = "stream $stream queue budget: ${before.phase.wire} " +
                        "--${step.event}--> ${step.state.phase.wire}"
                }
                if (bytes.size > (keyMaxBytes[stream] ?: 0)) {
                    keyMaxBytes[stream] = bytes.size
                    // The overrun arm needs a key frame's size against the
                    // budget it must fit in; sizes and rates only.
                    keyLog = "stream $stream key frame: bytes=${bytes.size} " +
                        "budget=${maxBytesFor(policy, step.state, rate)}"
                }
            }
            lock.notifyAll()
        }
        budgetLog?.let(log)
        keyLog?.let(log)
        if (changed) onSuspendChanged(stream)
    }

    fun enqueueDelta(stream: Int, ptsUs: Long, bytes: ByteArray) {
        var dropped = false
        var overflow = false
        var suspendChanged = false
        var retry = false
        synchronized(lock) {
            // The encoder produced this frame whatever the queue does with it.
            encodedRate.note(stream, bytes.size, nowUs())
            if (stream in dropping) {
                // Still waiting for the keyframe: this delta is discarded too.
                dropCounts[stream] = (dropCounts[stream] ?: 0) + 1
                advanceDrop(stream, DropEvent.DeltasDropped(1, nowMs()))
                val now = nowMs()
                val asked = keyAskedAtMs[stream]
                if (stream != 0 && (asked == null || now - asked >= KEY_RETRY_MS)) {
                    keyAskedAtMs[stream] = now
                    retry = true
                    log("stream $stream drop episode: waiting --retry--> waiting" +
                        (asked?.let { " (no key ${now - it} ms after the last request)" } ?: ""))
                }
                return@synchronized
            }
            // Read the queue switch only when this stream's first delta is
            // actually queued; never per frame.
            val policy = policyOf(stream)
            val budget = budgetOf(stream)
            val rate = rateBpsFor(stream, policy)
            val maxBytes = maxBytesFor(policy, budget, rate)
            val maxDurationUs = maxDurationFor(policy, budget)
            val existing = deltas[stream]
            val q: ArrayDeque<DeltaItem>
            if (existing == null) {
                q = ArrayDeque()
                deltas[stream] = q
                deltaOrder.addLast(stream)
            } else {
                q = existing
            }
            val used = deltaBytes[stream] ?: 0
            val firstPts = deltaFirstPtsUs[stream] ?: ptsUs
            val overBytes = used + bytes.size > maxBytes
            val overDuration = ptsUs - firstPts > maxDurationUs
            if ((overBytes || overDuration) && policy.overflow == StreamStrategy.Overflow.Suspend) {
                val before = overflowStates[stream] ?: OverflowState.Flowing
                val step = overflowStep(
                    before,
                    OverflowEvent.Pressure(used.toLong() + bytes.size > maxBytes.toLong() * 4),
                )
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
                            advanceDrop(stream, DropEvent.DeltasDropped(discarded, nowMs()))
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
                advanceDrop(stream, DropEvent.DeltasDropped(discarded, nowMs()))
                dropped = stream != 0
                return@synchronized
            }
            val chunks = if (videoChunks) Frames.chunkVideoFrame(bytes) else null
            if (chunks != null) {
                q.addLast(Chunked(chunks, stream, bytes.size, ptsUs, key = false,
                                  enqueuedUs = nowUs(), next = 0))
            } else {
                q.addLast(Entry(bytes, stream, nowUs(), ptsUs))
            }
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
        if (dropped) {
            synchronized(lock) { keyAskedAtMs[stream] = nowMs() }
            onDeltaDrop(stream)
        }
        if (retry) onKeyRetry(stream)
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
        discardChunked(stream)
        lastSentPtsUs.remove(stream)
        dropStartPtsUs.remove(stream)
        dropGapMs.remove(stream)
        overflowStates.remove(stream)
        suspendSinceMs.remove(stream)
        dropStates.remove(stream)
        keyMaxBytes.remove(stream)
        budgets.remove(stream)
        encodedRate.forget(stream)
    }

    private fun discardDeltas(stream: Int): Int {
        val removed = deltas.remove(stream)?.size ?: 0
        deltaOrder.remove(stream)
        deltaBytes[stream] = 0
        deltaFirstPtsUs.remove(stream)
        deltaLastPtsUs.remove(stream)
        noteDrainedIfEmpty(stream)
        return removed
    }

    /** A new control frame supersedes an older keyframe's remaining chunks. */
    private fun discardChunked(stream: Int) {
        chunked.removeAll { it.stream == stream }
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
        val controlEntry = control.removeFirstOrNull()
        if (controlEntry != null) {
            if (controlEntry.key && controlEntry.stream != 0) noteKeySent(controlEntry)
            return controlEntry
        }
        audio.removeFirstOrNull()?.let {
            audioBytes -= it.bytes.size
            return it
        }
        // R4: a keyframe's remaining chunks sit behind audio and ahead of the
        // delta lanes, one chunk per turn so a burst cannot fill the socket.
        chunked.removeFirstOrNull()?.let { item ->
            val index = item.next
            item.next += 1
            val entry = Entry(item.chunks[index], item.stream, item.enqueuedUs, item.ptsUs,
                              key = item.key && index == 0)
            if (item.next < item.chunks.size) chunked.addLast(item)
            return entry
        }
        val n = deltaOrder.size
        repeat(n) {
            val stream = deltaOrder.removeFirst()
            val q = deltas[stream] ?: return@repeat
            val item = q.removeFirstOrNull()
            if (item == null) {
                deltas.remove(stream)
                deltaBytes.remove(stream)
                deltaFirstPtsUs.remove(stream)
                deltaLastPtsUs.remove(stream)
                return@repeat
            }
            var released = 0
            val entry: Entry = when (item) {
                is Entry -> {
                    released = item.bytes.size
                    item
                }
                is Chunked -> {
                    val index = item.next
                    item.next += 1
                    if (item.next < item.chunks.size) {
                        // R5: the rest of a partly sent frame keeps the head of
                        // its lane, so a queued D2 can never go between D1's
                        // fragments (the Mac would throw D1 away and decode D2
                        // without its reference).
                        q.addFirst(item)
                    } else {
                        released = item.originalBytes
                    }
                    Entry(item.chunks[index], stream, item.enqueuedUs, item.ptsUs,
                          key = item.key && index == 0)
                }
            }
            if (released > 0) {
                deltaBytes[stream] = (deltaBytes[stream] ?: released) - released
            }
            if (q.isEmpty()) {
                deltas.remove(stream)
                deltaBytes.remove(stream)
                deltaFirstPtsUs.remove(stream)
                deltaLastPtsUs.remove(stream)
                noteDrainedIfEmpty(stream)
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
        // The first key frame handed to the socket closes the episode. Its
        // types say whether the picture can actually restart from it.
        if (entry.key) {
            val types = nalTypes(entry.bytes, offset = Frames.VIDEO_FRAME_DATA_OFFSET,
                                 codec = codecFor(stream))
            advanceDrop(stream, DropEvent.KeySent(nowMs(), types))
        }
    }

    /** Applies one drop-episode event; the machine's line is the field log. */
    private fun advanceDrop(stream: Int, event: DropEvent) {
        val before = dropStates[stream] ?: DropEpisode()
        val step = dropEpisodeTransition(stream, before, event)
        if (step.episode.phase == DropPhase.Flowing) dropStates.remove(stream)
        else dropStates[stream] = step.episode
        if (step.transition) {
            val eventWire = when (event) {
                is DropEvent.DeltasDropped -> "dropped(${event.count})"
                is DropEvent.KeySent -> "key"
            }
            log("stream $stream drop episode: ${before.phase.wire} --$eventWire--> ${step.episode.phase.wire}")
        }
        step.line?.let(log)
    }

    /** The first delta a drop discards starts the episode's gap at the last sent frame. */
    private fun noteDropStarted(stream: Int) {
        if (stream == 0 || dropStartPtsUs.containsKey(stream)) return
        lastSentPtsUs[stream]?.let { dropStartPtsUs[stream] = it }
    }

    /** The budget and policy for [stream], read once at its first delta. */
    private fun policyOf(stream: Int): QueuePolicy =
        policies.getOrPut(stream) { policyFor(stream) }

    private fun budgetOf(stream: Int): BudgetState =
        budgets.getOrPut(stream) { BudgetState() }

    /**
     * The rate the byte budget follows: the link's measured goodput when the
     * writer has one, else the encoder's own output, else the believed target.
     * A budget in bytes at this rate is the same 250 ms of *real* video, so a
     * VBR encoder at 3x its target and a 30 Mbps path both fit their bursts.
     */
    private fun rateBpsFor(stream: Int, policy: QueuePolicy): Int {
        linkBpsFor(stream)?.takeIf { it > 0 }?.let { return it }
        encodedRate.rateBps(stream, nowUs())?.takeIf { it > 0 }?.let { return it }
        return (policy.maxBytes.toLong() * 8_000_000L / policy.maxDurationUs)
            .coerceIn(1L, Int.MAX_VALUE.toLong()).toInt()
    }

    /** The byte budget: 250 ms at the measured rate, plus any key frame or its draining credit. */
    private fun maxBytesFor(policy: QueuePolicy, budget: BudgetState, rateBps: Int): Int {
        val rateBytes = rateBps.toLong() * policy.maxDurationUs / 8_000_000L
        return (rateBytes + budget.keyBytes + budget.byteCredit)
            .coerceIn(1L, MAX_QUEUE_BYTES.toLong()).toInt()
    }

    /** The duration budget: the base plus the key frame's send-time credit. */
    private fun maxDurationFor(policy: QueuePolicy, budget: BudgetState): Long =
        policy.maxDurationUs + budget.creditUs

    /** One queued key frame left for the socket: it stops extending the bytes. */
    private fun noteKeySent(entry: Entry) {
        val stream = entry.stream
        val before = budgetOf(stream)
        val step = budgetStep(before, BudgetEvent.KeySent(entry.bytes.size))
        if (!step.transition) return
        budgets[stream] = step.state
        log("stream $stream queue budget: ${before.phase.wire} --${step.event}--> " +
            "${step.state.phase.wire}")
        noteDrainedIfEmpty(stream)
    }

    /** The delta queue is empty: a key frame's credit ends once nothing is behind it. */
    private fun noteDrainedIfEmpty(stream: Int) {
        if (deltas[stream]?.isNotEmpty() == true) return
        val before = budgets[stream] ?: return
        if (before.phase == BudgetPhase.Steady) return
        val step = budgetStep(before, BudgetEvent.Drained)
        if (!step.transition) return
        budgets[stream] = step.state
        log("stream $stream queue budget: ${before.phase.wire} --${step.event}--> " +
            "${step.state.phase.wire}")
    }

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
        val budget = budgetOf(stream)
        val maxBytes = maxBytesFor(policy, budget, rateBpsFor(stream, policy))
        val maxDuration = maxDurationFor(policy, budget)
        val queued = deltas[stream]
        val empty = queued == null || queued.isEmpty()
        val used = if (empty) 0 else deltaBytes[stream] ?: 0
        val first = if (empty) 0L else deltaFirstPtsUs[stream] ?: 0L
        val last = if (empty) 0L else deltaLastPtsUs[stream] ?: 0L
        return used <= maxBytes / 2 && last - first <= maxDuration / 2
    }

    companion object {
        const val DEFAULT_MAX_DELTA_BYTES = 256 * 1024 // ~250 ms at 8 Mbps

        /** How long a waiting drop episode goes before it asks for its key again. */
        const val KEY_RETRY_MS = 500L

        /** The protocol's ~250 ms of queued video, independent of the bitrate. */
        const val DEFAULT_MAX_DELTA_DURATION_US = 250_000L

        /** The overrun budget's memory guard: one 4K key frame and its burst fit. */
        const val MAX_QUEUE_BYTES = 4 * 1024 * 1024

        /** One frame at 60 fps: the drop gap is a span of missing frames, not of time. */
        const val FRAME_INTERVAL_US = 16_667L

        const val DEFAULT_MAX_BULK_BYTES = 1024 * 1024

        /** ~250 ms of Opus at 64 kbps is 2 KB; 32 KB leaves headroom for AAC. */
        const val DEFAULT_MAX_AUDIO_BYTES = 32 * 1024
    }
}
