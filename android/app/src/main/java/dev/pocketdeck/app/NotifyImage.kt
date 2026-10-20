package dev.pocketdeck.app

import kotlin.math.roundToInt

/**
 * The picture the Mac shows on a forwarded notification (docs/design/notify.md,
 * "Part 2b design"). The phone picks at most one picture per notification and
 * this file holds the whole decision: which source, how far it is scaled, which
 * format and when it is dropped. Everything except the real bitmap is a pure,
 * JVM-tested rule ([NotifyImageRules]) behind a [BitmapSource] seam, so the cap
 * math is tested without Android.
 */
class NotifyImage(
    val mime: String,
    val width: Int,
    val height: Int,
    val data: ByteArray,
) {
    /** `notify.image` as the wire carries it; [base64] is Android's encoder. */
    fun wire(id: String, base64: (ByteArray) -> String): Map<String, Any?> = mapOf(
        "t" to "notify.image",
        "id" to id,
        "mime" to mime,
        "w" to width,
        "h" to height,
        "data" to base64(data),
    )
}

/**
 * A decoded picture reduced to what the scaling rules need. The production
 * implementation wraps `android.graphics.Bitmap`; tests use an in-memory fake.
 */
interface BitmapSource {
    val width: Int
    val height: Int

    /** The source has an alpha channel: PNG keeps it, JPEG would flatten it. */
    val hasAlpha: Boolean

    /** A copy scaled to exactly these dimensions. */
    fun scaledTo(width: Int, height: Int): BitmapSource

    /** Encodes with that mime and quality; null when the encoder produced nothing. */
    fun encode(mime: String, quality: Int): ByteArray?
}

object NotifyImageRules {
    /** Long side of the largest picture the wire carries. */
    const val MAX_SIDE = 512

    /** The phone refuses to send (and the Mac refuses to take) more than this. */
    const val MAX_BYTES = 200 * 1024

    const val JPEG_QUALITY = 80

    /** Below this the picture is too coarse to be worth a banner. */
    const val MIN_SIDE = 32

    /** PNG only when there is transparency to keep; everything else is JPEG. */
    fun mime(hasAlpha: Boolean): String = if (hasAlpha) "image/png" else "image/jpeg"

    /**
     * The size after fitting the long side to [longSide], aspect kept and never
     * enlarged. A source smaller than the cap is sent as it is.
     */
    fun targetSize(width: Int, height: Int, longSide: Int): Pair<Int, Int> {
        require(width > 0 && height > 0) { "a picture needs a size" }
        val longest = maxOf(width, height)
        if (longest <= longSide) return width to height
        val scale = longSide.toDouble() / longest
        val w = (width * scale).roundToInt().coerceAtLeast(1)
        val h = (height * scale).roundToInt().coerceAtLeast(1)
        return w to h
    }

    /**
     * The encoded picture at [longSide], or null when it still does not fit the
     * byte cap (or the encoder fails). One attempt only; [encode] halves.
     */
    fun encodeAt(source: BitmapSource, longSide: Int): NotifyImage? {
        if (source.width <= 0 || source.height <= 0) return null
        val (w, h) = targetSize(source.width, source.height, longSide)
        val scaled = if (w == source.width && h == source.height) source else source.scaledTo(w, h)
        val mime = mime(source.hasAlpha)
        val bytes = scaled.encode(mime, JPEG_QUALITY) ?: return null
        if (bytes.isEmpty() || bytes.size > MAX_BYTES) return null
        return NotifyImage(mime, w, h, bytes)
    }

    /**
     * The first size that fits: 512, then half until 32; null when even 32 px
     * encodes over the cap, in which case the notification goes without a
     * picture rather than with a bad one.
     */
    fun encode(source: BitmapSource?): NotifyImage? {
        if (source == null) return null
        var longSide = MAX_SIDE
        while (longSide >= MIN_SIDE) {
            encodeAt(source, longSide)?.let { return it }
            longSide /= 2
        }
        return null
    }
}
