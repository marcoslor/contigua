package app.contigua.server

import app.contigua.proto.Frames
import app.contigua.proto.Json
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean

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
 * point), verifies the digest and hands the image to [sink] — the app, which
 * owns the provider and puts it on the clipboard. Unknown ids and junk are
 * dropped with a log, never answered.
 */
internal class ClipImageReceiver(
    private val sink: Sink,
    private val log: (String) -> Unit = {},
    /** The phone's answer to the Mac (SHARE-16): the image is on the clipboard, or not. */
    private val done: (id: Int, ok: Boolean) -> Unit = { _, _ -> },
) {
    /** Hands a finished image to the app; [done] receives its answer once. */
    fun interface Sink {
        fun offer(id: Int, image: ClipImage, done: (Boolean) -> Unit)
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
        val answered = AtomicBoolean(false)
        val answer: (Boolean) -> Unit = { ok ->
            if (answered.compareAndSet(false, true)) {
                log("clip image: app answered ok=$ok (${current.bytes.size} bytes)")
                done(id, ok)
            }
        }
        runCatching { sink.offer(id, ClipImage(current.bytes, current.mimeType), answer) }
            .onFailure {
                log("clip image: delivery failed: ${failureClasses(it)}")
                answer(false)
            }
    }

    fun abort(id: Int) {
        if (transfer?.id == id) transfer = null
    }
}

/**
 * The app-owned clip (SHARE-2/16): the shell no longer writes a URI clip; uid
 * 2000's clip fails ClipboardService's owner check (boot 5, H1). The bytes go
 * to the app, which builds the URI at its own uid, sets A2's URI-only item and
 * answers `clip.image.done` through [ClipImageHost].
 */
class ClipImageLand(
    private val host: ClipImageHost?,
    private val log: (String) -> Unit = {},
) : ClipImageReceiver.Sink {

    override fun offer(id: Int, image: ClipImage, done: (Boolean) -> Unit) {
        if (!ClipImagePolicy.valid(image.mime)) return done(false)
        val host = host ?: run {
            log("clip image: no app writer")
            return done(false)
        }
        host.offer(id, image.mime, image.bytes, done)
    }
}
