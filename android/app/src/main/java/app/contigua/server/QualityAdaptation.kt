package app.contigua.server

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
 * two measured drops in a row lower the ceiling for it.
 *
 * The ceiling probes upward while the link carries more than the last
 * measurement. A probe that survives a [PROBE_INTERVAL_MS] interval is
 * successful and doubles the next step (5% → 10% → 20% → 25%), so a recovered
 * link is climbed back in geometric steps instead of being pinned at the dip's
 * rate for the life of the window (R2). A probe followed by a drop failed: the
 * ceiling comes from the measured goodput, the step resets to 5%, and the next
 * probe waits [PROBE_REFILL_MS] (R3: at most one failed probe per two minutes).
 * The budget refills after [PROBE_REFILL_MS] without a drop, so a long good
 * stretch can probe again.
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
    /** `debug.contigua.stream.quality=off`: the check's broken build; the
     *  policy never moves the bitrate, so each drop repeats the drop/key cycle.
     *  Set from the stream's strategy at configure time. */
    var enabled: Boolean = true
) {

    private var target = 0
    private var current = 0
    private var ceiling = Int.MAX_VALUE
    private var nextRecoverAtMs = Long.MAX_VALUE
    private var nextProbeAtMs = Long.MAX_VALUE
    private var measuredDrops = 0
    private var lastDropAtMs = Long.MIN_VALUE
    private var probesLeft = MAX_PROBES
    private var probeStep = FIRST_PROBE
    private var probeAtMs = Long.MIN_VALUE
    /** The newest measured goodput; it decides the floor below 1 Mbps (PATH-40). */
    private var lastMeasuredBps: Int? = null

    /** The bitrate the encoder should use now. */
    val bitrate: Int get() = current

    /** The bitrate recovery grows back to. */
    val targetBps: Int get() = target

    /** The goodput-derived recovery cap; equal to [target] until a drop measures one. */
    val ceilingBps: Int get() = ceiling

    /** The down-step floor the newest measurement implies (PATH-40). */
    val floorNowBps: Int get() = dropFloor(lastMeasuredBps)

    /** True while the belief cannot come down any further (the ladder's trigger). */
    val atFloor: Boolean get() = current <= floorNowBps

    /** The step the next probe will add, for the field log and the tests. */
    val nextProbeStep: Double get() = probeStep

    /** When the last probe went out, or [Long.MIN_VALUE] when none is in flight. */
    val probeInFlightAtMs: Long get() = probeAtMs

    /**
     * A new target (computed or requested): the stream restarts at it. A
     * reconfigure that repeats the current target is not a restart: the
     * measured cap, the current bitrate and the recovery clock stay.
     *
     * [restart] false keeps the belief through a rebuild the ladder caused: the
     * pixels changed, not the link, so the measured cap and the current
     * bitrate stay and only the recovery ceiling follows the new target.
     */
    @Synchronized
    fun setTarget(bps: Int, restart: Boolean = true): Int {
        val next = bps.coerceAtLeast(0)
        if (next == target) return current
        val raised = next > target
        target = next
        if (!restart) {
            current = minOf(current, target)
            ceiling = if (raised) target else minOf(ceiling, target)
            return current
        }
        current = target
        ceiling = target
        nextRecoverAtMs = Long.MAX_VALUE
        nextProbeAtMs = Long.MAX_VALUE
        measuredDrops = 0
        lastDropAtMs = Long.MIN_VALUE
        probesLeft = MAX_PROBES
        probeStep = FIRST_PROBE
        probeAtMs = Long.MIN_VALUE
        lastMeasuredBps = null
        return current
    }

    /**
     * The session dropped delta frames for this stream: take 25% off and, when
     * [measuredBps] reads clearly below the current bitrate (or this is the
     * second measured drop in a row), lower the recovery ceiling to 85% of it.
     * Below the 1 Mbps floor the floor itself follows the link, so a 900 kbps
     * goodput may take the belief down to 765 kbps instead of 1 Mbps (R4).
     * @return the new bitrate, or null when it did not move.
     */
    @Synchronized
    fun onDrop(nowMs: Long, measuredBps: Int? = null): Int? {
        if (!enabled) return null
        nextRecoverAtMs = nowMs + recoverIntervalMs
        // "Two in a row" means inside one recovery interval. A non-drop
        // window since the last drop starts a new row, even if the bitrate
        // was already back at its target and no recovery step was needed.
        if (lastDropAtMs == Long.MIN_VALUE || nowMs - lastDropAtMs > recoverIntervalMs) {
            measuredDrops = 0
        }
        lastDropAtMs = nowMs
        val probeFailed = probeAtMs != Long.MIN_VALUE
        if (probeFailed) {
            // The probe found the limit. R3: the next one waits two minutes,
            // and the step restarts at 5%.
            probesLeft = 0
            probeStep = FIRST_PROBE
            probeAtMs = Long.MIN_VALUE
            nextProbeAtMs = nowMs + PROBE_REFILL_MS
        }
        if (measuredBps != null && measuredBps > 0) {
            lastMeasuredBps = measuredBps
            measuredDrops++
            val clearlySlower = measuredBps.toLong() * 10 < current.toLong() * 9
            if (probeFailed || clearlySlower || measuredDrops >= 2) {
                val cap = maxOf(dropFloor(measuredBps), (measuredBps * GOODPUT_HEADROOM).toInt())
                ceiling = minOf(target, cap)
                if (!probeFailed) {
                    probesLeft = MAX_PROBES
                    nextProbeAtMs = nowMs + PROBE_INTERVAL_MS
                }
            }
        }
        val next = (current * dropFactor).toInt()
            .coerceAtLeast(dropFloor(measuredBps))
            .coerceAtMost(minOf(target, ceiling))
        if (next >= current) return null
        current = next
        return current
    }

    /**
     * PATH-47: the early delay signal measured a link below the belief. Lower
     * the belief and its recovery ceiling to [bps] without the 25 % drop step
     * and without asking for a keyframe; the 250 ms budget never had to fire.
     * Bounded by the same down-step floor as a drop, never above the target.
     * @return the new bitrate, or null when it did not move.
     */
    @Synchronized
    fun lowerTo(nowMs: Long, bps: Int): Int? {
        if (!enabled) return null
        val bounded = minOf(target, maxOf(dropFloor(lastMeasuredBps), bps))
        nextRecoverAtMs = nowMs + recoverIntervalMs
        ceiling = minOf(ceiling, bounded)
        val next = minOf(current, ceiling)
        if (next >= current) return null
        current = next
        return current
    }

    /**
     * Called often (the drain loop); adds 10% back at most once per interval
     * without a drop, after any ceiling probe due.
     * @return the new bitrate, or null when nothing changed.
     */
    @Synchronized
    fun maybeRecover(nowMs: Long): Int? {
        if (!enabled) return null
        if (current >= target) return null
        // A probe that survived its whole interval found usable capacity:
        // refund it and double the step for the next one.
        if (probeAtMs != Long.MIN_VALUE && nowMs - probeAtMs >= PROBE_INTERVAL_MS) {
            probeAtMs = Long.MIN_VALUE
            probeStep = minOf(MAX_PROBE_STEP, probeStep * 2)
            probesLeft = minOf(MAX_PROBES, probesLeft + 1)
        }
        // A long good stretch refills a budget spent by earlier probes.
        if (probesLeft < MAX_PROBES && lastDropAtMs != Long.MIN_VALUE &&
            nowMs - lastDropAtMs >= PROBE_REFILL_MS
        ) {
            probesLeft = MAX_PROBES
        }
        if (nowMs >= nextProbeAtMs && ceiling < target && probesLeft > 0) {
            ceiling = minOf(
                target,
                (ceiling * (1 + probeStep)).toInt().coerceAtLeast(ceiling + 1),
            )
            probesLeft--
            probeAtMs = nowMs
            nextProbeAtMs = nowMs + PROBE_INTERVAL_MS
            // The link carried the cap for the interval, so the previous drop
            // row is broken even if the probe lands in a later one.
            measuredDrops = 0
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

    /**
     * The down-step floor: 1 Mbps normally; below it, 85% of the measured
     * goodput (R4), never under a quarter megabit and never above the target.
     */
    private fun dropFloor(measuredBps: Int?): Int {
        val base = if (measuredBps != null && measuredBps in 1 until floorBps) {
            maxOf(MIN_BPS, (measuredBps * GOODPUT_HEADROOM).toInt())
        } else {
            floorBps
        }
        return minOf(base, target)
    }

    companion object {
        const val FLOOR_BPS = 1_000_000
        const val RECOVER_INTERVAL_MS = 5_000L
        /** Leave headroom for TLS/TCP/keyframes on the measured goodput. */
        const val GOODPUT_HEADROOM = 0.85
        /** The smallest belief a broken link may take (R4). */
        const val MIN_BPS = 250_000
        /** A probe every 10 s while it keeps succeeding; R2 needs the faster walk. */
        const val PROBE_INTERVAL_MS = 10_000L
        /** A failed probe costs nothing for two minutes (R3). */
        const val PROBE_REFILL_MS = 120_000L
        /** 5% → 10% → 20% → 25%, doubled after each successful probe. */
        const val FIRST_PROBE = 0.05
        const val MAX_PROBE_STEP = 0.25
        /** Safety cap; successful probes refund themselves. */
        const val MAX_PROBES = 2
    }
}
