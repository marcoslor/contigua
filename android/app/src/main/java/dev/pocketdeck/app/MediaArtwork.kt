package dev.pocketdeck.app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadata
import android.net.Uri

/**
 * The Android end of [MediaArtRules]: the chosen session's artwork as a
 * [BitmapSource] (docs/design/notify.md, "Media part 2 design"). Bitmaps from
 * the metadata come first; the `*_URI` variants are tried only when the app
 * process can actually open them. Nothing here logs or keeps the picture.
 */
object MediaArtwork {

    fun sourceFor(context: Context, metadata: MediaMetadata?): BitmapSource? {
        if (metadata == null) return null
        for (key in BITMAP_KEYS) {
            val bitmap = runCatching { metadata.getBitmap(key) }.getOrNull() ?: continue
            if (bitmap.width > 0 && bitmap.height > 0) return AndroidBitmapSource(bitmap)
        }
        for (key in URI_KEYS) {
            val uri = runCatching { metadata.getString(key) }.getOrNull() ?: continue
            bitmapFromUri(context, uri)?.let { return AndroidBitmapSource(it) }
        }
        return null
    }

    /** The artwork only changes with its metadata: the listener re-encodes then. */
    fun changed(previous: MediaMetadata?, current: MediaMetadata?): Boolean = previous?.let { it !== current } ?: (current != null)

    private fun bitmapFromUri(context: Context, uri: String): Bitmap? = runCatching {
        context.contentResolver.openInputStream(Uri.parse(uri))?.use { BitmapFactory.decodeStream(it) }
    }.getOrNull()

    private val BITMAP_KEYS = arrayOf(
        MediaMetadata.METADATA_KEY_ART,
        MediaMetadata.METADATA_KEY_ALBUM_ART,
        MediaMetadata.METADATA_KEY_DISPLAY_ICON,
    )

    private val URI_KEYS = arrayOf(
        MediaMetadata.METADATA_KEY_ART_URI,
        MediaMetadata.METADATA_KEY_ALBUM_ART_URI,
        MediaMetadata.METADATA_KEY_DISPLAY_ICON_URI,
    )
}
