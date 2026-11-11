package app.contigua.server

import android.graphics.Bitmap
import android.media.ThumbnailUtils
import android.os.CancellationSignal
import android.util.Size
import android.webkit.MimeTypeMap
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * The phone's half of [ThumbSource] (docs/design/files.md "Thumbnails (S6)").
 *
 * `ThumbnailUtils` gives a bitmap already scaled to the requested box, long side
 * at most the box's side; the platform's decoders cover JPEG, PNG, WebP, HEIF
 * and the video codecs the phone can play. The answer is JPEG at the asked
 * quality, or PNG when the bitmap has alpha and a PNG was allowed; an encode
 * that fails or a file the platform cannot decode answers null, which becomes
 * `fs_no_thumb`.
 */
class AndroidThumbSource : ThumbSource {

    override fun kind(name: String): Boolean? {
        val ext = name.substringAfterLast('.', "").lowercase()
        if (ext.isEmpty()) return null
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: return null
        return when {
            mime.startsWith("image/") -> false
            mime.startsWith("video/") -> true
            else -> null
        }
    }

    override fun render(file: File, video: Boolean, longSide: Int, quality: Int,
                        allowPng: Boolean, cancel: ThumbCancellation): ThumbBytes? {
        val signal = CancellationSignal()
        cancel.onCancel { signal.cancel() }
        if (cancel.isCancelled()) return null
        val box = Size(longSide, longSide)
        var bitmap = try {
            if (video) {
                ThumbnailUtils.createVideoThumbnail(file, box, signal)
            } else {
                ThumbnailUtils.createImageThumbnail(file, box, signal)
            }
        } catch (e: Exception) {
            return null
        } ?: return null
        try {
            // ThumbnailUtils sizes its decode from the source's sample steps and
            // can hand back a bitmap longer than the box (a 1200x900 photo at
            // 512 came back 800x600 on API 36), so the cap is enforced here.
            ThumbScale.fit(bitmap.width, bitmap.height, longSide)?.let { (width, height) ->
                val scaled = Bitmap.createScaledBitmap(bitmap, width, height, true)
                if (scaled !== bitmap) {
                    bitmap.recycle()
                    bitmap = scaled
                }
            }
            // A video frame is opaque even when the bitmap reports alpha;
            // FsThumbnailer passes allowPng = false for video (FILES-24).
            val png = allowPng && bitmap.hasAlpha()
            val format = if (png) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG
            val stream = ByteArrayOutputStream()
            val encoded = bitmap.compress(format, if (png) 100 else quality, stream)
            if (!encoded) return null
            return ThumbBytes(stream.toByteArray(), if (png) "image/png" else "image/jpeg")
        } finally {
            bitmap.recycle()
        }
    }
}
