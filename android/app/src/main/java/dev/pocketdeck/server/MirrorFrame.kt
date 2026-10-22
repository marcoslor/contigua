package dev.pocketdeck.server

import kotlin.math.abs
import kotlin.math.roundToInt

/** A rectangle in encoded-frame pixels: where a mirror's picture sits in its frame. */
data class IntRect(val x: Int, val y: Int, val w: Int, val h: Int)

/**
 * The encoder frame of a mirror of display 0, and where the picture sits in it.
 * A frame whose width and height were rounded to the grid on their own can be
 * up to a few percent off the screen's aspect, and the display is then drawn
 * with a black band inside the frame (docs/PROTOCOL.md `window.content`).
 */
internal object MirrorFrame {
    /** A frame may be this much smaller than the largest one when that buys a closer aspect. */
    private const val MIN_AREA_SHARE = 0.75

    /**
     * The frame for [box] (the Mac's window, in pixels): every size on the
     * encoder's grid (`align`), no larger than the box, the screen or the
     * encoder's ceiling, whose aspect is closest to [screen]'s. Among the
     * frames of at least [MIN_AREA_SHARE] of the largest one, the closest
     * aspect wins; the first one the encoder accepts is taken. Never upscales.
     */
    fun pick(
        box: IntSize,
        screen: IntSize,
        align: IntSize,
        maxW: Int,
        maxH: Int,
        supported: (Int, Int) -> Boolean = { _, _ -> true },
    ): IntSize {
        val aw = maxOf(align.w, 1)
        val ah = maxOf(align.h, 1)
        val limitW = minOf(box.w, screen.w, maxW)
        val limitH = minOf(box.h, screen.h, maxH)
        val aspect = screen.w.toDouble() / screen.h
        val candidates = ArrayList<Candidate>()
        var h = (limitH / ah) * ah
        while (h >= ah) {
            val base = ((h * aspect) / aw).toInt() * aw
            for (w in intArrayOf(base, base + aw)) {
                if (w in aw..limitW) candidates += Candidate(IntSize(w, h), abs((w.toDouble() / h) / aspect - 1.0))
            }
            h -= ah
        }
        if (candidates.isEmpty()) return IntSize(aw, ah)
        val largest = candidates.maxOf { it.size.w.toLong() * it.size.h }
        val near = candidates
            .filter { it.size.w.toLong() * it.size.h >= MIN_AREA_SHARE * largest }
            .sortedWith(compareBy<Candidate> { it.error }.thenByDescending { it.size.w.toLong() * it.size.h })
        val accepted = near.firstOrNull { supported(it.size.w, it.size.h) }
            ?: candidates.sortedByDescending { it.size.w.toLong() * it.size.h }.firstOrNull { supported(it.size.w, it.size.h) }
        return accepted?.size ?: IntSize(aw, ah)
    }

    /**
     * Where the display's picture sits in [frame]: the screen scaled to fit and
     * centred, as the phone's own mirror draws it. The Mac shows only this rect.
     */
    fun contentIn(frame: IntSize, screen: IntSize): IntRect {
        if (frame.w <= 0 || frame.h <= 0 || screen.w <= 0 || screen.h <= 0) {
            return IntRect(0, 0, maxOf(frame.w, 0), maxOf(frame.h, 0))
        }
        val scale = minOf(frame.w.toDouble() / screen.w, frame.h.toDouble() / screen.h)
        val w = (screen.w * scale).roundToInt().coerceIn(1, frame.w)
        val h = (screen.h * scale).roundToInt().coerceIn(1, frame.h)
        return IntRect((frame.w - w) / 2, (frame.h - h) / 2, w, h)
    }

    private class Candidate(val size: IntSize, val error: Double)
}
