package app.contigua.server

/**
 * The inner bitrate loop: the codec key follows the sender's believed bitrate
 * through the encoder's measured gain.
 *
 * `QualityAdaptation` decides what the link can carry; a VBR encoder may still
 * put out several times the key it is given (the emulator's arm A ran 11.5
 * Mbps on a 16 Mbps key, arm B 1.3 Mbps on a 1 Mbps key). The gain is
 * `measured output / applied key`, smoothed with an EWMA, and the key that
 * should produce the believed bitrate is `believed / gain`. So there is one
 * cascade, not two clamps: the outer loop moves the believed bitrate, this one
 * makes the encoder follow it.
 *
 * A measurement is only honest while the key is steady: the machine starts in
 * [State.Unmeasured], takes its first sample only after the key has run for
 * [settleMs], and re-settles after every key change. Samples arrive at most
 * once per [sampleIntervalMs]. A key may fall at once, but it climbs at most
 * [maxUpPerSecond] toward the uncorrected key (target × overshoot): a static
 * screen reads as a tiny gain, and jumping straight back would overshoot the
 * link. The key never goes above the uncorrected key and never below
 * [floorBps] (or the uncorrected key, when that is smaller).
 *
 * The caller measures delta frames only: a key frame is a content-driven burst
 * the queue budget already admits, and a periodic key in a one-second window
 * would read as a gain spike.
 *
 * Pure math: the caller passes the clock and applies [keyBps] to the codec.
 */
internal class EncoderCorrection(
    private val floorBps: Int = FLOOR_BPS,
    private val gainAlpha: Double = GAIN_ALPHA,
    private val settleMs: Long = SETTLE_MS,
    private val sampleIntervalMs: Long = SAMPLE_INTERVAL_MS,
    private val maxUpPerSecond: Double = MAX_UP_PER_SECOND,
) {
    /** The measurement machine: no gain yet, a steady gain, or re-measuring after a key change. */
    enum class State(val wire: String) {
        Unmeasured("unmeasured"),
        Tracking("tracking"),
        Settling("settling"),
    }

    var state = State.Unmeasured
        private set

    /** The smoothed encoder output per unit of key; 1.0 is a well-behaved encoder. */
    var gain = 1.0
        private set

    /** The key last returned by [keyFor]. */
    var keyBps = 0
        private set

    private var keyChangedAtMs = Long.MIN_VALUE
    private var lastSampleAtMs = Long.MIN_VALUE

    @Synchronized
    fun reset() {
        state = State.Unmeasured
        gain = 1.0
        keyBps = 0
        keyChangedAtMs = Long.MIN_VALUE
        lastSampleAtMs = Long.MIN_VALUE
    }

    /**
     * One measured output over a span where [appliedKeyBps] ran. The caller
     * passes the encoder's delta output; [appliedKeyBps] is the key the codec
     * actually ran with.
     * @return true when the gain moved, so the caller should re-apply the key.
     */
    @Synchronized
    fun sample(nowMs: Long, outputBps: Int?, appliedKeyBps: Int): Boolean {
        if (outputBps == null || outputBps <= 0 || appliedKeyBps <= 0) return false
        if (keyChangedAtMs == Long.MIN_VALUE) return false
        if (lastSampleAtMs != Long.MIN_VALUE && nowMs - lastSampleAtMs < sampleIntervalMs) {
            return false
        }
        if (nowMs - keyChangedAtMs < settleMs) return false
        val measured = outputBps.toDouble() / appliedKeyBps
        gain = when (state) {
            State.Unmeasured -> measured
            State.Tracking -> gain * (1 - gainAlpha) + measured * gainAlpha
            State.Settling -> measured
        }.coerceIn(MIN_GAIN, MAX_GAIN)
        lastSampleAtMs = nowMs
        state = State.Tracking
        return true
    }

    /**
     * The key for [believedBps] now, capped by [uncorrectedBps] (target ×
     * overshoot). A fall applies at once; a rise is at most
     * [maxUpPerSecond] of the current key per second.
     */
    @Synchronized
    fun keyFor(nowMs: Long, believedBps: Int, uncorrectedBps: Int): Int {
        if (believedBps <= 0 || uncorrectedBps <= 0) return 0
        if (state == State.Unmeasured) {
            if (keyBps != uncorrectedBps) {
                keyBps = uncorrectedBps
                keyChangedAtMs = nowMs
            }
            return keyBps
        }
        val floor = minOf(floorBps, uncorrectedBps)
        val wanted = (believedBps / gain).toInt().coerceIn(floor, uncorrectedBps)
        var next = wanted
        if (wanted > keyBps) {
            val elapsed = (nowMs - keyChangedAtMs).coerceAtLeast(0)
            val allowance = (keyBps.toDouble() * maxUpPerSecond * elapsed / 1000.0).toInt()
            next = minOf(wanted, keyBps + allowance)
        }
        if (next != keyBps) {
            keyBps = next
            keyChangedAtMs = nowMs
            state = State.Settling
        }
        return keyBps
    }

    companion object {
        /** A quarter megabit is the smallest key that can carry a window. */
        const val FLOOR_BPS = 250_000

        /** A gain sample updates at most once a second. */
        const val SAMPLE_INTERVAL_MS = 1_000L

        /** Ignore output until the new key has run this long. */
        const val SETTLE_MS = 1_000L

        /** Smoothing for a steady key: half the old gain, half the new sample. */
        const val GAIN_ALPHA = 0.5

        /** A static screen walks back up; it never jumps. */
        const val MAX_UP_PER_SECOND = 0.10

        /** Guard the division against a stalled encoder's tiny output. */
        const val MIN_GAIN = 0.01
        const val MAX_GAIN = 100.0
    }
}
