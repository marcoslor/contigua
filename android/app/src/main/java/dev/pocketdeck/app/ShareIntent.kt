package dev.pocketdeck.app

import dev.pocketdeck.server.LinkPolicy
import dev.pocketdeck.server.ShareSender
import dev.pocketdeck.server.ShareStatus
import java.io.InputStream

/**
 * What another app shared with "Send to Mac" (docs/design/sharein.md). Parsing is
 * kept free of Android types so it is unit-tested on the JVM; [S] is the stream
 * handle (a `Uri` in the app).
 */
sealed class ShareItem<out S> {
    /** Text for the Mac; [isLink] only picks the toast, the Mac classifies it again. */
    data class Text(val text: String, val isLink: Boolean) : ShareItem<Nothing>()
    data class Images<S>(val streams: List<S>, val mime: String) : ShareItem<S>()
    data class Unsupported(val why: String) : ShareItem<Nothing>()
}

object ShareIntent {
    const val ACTION_SEND = "android.intent.action.SEND"
    const val ACTION_SEND_MULTIPLE = "android.intent.action.SEND_MULTIPLE"
    const val MAX_IMAGES = 10
    const val TOO_LARGE = "too large"
    const val UNSUPPORTED = "Can't send this to a Mac"

    private val webUrl = Regex("""(?i)\bhttps?://[^\s<>"]+""")

    fun <S> parse(action: String?, type: String?, text: CharSequence?, streams: List<S>): ShareItem<S> {
        val mime = type?.lowercase().orEmpty()
        val isImage = mime.startsWith("image/")
        when (action) {
            ACTION_SEND -> {
                if (isImage && streams.isNotEmpty()) return ShareItem.Images(streams.take(1), mime)
                val body = text?.toString()?.trim().orEmpty()
                if (body.isNotEmpty() && (mime.isEmpty() || mime.startsWith("text/") || !isImage)) {
                    if (body.toByteArray(Charsets.UTF_8).size > ShareSender.MAX_TEXT_BYTES) {
                        return ShareItem.Unsupported(TOO_LARGE)
                    }
                    return ShareItem.Text(body, isLink(body))
                }
                return ShareItem.Unsupported(if (isImage) "no image" else "unsupported type $mime")
            }
            ACTION_SEND_MULTIPLE -> {
                if (isImage && streams.isNotEmpty()) return ShareItem.Images(streams.take(MAX_IMAGES), mime)
                return ShareItem.Unsupported("unsupported type $mime")
            }
        }
        return ShareItem.Unsupported("unsupported action $action")
    }

    /** Exactly one web URL in the text (alone or among other words). */
    fun isLink(text: String): Boolean = webUrl.findAll(text).take(2).count() == 1

    /** The toast for a share result. */
    fun message(status: Int, item: ShareItem<*>): String = when (status) {
        ShareStatus.OK -> when (item) {
            is ShareItem.Text -> if (item.isLink) "Opening on your Mac" else "Copied to your Mac"
            is ShareItem.Images<*> -> if (item.streams.size > 1) "Sent ${item.streams.size} images to your Mac" else "Sent to your Mac"
            is ShareItem.Unsupported -> UNSUPPORTED
        }
        ShareStatus.NO_SESSION -> "No Mac connected"
        ShareStatus.TOO_LARGE -> "Too large to send (max 50 MB)"
        else -> "Couldn't send to your Mac"
    }
    /**
     * "Open on Mac" from the text-selection menu: EXTRA_PROCESS_TEXT, same rules
     * as shared text. Never return a result, so the source text is never changed.
     */
    fun parseProcessText(text: CharSequence?): ShareItem<Nothing> {
        val body = text?.toString()?.trim().orEmpty()
        if (body.isEmpty()) return ShareItem.Unsupported("empty")
        if (body.toByteArray(Charsets.UTF_8).size > ShareSender.MAX_TEXT_BYTES) return ShareItem.Unsupported(TOO_LARGE)
        return ShareItem.Text(body, isLink(body))
    }

    /** "Open on Mac" from Open with / the browser chooser: an http(s) data URI, else null (ignored). */
    fun parseView(uri: String?): ShareItem.Text? {
        val url = LinkPolicy.validate(uri) ?: return null
        val scheme = url.substringBefore(':').lowercase()
        if (scheme != "http" && scheme != "https") return null
        return ShareItem.Text(url, true)
    }

}

/** The shell service's share calls as the dispatcher sees them (null: not bound). */
interface ShareTarget {
    fun text(text: String): Int
    fun file(name: String, mime: String, input: InputStream): Int
}

/** One image opened by the activity before it finished (the URI grant ends with it). */
class OpenedImage(val name: String, val mime: String, val size: Long?, val input: InputStream)

object ShareDispatch {

    /** Sends [item] and returns a [ShareStatus]; every opened stream is closed. */
    fun send(item: ShareItem<*>, images: List<OpenedImage>, target: ShareTarget?): Int {
        try {
            if (item is ShareItem.Unsupported) {
                return if (item.why == ShareIntent.TOO_LARGE) ShareStatus.TOO_LARGE else ShareStatus.FAILED
            }
            if (target == null) return ShareStatus.NO_SESSION
            return when (item) {
                is ShareItem.Text -> target.text(item.text)
                else -> {
                    if (images.isEmpty()) return ShareStatus.FAILED
                    // A size the provider reports is checked before anything is sent.
                    if (images.any { (it.size ?: 0) > ShareSender.MAX_FILE_BYTES }) return ShareStatus.TOO_LARGE
                    images.firstNotNullOfOrNull { image ->
                        target.file(image.name, image.mime, image.input).takeIf { it != ShareStatus.OK }
                    } ?: ShareStatus.OK
                }
            }
        } finally {
            images.forEach { runCatching { it.input.close() } }
        }
    }
}
