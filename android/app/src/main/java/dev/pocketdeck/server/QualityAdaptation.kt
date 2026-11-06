package dev.pocketdeck.server

/**
 * Live bitrate adaptation for one stream.
 *
 * The target is the full-size bitrate computed from the pixels, or an explicit
 * `window.quality` request. Every backpressure drop (the send queue exceeded
 * ~250 ms of video) takes 25% off, with a 1 Mbps floor; each 5 s without a drop
 * gives 10% back, up to the target.
 *
 * A drop also carries the writer's recent goodput. When it is known, recovery
 * is capped at 85% of that rate (plus a 5% probe every 30 s): the old
 * time-only rule climbed back to the 8 Mbps cap on a 3 Mbit/s link every
 * ~15 s, filling the queue and breaking the reference chain on every cycle.
 *
 * Pure math: the caller passes the clock and applies the returned bitrate to the
 * encoder, so the policy is testable without a codec.
 */
internal class QualityAdaptation(
    private val floorBps: Int = FLOOR_BPS,
    private val dropFactor: Double = 0.75,
    private val recoverFactor: Double = 1.10,
    private val recoverIntervalMs: Long = RECOVER_INTERVAL_MS,
) {

    private var target = 0
    private var current = 0
    private var ceiling = Int.MAX_VALUE
    private var nextRecoverAtMs = Long.MAX_VALUE
    private var nextCeilingProbeAtMs = Long.MAX_VALUE

    /** The bitrate the encoder should use now. */
    val bitrate: Int get() = current

    /** The bitrate recovery grows back to. */
    val targetBps: Int get() = target

    /** The goodput-derived recovery cap; equal to [target] until a drop measures one. */
    val ceilingBps: Int get() = ceiling

    /** A new target (computed or requested): the stream restarts at it. */
    fun setTarget(bps: Int): Int {
        target = bps.coerceAtLeast(0)
        current = target
        ceiling = target
        nextRecoverAtMs = Long.MAX_VALUE
        nextCeilingProbeAtMs = Long.MAX_VALUE
        return current
    }

    /**
     * The session dropped delta frames for this stream: take 25% off and, when
     * [measuredBps] is known, lower the recovery ceiling to 85% of it.
     * @return the new bitrate, or null when it did not move.
     */
    fun onDrop(nowMs: Long, measuredBps: Int? = null): Int? {
        nextRecoverAtMs = nowMs + recoverIntervalMs
        if (measuredBps != null && measuredBps > 0) {
            val cap = maxOf(floorBps, (measuredBps * GOODPUT_HEADROOM).toInt())
            ceiling = minOf(target, cap)
            nextCeilingProbeAtMs = nowMs + CEILING_PROBE_MS
        }
        val floor = minOf(floorBps, target)
        val next = (current * dropFactor).toInt()
            .coerceAtLeast(floor)
            .coerceAtMost(minOf(target, ceiling))
        if (next >= current) return null
        current = next
        return current
    }

    /**
     * Called often (the drain loop); adds 10% back at most once per interval
     * without a drop. @return the new bitrate, or null when nothing changed.
     */
    fun maybeRecover(nowMs: Long): Int? {
        if (current >= target) return null
        // At the measured cap, probe upward 5% every 30 s; a drop resets it.
        if (nowMs >= nextCeilingProbeAtMs && ceiling < target) {
            ceiling = minOf(target, ceiling + maxOf(1, (ceiling * CEILING_PROBE).toInt()))
            nextCeilingProbeAtMs = nowMs + CEILING_PROBE_MS
        }
        if (nowMs < nextRecoverAtMs) return null
        val next = minOf(target, ceiling, (current * recoverFactor).toInt())
        if (next <= current) return null
        current = next
        nextRecoverAtMs = nowMs + recoverIntervalMs
        return current
    }

    companion object {
        const val FLOOR_BPS = 1_000_000
        const val RECOVER_INTERVAL_MS = 5_000L
        /** Leave headroom for TLS/TCP/keyframes on the measured goodput. */
        const val GOODPUT_HEADROOM = 0.85
        /** A 5% probe upward at the cap, after 30 s without a drop. */
        const val CEILING_PROBE = 0.05
        const val CEILING_PROBE_MS = 30_000L
    }
}
