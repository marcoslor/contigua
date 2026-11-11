package app.contigua.server

import java.io.File

/**
 * One encoded thumbnail: the bytes and the mime the Mac is told
 * (docs/PROTOCOL.md "Phone files" › "Thumbnails").
 */
class ThumbBytes(val bytes: ByteArray, val mime: String)

/**
 * Follows one thumbnail request into the platform's decode. `fs.thumb` runs on
 * the session's worker, and `fs.cancel` arrives on another thread: the Android
 * half turns [onCancel] into `CancellationSignal.cancel`, the JVM tests just
 * record it, so this interface never names an Android type.
 */
interface ThumbCancellation {
    fun isCancelled(): Boolean

    /** Runs [action] now when the request is already cancelled, else on cancel. */
    fun onCancel(action: () -> Unit)
}

/**
 * The platform's decode + scale + encode, behind a seam the JVM tests fake
 * (docs/design/files.md "Thumbnails (S6)"). `FsThumbnailer` owns the caps, the
 * re-encode and the queue; this owns the bitmap.
 */
interface ThumbSource {
    /**
     * True when the name is a video, false when an image, null when neither.
     * The Mac filters too; this is the phone's own check.
     */
    fun kind(name: String): Boolean?

    /**
     * Long side at most [longSide]; JPEG at [quality], or PNG while [allowPng]
     * and the bitmap has alpha (PNG ignores the quality). A video frame is
     * opaque even when its bitmap reports alpha, so the caller passes
     * `allowPng = false` for video (FILES-24). Null: no picture.
     */
    fun render(file: File, video: Boolean, longSide: Int, quality: Int,
               allowPng: Boolean, cancel: ThumbCancellation): ThumbBytes?

    companion object {
        /** A build with no image decoder: every request answers `fs_no_thumb`. */
        val None = object : ThumbSource {
            override fun kind(name: String): Boolean? = null

            override fun render(file: File, video: Boolean, longSide: Int, quality: Int,
                                allowPng: Boolean, cancel: ThumbCancellation): ThumbBytes? = null
        }
    }
}
