package dev.pocketdeck.server

/**
 * Live bitrate adaptation for one stream.
 *
 * The target is the full-size bitrate computed from the pixels, or an explicit
 * `window.quality` request. Every backpressure drop (the send queue exceeded
 * ~250 ms of video) takes 25% off, with a 1 Mbps floor; each 5 s without a drop
 * gives 10% back, up to the target.
 *
 * A drop also carries the writer's recent goodput. When it reads clearly below
 * the current bitrate, recovery is capped at 85% of that rate: the old
 * time-only rule climbed back to the 8 Mbps cap on a 3 Mbit/s link every
 * ~15 s, filling the queue and breaking the reference chain on every cycle.
 * A single sample close to the current bitrate is treated as transient; only
 * two measured drops in a row lower the ceiling for it. The cap probes upward
 * by 5% at most [CEILING_PROBES] times, then holds: unbounded probes walked a
 * hard 3 Mbit/s link back into the sawtooth in about two minutes. A drop after
 * a probe spends the rest of the budget, so one failed probe stops the walk.
 *
 * A reconfigure at the same target keeps the measured cap and the current
 * bitrate; resetting them made every resize replay the drop from the top.
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
    private var measuredDrops = 0
    private var lastDropAtMs = Long.MIN_VALUE
    private var probesLeft = CEILING_PROBES

    /** The bitrate the encoder should use now. */
    val bitrate: Int get() = current

    /** The bitrate recovery grows back to. */
    val targetBps: Int get() = target

    /** The goodput-derived recovery cap; equal to [target] until a drop measures one. */
    val ceilingBps: Int get() = ceiling

    /**
     * A new target (computed or requested): the stream restarts at it. A
     * reconfigure that repeats the current target is not a restart: the
     * measured cap, the current bitrate and the recovery clock stay.
     */
    fun setTarget(bps: Int): Int {
        val next = bps.coerceAtLeast(0)
        if (next == target) return current
        target = next
        current = target
        ceiling = target
        nextRecoverAtMs = Long.MAX_VALUE
        nextCeilingProbeAtMs = Long.MAX_VALUE
        measuredDrops = 0
        lastDropAtMs = Long.MIN_VALUE
        probesLeft = CEILING_PROBES
        return current
    }

    /**
     * The session dropped delta frames for this stream: take 25% off and, when
     * [measuredBps] reads clearly below the current bitrate (or this is the
     * second measured drop in a row), lower the recovery ceiling to 85% of it.
     * @return the new bitrate, or null when it did not move.
     */
    fun onDrop(nowMs: Long, measuredBps: Int? = null): Int? {
        nextRecoverAtMs = nowMs + recoverIntervalMs
        // "Two in a row" means inside one recovery interval. A non-drop
        // window since the last drop starts a new row, even if the bitrate
        // was already back at its target and no recovery step was needed.
        if (lastDropAtMs == Long.MIN_VALUE || nowMs - lastDropAtMs > recoverIntervalMs) {
            measuredDrops = 0
        }
        lastDropAtMs = nowMs
        val probeFailed = probesLeft < CEILING_PROBES
        if (probeFailed) probesLeft = 0
        if (measuredBps != null && measuredBps > 0) {
            measuredDrops++
            val clearlySlower = measuredBps.toLong() * 10 < current.toLong() * 9
            if (probeFailed || clearlySlower || measuredDrops >= 2) {
                val cap = maxOf(floorBps, (measuredBps * GOODPUT_HEADROOM).toInt())
                ceiling = minOf(target, cap)
                // A drop after a probe means the probe found the limit; hold
                // it. A fresh cap starts a new, bounded walk.
                probesLeft = if (probeFailed) 0 else CEILING_PROBES
                nextCeilingProbeAtMs = nowMs + CEILING_PROBE_MS
            }
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
        // At the measured cap, probe upward 5% at most twice; a drop resets it.
        if (nowMs >= nextCeilingProbeAtMs && ceiling < target && probesLeft > 0) {
            ceiling = minOf(target, ceiling + maxOf(1, (ceiling * CEILING_PROBE).toInt()))
            probesLeft--
            // The link carried the cap for 30 s, so the previous drop row is
            // broken even if this probe is followed by a new drop later.
            measuredDrops = 0
            nextCeilingProbeAtMs = if (probesLeft > 0) {
                nowMs + CEILING_PROBE_MS
            } else {
                Long.MAX_VALUE
            }
        }
        if (nowMs < nextRecoverAtMs) return null
        val next = minOf(target, ceiling, (current * recoverFactor).toInt())
        if (next <= current) return null
        current = next
        // A recovery step is a non-drop window: the drop row is broken.
        measuredDrops = 0
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
        /** Two no-drop probes, then hold: 2.55 -> 2.81 Mbit/s, below a 3 Mbit/s link. */
        const val CEILING_PROBES = 2
    }
}
