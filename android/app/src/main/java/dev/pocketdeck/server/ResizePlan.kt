package dev.pocketdeck.server

/** What the platform encoder accepts: size ceiling and alignment. */
internal data class EncoderLimits(
    val maxW: Int = Int.MAX_VALUE,
    val maxH: Int = Int.MAX_VALUE,
    val align: Int = EncoderSizes.ALIGN,
    /** The codec's own steps: a mirror's frame keeps them, not the 16 that app windows use. */
    val widthAlign: Int = EncoderSizes.ALIGN,
    val heightAlign: Int = EncoderSizes.ALIGN,
)

internal object EncoderSizes {
    const val ALIGN = 16
    private const val MIN_SIDE = 16
    private const val SHRINK = 0.9
    private const val SHRINK_TRIES = 8

    /**
     * The stream size for a requested window size: aligned down to the encoder's
     * macroblock grid, scaled down to fit under the encoder's ceiling (aspect
     * kept), and shrunk further while [supported] still rejects it. A size the
     * encoder cannot take must not reach `configure`, which would throw with the
     * old encoder already gone.
     */
    fun fit(w: Int, h: Int, limits: EncoderLimits, supported: (Int, Int) -> Boolean = { _, _ -> true }): IntSize {
        val align = maxOf(limits.align, ALIGN).let { lcm16(it) }
        var scale = minOf(1.0, limits.maxW.toDouble() / maxOf(w, 1), limits.maxH.toDouble() / maxOf(h, 1))
        var size = aligned(w, h, scale, align)
        var tries = 0
        while (!supported(size.w, size.h) && tries < SHRINK_TRIES) {
            scale *= SHRINK
            size = aligned(w, h, scale, align)
            tries++
        }
        return size
    }

    private fun aligned(w: Int, h: Int, scale: Double, align: Int): IntSize =
        IntSize(alignDown((w * scale).toInt(), align), alignDown((h * scale).toInt(), align))

    private fun alignDown(v: Int, align: Int): Int = maxOf(MIN_SIDE, (v / align) * align)

    private fun lcm16(a: Int): Int = if (a % ALIGN == 0) a else a * ALIGN / gcd(a, ALIGN)

    private fun gcd(a: Int, b: Int): Int = if (b == 0) a else gcd(b, a % b)
}

/**
 * The calls a resize is made of, in the order [ResizeSequencer] issues them.
 * [WindowStream] backs them with a MediaCodec and a VirtualDisplay; tests with a
 * recorder.
 */
internal interface ResizeSteps {
    /** The stream size for a requested size under the encoder's limits. */
    fun fit(w: Int, h: Int): IntSize

    /**
     * Builds and starts the next encoder for [size]; returns the size it really
     * encodes (it may shrink a size the platform rejects) or null if it cannot
     * be built at all.
     */
    fun prepare(size: IntSize): IntSize?

    fun resizeDisplay(size: IntSize, dpi: Int)

    /** Points the display at the prepared encoder and starts draining it. */
    fun attachPrepared()

    /** Stops the encoder the display no longer feeds. */
    fun releasePrevious()
}

/**
 * The order of a resize. The new encoder is built while the old one still
 * streams; only then the display is resized and re-pointed at it in two quick
 * calls. Building it after detaching (the old order) let the app redraw for the
 * new size into a display with no surface: an idle app then never produced
 * damage again, the new encoder got no input and the stream froze. If the new
 * encoder cannot be built the old stream is left untouched.
 */
internal class ResizeSequencer(private val steps: ResizeSteps) {

    enum class Outcome {
        /** Display resized and fed by a new encoder. */
        RESIZED,

        /** Paused: only the display was resized; [resume] builds the encoder. */
        DISPLAY_ONLY,

        /** No encoder could be built for the size; the stream keeps its old size. */
        KEPT,
    }

    class Result(val outcome: Outcome, val size: IntSize)

    fun resize(w: Int, h: Int, dpi: Int, paused: Boolean, current: IntSize): Result {
        val size = steps.fit(w, h)
        if (paused) {
            steps.resizeDisplay(size, dpi)
            return Result(Outcome.DISPLAY_ONLY, size)
        }
        val actual = steps.prepare(size) ?: return Result(Outcome.KEPT, current)
        steps.resizeDisplay(actual, dpi)
        steps.attachPrepared()
        steps.releasePrevious()
        return Result(Outcome.RESIZED, actual)
    }

    /** Re-attaches an encoder after a pause; the display may need its size fixed first. */
    fun resume(w: Int, h: Int, dpi: Int, displaySize: IntSize): Result {
        val size = steps.fit(w, h)
        val actual = steps.prepare(size) ?: return Result(Outcome.KEPT, displaySize)
        if (actual != displaySize) steps.resizeDisplay(actual, dpi)
        steps.attachPrepared()
        steps.releasePrevious()
        return Result(Outcome.RESIZED, actual)
    }
}

/**
 * Notices an encoder that was attached but gets no frames. SurfaceFlinger only
 * composes into a new surface when something draws, so an idle app leaves it
 * empty; a density change of one dpi makes every app relayout and redraw, which
 * is the cheapest damage that needs nothing from the app. The offsets alternate
 * (+1, then 0) so each nudge is a real change and the last one lands back on
 * the requested density.
 */
internal class RedrawGuard(
    private val firstCheckMs: Long = FIRST_CHECK_MS,
    private val retryMs: Long = RETRY_MS,
    private val maxNudges: Int = MAX_NUDGES,
) {
    private var attachedAtMs = -1L
    private var sawFrame = false
    private var nudges = 0
    private var nextCheckMs = 0L

    @Synchronized
    fun onAttached(nowMs: Long) {
        attachedAtMs = nowMs
        sawFrame = false
        nudges = 0
        nextCheckMs = nowMs + firstCheckMs
    }

    /** @return ms from attach to this frame the first time one arrives, else null. */
    @Synchronized
    fun onFrame(nowMs: Long): Long? {
        if (sawFrame || attachedAtMs < 0) return null
        sawFrame = true
        return nowMs - attachedAtMs
    }

    /** @return the dpi offset to nudge with when a redraw is overdue, else null. */
    @Synchronized
    fun poll(nowMs: Long): Int? {
        if (attachedAtMs < 0 || sawFrame || nudges >= maxNudges || nowMs < nextCheckMs) return null
        val offset = if (nudges % 2 == 0) 1 else 0
        nudges++
        nextCheckMs = nowMs + retryMs
        return offset
    }

    @get:Synchronized
    val nudgeCount: Int get() = nudges

    companion object {
        const val FIRST_CHECK_MS = 400L
        const val RETRY_MS = 600L
        const val MAX_NUDGES = 2
    }
}
