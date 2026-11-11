package app.contigua.server

/**
 * The picture's largest silence around a screen-off edge: the number the
 * emulator rig reads to judge the power-press gap (docs/PROTOCOL.md "Phone
 * screen"). The "first frame after the edge" is not a sound metric — the VD can
 * emit one it made before its group actually slept, so a gap has to be measured
 * between consecutive frames.
 *
 * Timestamps only, one fixed ring and no per-frame allocation: [onFrame] runs on
 * the encoder drain thread for every frame.
 *
 * The window is [edge − beforeMs, edge + afterMs]. The seed is the newest frame
 * still inside it at the edge; each later frame closes a gap against the one
 * before. [closeIfDue] reports once the whole window has passed, so a stream
 * that never draws again still reports its silence.
 */
internal class FrameGapTracker(
    private val beforeMs: Long = 1_000L,
    private val afterMs: Long = 3_000L,
    ringSize: Int = 16,
) {
    private val ring = LongArray(ringSize)
    private var stored = 0
    private var next = 0

    /** The edge of the measurement in progress, or [NONE]. */
    private var edgeMs = NONE
    private var lastFrameMs = NONE
    private var maxGapMs = 0L

    /** Frames observed in the window, seed included. */
    var framesSeen: Int = 0
        private set

    /** Frames that arrived after the edge (the picture came back). */
    private var afterEdge: Int = 0

    val tracking: Boolean get() = edgeMs != NONE

    /** One VD frame's clock. Always fed: the ring is the edge's seed. */
    fun onFrame(nowMs: Long) {
        ring[next] = nowMs
        next = (next + 1) % ring.size
        if (stored < ring.size) stored++
        if (edgeMs == NONE) return
        if (nowMs < edgeMs - beforeMs || nowMs > edgeMs + afterMs) return
        if (lastFrameMs != NONE) {
            val gap = nowMs - lastFrameMs
            if (gap > maxGapMs) maxGapMs = gap
        }
        lastFrameMs = nowMs
        framesSeen++
        if (nowMs > edgeMs) afterEdge++
    }

    /**
     * The screen-off edge: the frames still in the ring that fall inside the
     * window seed it, with the gaps between them (the silence can start before
     * the edge).
     */
    fun markEdge(nowMs: Long) {
        edgeMs = nowMs
        lastFrameMs = NONE
        maxGapMs = 0L
        framesSeen = 0
        afterEdge = 0
        val from = nowMs - beforeMs
        val oldest = (next - stored + ring.size) % ring.size
        for (i in 0 until stored) {
            val t = ring[(oldest + i) % ring.size]
            if (t < from || t > nowMs) {
                lastFrameMs = NONE
                continue
            }
            if (lastFrameMs != NONE) {
                val gap = t - lastFrameMs
                if (gap > maxGapMs) maxGapMs = gap
            }
            lastFrameMs = t
            framesSeen++
        }
    }

    /**
     * The window is over: the largest gap between consecutive frames in it, or
     * null while the window still runs. [framesSeen] stays readable until the
     * next [markEdge].
     *
     * A picture that never drew again after the edge has no second frame to
     * close a gap against: its silence to the window's end is reported instead,
     * so a frozen VD cannot read as a zero gap.
     */
    fun closeIfDue(nowMs: Long): Long? {
        if (edgeMs == NONE || nowMs < edgeMs + afterMs) return null
        if (lastFrameMs != NONE && afterEdge == 0) {
            val silence = edgeMs + afterMs - lastFrameMs
            if (silence > maxGapMs) maxGapMs = silence
        }
        edgeMs = NONE
        return maxGapMs
    }

    private companion object {
        const val NONE = Long.MIN_VALUE
    }
}
