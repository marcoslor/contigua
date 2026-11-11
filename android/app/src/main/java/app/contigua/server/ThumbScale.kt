package app.contigua.server

import kotlin.math.roundToInt

/**
 * The long-side clamp for `fs.thumb` (docs/specs/files.md FILES-24): the
 * platform's decode can hand back a bitmap longer than the box it was asked
 * for (API 36 returned 800x600 for a 1200x900 photo at 512), so the platform
 * half scales it to the cap before encoding.
 *
 * Pure arithmetic, apart from Android so the JVM tests pin it.
 */
object ThumbScale {
    /**
     * The size to scale [width] x [height] to so the long side is at most
     * [cap], or null when the bitmap is already inside the cap (or a side is
     * not positive). The short side is never smaller than one pixel.
     */
    fun fit(width: Int, height: Int, cap: Int): Pair<Int, Int>? {
        if (width < 1 || height < 1 || cap < 1) return null
        val longest = maxOf(width, height)
        if (longest <= cap) return null
        val scale = cap.toFloat() / longest
        return maxOf(1, (width * scale).roundToInt()) to
            maxOf(1, (height * scale).roundToInt())
    }
}
