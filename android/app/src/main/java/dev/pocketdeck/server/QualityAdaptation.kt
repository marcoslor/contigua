package dev.pocketdeck.server

/**
 * Live bitrate adaptation for one stream.
 *
 * The target is the full-size bitrate computed from the pixels, or an explicit
 * `window.quality` request. Every backpressure drop (the send queue exceeded
 * ~250 ms of video) takes 25% off, with a 1 Mbps floor; each 5 s without a drop
 * gives 10% back, up to the target.
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
    private var nextRecoverAtMs = Long.MAX_VALUE

    /** The bitrate the encoder should use now. */
    val bitrate: Int get() = current

    /** The bitrate recovery grows back to. */
    val targetBps: Int get() = target

    /** Whether a further drop can still lower the bitrate: the floor (or a lower target) is reached. */
    val atFloor: Boolean get() = current <= minOf(floorBps, target)

    /** A new target (computed or requested): the stream restarts at it. */
    fun setTarget(bps: Int): Int {
        target = bps.coerceAtLeast(0)
        current = target
        nextRecoverAtMs = Long.MAX_VALUE
        return current
    }

    /**
     * The session dropped delta frames for this stream: take 25% off.
     * @return the new bitrate, or null when it was already at the floor.
     */
    fun onDrop(nowMs: Long): Int? {
        nextRecoverAtMs = nowMs + recoverIntervalMs
        val floor = minOf(floorBps, target)
        val next = (current * dropFactor).toInt().coerceAtLeast(floor)
        if (next >= current) return null
        current = next
        return current
    }

    /**
     * Called often (the drain loop); adds 10% back at most once per interval
     * without a drop. @return the new bitrate, or null when nothing changed.
     */
    fun maybeRecover(nowMs: Long): Int? {
        if (current >= target || nowMs < nextRecoverAtMs) return null
        val next = minOf(target, (current * recoverFactor).toInt())
        if (next <= current) return null
        current = next
        nextRecoverAtMs = nowMs + recoverIntervalMs
        return current
    }

    companion object {
        const val FLOOR_BPS = 1_000_000
        const val RECOVER_INTERVAL_MS = 5_000L
    }
}
