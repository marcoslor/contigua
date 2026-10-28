package dev.pocketdeck.server

import dev.pocketdeck.proto.Crypto
import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.Json
import java.io.InputStream
import java.security.MessageDigest

/** Result codes of `IDeckService.shareText` / `shareFile` (docs/design/sharein.md). */
object ShareStatus {
    const val OK = 0
    const val NO_SESSION = 1
    const val TOO_LARGE = 2
    const val FAILED = 3
    /** No shell service bound: the phone's own Shizuku is missing or stopped (CONV-AND-03). */
    const val NO_SHELL = 4
}

/**
 * Phone → Mac sharing on one session: `share.text`, and `share.file` + `SHARE_DATA`
 * + `share.end`/`share.abort` for files. Every message of a file goes through the
 * bulk lane so they stay in order (JSON would overtake the data). The caller's
 * thread does the reading and is paced by [sendBulk], which blocks while the lane is full.
 */
internal class ShareSender(
    private val sendJson: (Map<String, Any?>) -> Unit,
    private val sendBulk: (ByteArray) -> Boolean,
    private val log: (String) -> Unit = {},
    private val maxFileBytes: Long = MAX_FILE_BYTES,
    private val chunkBytes: Int = CHUNK_BYTES,
) {
    private val lock = Object()
    private var nextId = 1

    fun text(text: String): Int {
        val size = text.toByteArray(Charsets.UTF_8).size
        if (size == 0) return ShareStatus.FAILED
        if (size > MAX_TEXT_BYTES) return ShareStatus.TOO_LARGE
        sendJson(mapOf("t" to "share.text", "text" to text))
        return ShareStatus.OK
    }

    /** Streams [input] to the Mac; one file at a time per session. */
    fun file(name: String, mime: String, input: InputStream): Int = synchronized(lock) {
        val id = nextId++
        if (!bulkJson(mapOf("t" to "share.file", "id" to id, "name" to name, "mime" to mime))) return ShareStatus.NO_SESSION
        val digest = MessageDigest.getInstance("SHA-256")
        var total = 0L
        val buffer = ByteArray(chunkBytes)
        try {
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                if (n == 0) continue
                total += n
                if (total > maxFileBytes) {
                    abort(id, "over $maxFileBytes bytes")
                    return ShareStatus.TOO_LARGE
                }
                digest.update(buffer, 0, n)
                if (!sendBulk(Frames.encode(Frames.TYPE_SHARE_DATA, id, buffer.copyOf(n)))) {
                    log("share $id: session closed after $total bytes")
                    return ShareStatus.NO_SESSION
                }
            }
        } catch (e: Throwable) {
            abort(id, "read failed: ${e.message}")
            return ShareStatus.FAILED
        }
        if (!bulkJson(mapOf("t" to "share.end", "id" to id, "size" to total, "sha256" to Crypto.toHex(digest.digest())))) {
            return ShareStatus.NO_SESSION
        }
        log("share $id: $total bytes ($mime)")
        ShareStatus.OK
    }

    private fun abort(id: Int, why: String) {
        log("share $id aborted: $why")
        bulkJson(mapOf("t" to "share.abort", "id" to id))
    }

    private fun bulkJson(obj: Map<String, Any?>): Boolean = sendBulk(Frames.encodeJson(0, Json.encode(obj)))

    companion object {
        const val MAX_TEXT_BYTES = 1_048_576
        const val MAX_FILE_BYTES = 52_428_800L
        const val CHUNK_BYTES = 256 * 1024
    }
}
