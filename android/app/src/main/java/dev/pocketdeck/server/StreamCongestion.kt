package dev.pocketdeck.server

import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ThreadFactory
import java.util.concurrent.TimeUnit

/**
 * One stream's congestion, as a machine: what the sender owes a reader that
 * falls behind.
 *
 * The send queue drops a stream's delta frames when it holds more than ~250 ms
 * of video, and holds them back until a keyframe repairs the picture. Asking
 * for that keyframe on every drop was the 10-28 bug: a keyframe is many times a
 * delta's size, so it refilled the queue at once, the next drop followed ~250 ms
 * later, and a short slowdown on the reader became a permanent loop at the
 * bitrate floor with the picture frozen between keyframes.
 *
 * Three states and one repair cycle:
 * - `FLOWING`: the stream keeps up.
 * - `DRAINING`: the queue dropped deltas and is emptying. Once it is below the
 *   low mark (or [drainWaitMs] has passed) the machine takes one bitrate step
 *   and asks for one keyframe.
 * - `RECOVERING`: the repair keyframe is out. While it works its way through a
 *   still-slow reader the stream may overflow again; that is the same episode,
 *   so no second keyframe and no second step until [repairIntervalMs] has
 *   passed. A drained queue that stays drained for [healthyMs] means the reader
 *   caught up: `FLOWING` again, and the bitrate recovers as it always did.
 *
 * The gates are what bound the repair rate: at most one keyframe and one
 * bitrate step per [repairIntervalMs] of congestion, never one per drop, and
 * the loop stops as soon as the reader keeps up. The interval also bounds how
 * long a recovering stream waits before its next repair, which is what keeps
 * the first frame after the reader recovers inside ~1 s (NFR
 * `backpressure_recovery_ms`). Pure: the caller passes the clock and performs
 * the returned actions.
 */
internal class StreamCongestion(
    private val drainWaitMs: Long = DRAIN_WAIT_MS,
    private val repairIntervalMs: Long = REPAIR_INTERVAL_MS,
    private val healthyMs: Long = HEALTHY_MS,
) {

    enum class State { FLOWING, DRAINING, RECOVERING }

    sealed interface Event {
        /** The send queue went past ~250 ms of video for this stream. */
        data class Drop(val nowMs: Long) : Event

        /**
         * A tick saw the stream's queue below the low mark. [stalled] is the
         * queue still holding deltas back for a keyframe: it has nothing to
         * send, so the stream needs a repair even though it is empty.
         */
        data class Drained(val nowMs: Long, val stalled: Boolean) : Event

        /** The tick clock: the bounded wait for a queue that never empties. */
        data class Tick(val nowMs: Long) : Event
    }

    enum class Action { LOWER_BITRATE, REQUEST_KEYFRAME }

    var state: State = State.FLOWING
        private set

    /** When the current congestion started: the bounded wait for a drain is measured from here. */
    private var episodeStartMs = 0L

    private var repairedMs = 0L
    private var repaired = false

    /** Drops the current episode has seen (logged when it ends). */
    var dropsInEpisode = 0
        private set

    fun onEvent(event: Event): List<Action> = when (event) {
        is Event.Drop -> onDrop(event.nowMs)
        is Event.Drained -> onDrained(event.nowMs, event.stalled)
        is Event.Tick -> onTick(event.nowMs)
    }

    private fun onDrop(nowMs: Long): List<Action> = when (state) {
        State.FLOWING -> {
            // A new episode: the queue is at its budget. The repair (and with
            // it the bitrate step) waits until the queue has emptied, so the
            // keyframe is encoded at the lower bitrate and into an empty queue.
            episodeStartMs = nowMs
            dropsInEpisode = 1
            state = State.DRAINING
            emptyList()
        }
        // Already congested: the drops are this episode's, not new ones.
        State.DRAINING -> {
            dropsInEpisode++
            emptyList()
        }
        State.RECOVERING -> {
            // The repair's own backlog overflowed: the reader is still behind,
            // so the episode continues and the next cycle may repair again.
            dropsInEpisode++
            if (canRepair(nowMs)) state = State.DRAINING
            emptyList()
        }
    }

    private fun onDrained(nowMs: Long, stalled: Boolean): List<Action> = when (state) {
        State.FLOWING -> emptyList()
        State.DRAINING -> if (canRepair(nowMs)) repair(nowMs) else emptyList()
        State.RECOVERING -> when {
            // A repair that has not settled because the reader is still behind
            // and the queue is holding deltas back: the next cycle may repair.
            stalled && nowMs - repairedMs >= repairIntervalMs -> {
                state = State.DRAINING
                emptyList()
            }
            !stalled && nowMs - repairedMs >= healthyMs -> {
                state = State.FLOWING
                emptyList()
            }
            else -> emptyList()
        }
    }

    private fun onTick(nowMs: Long): List<Action> = when (state) {
        State.FLOWING -> emptyList()
        State.DRAINING ->
            if (nowMs - episodeStartMs >= drainWaitMs && canRepair(nowMs)) repair(nowMs) else emptyList()
        // The queue never emptied (a keyframe stuck behind a stalled socket):
        // the interval is a bound on the wait, not a reason to stop repairing.
        State.RECOVERING ->
            if (nowMs - repairedMs >= repairIntervalMs) {
                state = State.DRAINING
                emptyList()
            } else {
                emptyList()
            }
    }

    private fun repair(nowMs: Long): List<Action> {
        state = State.RECOVERING
        repaired = true
        repairedMs = nowMs
        return listOf(Action.LOWER_BITRATE, Action.REQUEST_KEYFRAME)
    }

    private fun canRepair(nowMs: Long): Boolean = !repaired || nowMs - repairedMs >= repairIntervalMs

    companion object {
        /** PROTOCOL "Video rules": a stream never queues more than ~250 ms of video. */
        const val LOW_WATER_BYTES = 32 * 1024

        /** How long a drop waits for the queue to empty before the repair goes anyway. */
        const val DRAIN_WAIT_MS = 1_000L

        /** At most one keyframe request and one bitrate step per repair interval of one episode. */
        const val REPAIR_INTERVAL_MS = 750L

        /** A drained queue this long after the repair means the reader caught up. */
        const val HEALTHY_MS = 750L

        /** How often a congested stream looks at its queue. */
        const val TICK_MS = 50L
    }
}

/**
 * Drives one [StreamCongestion] per stream from the send queue's drop callback
 * and a tick that runs only while a stream is congested (a healthy stream costs
 * no timer). Actions go to [perform] outside the driver's lock: they reach the
 * display, and a display busy opening another window can take seconds.
 */
internal class CongestionDriver(
    private val queuedBytes: (Int) -> Int,
    private val stalled: (Int) -> Boolean,
    private val perform: (Int, StreamCongestion.Action) -> Unit,
    private val log: (String) -> Unit,
    private val clock: () -> Long = { System.nanoTime() / 1_000_000 },
    threads: ThreadFactory = ThreadFactory { r ->
        Thread(r, "pocketdeck-congestion").apply { isDaemon = true }
    },
) : AutoCloseable {

    private class Entry(val machine: StreamCongestion) {
        var tick: ScheduledFuture<*>? = null
    }

    private val lock = Object()
    private val streams = HashMap<Int, Entry>()
    private val executor: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor(threads)

    /** The send queue dropped this stream's deltas. */
    fun onDrop(stream: Int) = drive(stream) { now -> StreamCongestion.Event.Drop(now) }

    /** The machine's state for one stream, for tests and for the stream's own log. */
    fun state(stream: Int): StreamCongestion.State? = synchronized(lock) { streams[stream]?.machine?.state }

    override fun close() {
        synchronized(lock) { streams.clear() }
        executor.shutdownNow()
    }

    private fun drive(stream: Int, event: (Long) -> StreamCongestion.Event) {
        var actions: List<StreamCongestion.Action> = emptyList()
        var line: String? = null
        synchronized(lock) {
            val entry = streams.getOrPut(stream) { Entry(StreamCongestion()) }
            val before = entry.machine.state
            val event = event(clock())
            actions = entry.machine.onEvent(event)
            val after = entry.machine.state
            val drops = entry.machine.dropsInEpisode
            if (after == StreamCongestion.State.FLOWING && before != after) {
                line = "stream $stream congestion: $before --${eventName(event)}--> $after after $drops drops"
                streams.remove(stream)
            } else {
                if (after != before) line = "stream $stream congestion: $before --${eventName(event)}--> $after"
                if (after != StreamCongestion.State.FLOWING && entry.tick == null) {
                    entry.tick = runCatching {
                        executor.schedule({ tick(stream) }, StreamCongestion.TICK_MS, TimeUnit.MILLISECONDS)
                    }.getOrNull()
                }
            }
        }
        line?.let(log)
        for (action in actions) perform(stream, action)
    }

    private fun eventName(event: StreamCongestion.Event): String = when (event) {
        is StreamCongestion.Event.Drop -> "drop"
        is StreamCongestion.Event.Drained -> "drained"
        is StreamCongestion.Event.Tick -> "tick"
    }

    private fun tick(stream: Int) {
        synchronized(lock) { streams[stream]?.tick = null }
        val queued = queuedBytes(stream)
        val latched = stalled(stream)
        if (queued < StreamCongestion.LOW_WATER_BYTES) {
            drive(stream) { now -> StreamCongestion.Event.Drained(now, latched) }
        } else {
            drive(stream) { now -> StreamCongestion.Event.Tick(now) }
        }
    }
}
