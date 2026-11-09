package dev.pocketdeck.server

/**
 * The cap on the bitrate key handed to a VBR encoder, closed on the encoder's
 * own measured output.
 *
 * `QualityAdaptation` reasons about the sender's believed bitrate, but a VBR
 * encoder can put out several times that: emulator arm A ran a 16 Mbps key on a
 * 1 Mbps target while the link carried about 5 Mbps, and arm B's 1 Mbps key
 * still averaged 1.3 Mbps. No queue budget can fix that; the key itself must
 * come down. On a drop the caller passes the link's measured goodput L and the
 * encoder's measured output E. If E is above the 85% headroom, the key that
 * should have produced it is `key * 0.85 * L / E`; the ratio comes from the
 * measurement, so it works for any VBR multiplier. The cap only lowers a key
 * that does not fit; a later drop with a higher measurement may raise it.
 *
 * The cap probes upward 5% after 30 s without a drop, at most twice, then
 * holds: unbounded probes on a hard link walk straight back into the spiral
 * (the same rule `QualityAdaptation` uses). A drop after a probe spends the
 * rest of the budget, so one failed probe stops the walk.
 *
 * Pure math: the caller passes the clock and applies [capBps] to the codec.
 */
internal class EncoderCap(
    private val headroom: Double = HEADROOM,
    private val probeFactor: Double = PROBE_FACTOR,
    private val probeIntervalMs: Long = PROBE_INTERVAL_MS,
    private val maxProbes: Int = MAX_PROBES,
    private val floorBps: Int = FLOOR_BPS,
) {

    /** The ceiling for the encoder key; [Int.MAX_VALUE] until a drop measures one. */
    var capBps: Int = Int.MAX_VALUE
        private set

    /** Upward probes left before the cap holds. */
    var probesLeft: Int = maxProbes
        private set

    private var nextProbeAtMs = Long.MAX_VALUE

    /**
     * A drop measured [encodedBps] of encoder output on a link carrying
     * [linkBps], while the codec's key was [keyBps]. Lowers (or, with a higher
     * later measurement, raises) the cap so the output would fit 85% of the
     * link. A drop whose output already fits leaves the cap alone.
     * @return the new cap, or null when it did not move.
     */
    fun onDrop(nowMs: Long, linkBps: Int?, encodedBps: Int?, keyBps: Int): Int? {
        // A drop is evidence about the last probe too: if one was spent since
        // the previous drop, the cap is at the link's limit and must hold.
        val probeFailed = probesLeft < maxProbes
        probesLeft = if (probeFailed) 0 else maxProbes
        nextProbeAtMs = if (probesLeft > 0) nowMs + probeIntervalMs else Long.MAX_VALUE
        if (linkBps == null || linkBps <= 0) return null
        if (encodedBps == null || encodedBps <= 0 || keyBps <= 0) return null
        val fits = (linkBps.toDouble() * headroom).toLong()
        // The encoder already puts out less than the headroom: the drop was a
        // burst or a queue delay, not a sustained overload.
        if (encodedBps <= fits) return null
        val next = (keyBps.toDouble() * fits / encodedBps)
            .toInt()
            .coerceIn(minOf(floorBps, keyBps), keyBps)
        if (next == capBps) return null
        capBps = next
        return next
    }

    /**
     * Called from the drain loop; lifts the cap 5% after 30 s without a drop,
     * at most [MAX_PROBES] times. @return the new cap, or null.
     */
    fun maybeProbe(nowMs: Long): Int? {
        if (capBps == Int.MAX_VALUE || probesLeft <= 0) return null
        if (nowMs < nextProbeAtMs) return null
        val next = (capBps.toDouble() * (1 + probeFactor))
            .toInt()
            .coerceAtLeast(capBps + 1)
        capBps = next
        probesLeft--
        nextProbeAtMs = if (probesLeft > 0) nowMs + probeIntervalMs else Long.MAX_VALUE
        return next
    }

    /** A new encoder/target: no measured cap until a drop says otherwise. */
    fun reset() {
        capBps = Int.MAX_VALUE
        probesLeft = maxProbes
        nextProbeAtMs = Long.MAX_VALUE
    }

    companion object {
        /** Leave headroom for TLS/TCP and the next key frame. */
        const val HEADROOM = 0.85

        /** A 5% probe upward at the cap, after 30 s without a drop. */
        const val PROBE_FACTOR = 0.05
        const val PROBE_INTERVAL_MS = 30_000L
        const val MAX_PROBES = 2

        /**
         * A sanity floor: a key below a quarter megabit cannot carry a window,
         * and a link that small is broken, not slow.
         */
        const val FLOOR_BPS = 250_000
    }
}
