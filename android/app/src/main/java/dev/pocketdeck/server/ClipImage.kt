package dev.pocketdeck.server

import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.Json
import java.io.File
import java.security.MessageDigest

/**
 * Clipboard images (docs/design/dragdrop.md): the byte-based counterpart of
 * [ClipSync] for `clip.set`, plus the two senders/receivers of `clip.image.*`
 * + `CLIP_DATA`. One image per direction at a time; the cap mirrors clip text's
 * 1 MiB rule at 8 MiB and larger sizes are silently not sent / not applied.
 */
object ClipImagePolicy {
    const val MAX_BYTES = 8 * 1024 * 1024

    fun valid(mime: String?): Boolean =
        mime != null && (mime.equals("image/jpeg", true) || mime.equals("image/png", true))

    fun sha256(bytes: ByteArray): String? {
        if (bytes.isEmpty() || bytes.size > MAX_BYTES) return null
        return MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    }
}

/**
 * Whether a local clipboard image goes out and a received one is applied — the
 * `ClipSync` hash rule, for bytes.
 */
class ClipImageSync {
    private val lock = Any()
    private var synced: ByteArray? = null

    /** Records the image when its bytes would go out. */
    fun shouldSend(image: ClipImage): Boolean {
        val hash = MessageDigest.getInstance("SHA-256").digest(image.bytes)
        synchronized(lock) {
            if (synced?.contentEquals(hash) == true) return false
            synced = hash
            return true
        }
    }

    /** Records the hash first, so the change the write causes is not echoed back. */
    fun accept(image: ClipImage) = synchronized(lock) { synced = MessageDigest.getInstance("SHA-256").digest(image.bytes) }
}

/**
 * Phone → Mac: streams a clipboard image as `clip.image.start` / `CLIP_DATA` /
 * `clip.image.end`, all on the bulk lane so they never overtake their data — the
 * shape [ShareSender] established for shared files. `sendBulk` blocks the caller
 * while the lane is full; one image at a time is the caller's business (the
 * session's poller is sequential).
 */
internal class ClipImageSender(
    private val sendBulk: (ByteArray) -> Boolean,
    private val log: (String) -> Unit = {},
    private val chunkBytes: Int = CHUNK_BYTES,
) {
    private val lock = Any()
    private var nextId = 1

    /** True when the whole image was queued; an oversized image is silently skipped. */
    fun send(image: ClipImage): Boolean = synchronized(lock) {
        val digest = ClipImagePolicy.sha256(image.bytes) ?: return false.also {
            log("clip image: ${image.bytes.size} bytes rejected (cap ${ClipImagePolicy.MAX_BYTES})")
        }
        val id = nextId++
        if (!bulkJson(mapOf("t" to "clip.image.start", "id" to id, "mime" to image.mime, "size" to image.bytes.size))) {
            return false
        }
        var offset = 0
        while (offset < image.bytes.size) {
            val end = minOf(offset + chunkBytes, image.bytes.size)
            if (!sendBulk(Frames.encode(Frames.TYPE_CLIP_DATA, id, image.bytes.copyOfRange(offset, end)))) {
                log("clip image $id: session closed after $offset bytes")
                return false
            }
            offset = end
        }
        bulkJson(mapOf("t" to "clip.image.end", "id" to id, "size" to image.bytes.size, "sha256" to digest))
    }

    fun abort(id: Int) {
        bulkJson(mapOf("t" to "clip.image.abort", "id" to id))
    }

    private fun bulkJson(obj: Map<String, Any?>): Boolean = sendBulk(Frames.encodeJson(0, Json.encode(obj)))

    companion object {
        const val CHUNK_BYTES = 256 * 1024
    }
}

/**
 * Mac → phone: reassembles one image at a time in memory (the cap is the whole
 * point), verifies the digest and hands the image to [sink] — which puts it on
 * the clipboard. Unknown ids and junk are dropped with a log, never answered.
 */
internal class ClipImageReceiver(
    private val sink: Sink,
    private val log: (String) -> Unit = {},
    /** The phone's answer to the Mac (SHARE-16): the image is on the clipboard, or not. */
    private val done: (id: Int, ok: Boolean) -> Unit = { _, _ -> },
) {
    /** Consumes a finished image; true when it really reached the clipboard. */
    fun interface Sink {
        fun offer(image: ClipImage): Boolean
    }

    private class Transfer(val id: Int, var mimeType: String, val bytes: ByteArray, var size: Int = 0)

    private var transfer: Transfer? = null

    fun begin(id: Int, mime: String?, size: Long) {
        if (id <= 0 || !ClipImagePolicy.valid(mime) || size <= 0 || size > ClipImagePolicy.MAX_BYTES) {
            log("clip.image.start ignored (id=$id mime=$mime size=$size)")
            transfer = null
            return
        }
        transfer = Transfer(id, mime!!, ByteArray(size.toInt()))
    }

    fun data(id: Int, payload: ByteArray) {
        val current = transfer ?: return
        if (current.id != id) return
        if (current.size + payload.size > current.bytes.size) {
            log("clip image: more bytes than announced")
            transfer = null
            return
        }
        payload.copyInto(current.bytes, current.size)
        current.size += payload.size
    }

    /** Validates, delivers and answers the Mac; junk is refused, never answered with ok. */
    fun end(id: Int, size: Long, sha256: String?) {
        val current = transfer
        if (current == null || current.id != id) {
            done(id, false)
            return
        }
        transfer = null
        val hash = MessageDigest.getInstance("SHA-256").digest(current.bytes).joinToString("") { "%02x".format(it) }
        if (current.size.toLong() != size || hash != sha256?.lowercase()) {
            log("clip image: checksum failed (${current.size}/$size)")
            done(id, false)
            return
        }
        val ok = sink.offer(ClipImage(current.bytes, current.mimeType))
        done(id, ok)
    }

    fun abort(id: Int) {
        if (transfer?.id == id) transfer = null
    }
}

/**
 * The one path a received image takes on the phone: the file in the shared
 * folder (the only path the shell process owns on the card), the media scan and
 * the clipboard. The Uri/name concerns live in [ShellClipboard]; this class only
 * picks names and files.
 */
class ClipImageLand(
    private val port: ClipboardImagePort?,
    private val log: (String) -> Unit = {},
) : ClipImageReceiver.Sink {
    private val lock = Any()

    override fun offer(image: ClipImage): Boolean {
        val port = port ?: run { log("clip image: no clipboard port"); return false }
        if (!ClipImagePolicy.valid(image.mime)) return false
        val ext = if (image.mime.equals("image/jpeg", true)) "jpg" else "png"
        val file = nextFile(ext) ?: run { log("clip image: no name"); return false }
        return try {
            File(DIRECTORY).mkdirs()
            file.outputStream().use { it.write(image.bytes) }
            val ok = port.writeImage(file, image.mime, file.nameWithoutExtension)
            if (ok) log("clip image: on the clipboard (${image.bytes.size} bytes)")
            else log("clip image: clipboard write refused")
            ok
        } catch (e: Exception) {
            log("clip image failed: ${e.message}")
            false
        }
    }

    /** "Clipboard 1.png", "Clipboard 2.png"… the first name that is not on disk. */
    private fun nextFile(ext: String): File? = synchronized(lock) {
        while (true) {
            clipCount += 1
            val candidate = File(DIRECTORY, "Clipboard $clipCount.$ext")
            if (!candidate.exists()) return candidate
        }
        @Suppress("NULLABILITY")
        null
    }

    companion object {
        var DIRECTORY = DropPolicy.DIRECTORY
        private var clipCount = 0
    }
}
