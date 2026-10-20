package dev.pocketdeck.app

import java.security.MessageDigest
import kotlin.math.roundToInt

/**
 * The chosen session's artwork as `media.art` carries it (docs/design/notify.md,
 * "Media part 2 design"). Scaled to at most 512 px on the long side, always
 * JPEG quality 80, at most 256 KiB. Pure rules behind the same [BitmapSource]
 * seam the notification pictures use, so they are JVM-tested without Android.
 */
class MediaArt(
    val mime: String,
    val width: Int,
    val height: Int,
    val data: ByteArray,
) {
    /** `media.art` as the wire carries it; [base64] is Android's encoder. */
    fun wire(key: String, base64: (ByteArray) -> String): Map<String, Any?> = mapOf(
        "t" to "media.art",
        "key" to key,
        "mime" to mime,
        "w" to width,
        "h" to height,
        "data" to base64(data),
    )
}

object MediaArtRules {
    const val MAX_SIDE = 512
    const val MAX_BYTES = 256 * 1024
    const val JPEG_QUALITY = 80

    /** Below this the artwork is too coarse to be worth a send. */
    const val MIN_SIDE = 64

    /** The size after fitting the long side to [longSide], aspect kept, never enlarged. */
    fun targetSize(width: Int, height: Int, longSide: Int): Pair<Int, Int> {
        require(width > 0 && height > 0) { "artwork needs a size" }
        val longest = maxOf(width, height)
        if (longest <= longSide) return width to height
        val scale = longSide.toDouble() / longest
        return (width * scale).roundToInt().coerceAtLeast(1) to
            (height * scale).roundToInt().coerceAtLeast(1)
    }

    /**
     * The artwork at [longSide], or null when it still does not fit the byte
     * cap. One attempt only; [encode] halves.
     */
    fun encodeAt(source: BitmapSource, longSide: Int): MediaArt? {
        if (source.width <= 0 || source.height <= 0) return null
        val (w, h) = targetSize(source.width, source.height, longSide)
        val scaled = if (w == source.width && h == source.height) source else source.scaledTo(w, h)
        val bytes = scaled.encode("image/jpeg", JPEG_QUALITY) ?: return null
        if (bytes.isEmpty() || bytes.size > MAX_BYTES) return null
        return MediaArt("image/jpeg", w, h, bytes)
    }

    /** 512, then half until [MIN_SIDE]; null when nothing fits. */
    fun encode(source: BitmapSource?): MediaArt? {
        if (source == null) return null
        var longSide = MAX_SIDE
        while (longSide >= MIN_SIDE) {
            encodeAt(source, longSide)?.let { return it }
            longSide /= 2
        }
        return null
    }

    /** The dedupe hash: SHA-256 of the scaled bytes, first 16 hex chars. */
    fun hash(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }
            .take(16)
}
