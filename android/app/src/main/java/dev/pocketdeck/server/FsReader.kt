package dev.pocketdeck.server

import dev.pocketdeck.proto.Crypto
import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.Json
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean

/**
 * `fs.read` → `FS_DATA` chunks → `fs.read.end` (docs/PROTOCOL.md "Phone files").
 *
 * Each read runs on its own thread and hands one 256 KiB frame at a time to the
 * session's bulk lane; that lane is the share-in pacing (at most 1 MiB queued),
 * so the producer blocks instead of buffering the file and at most four chunks
 * are in flight. `FS_DATA` and the closing `fs.read.end` both ride the bulk
 * lane: a JSON-lane reply would overtake the data and end a read early.
 *
 * A cancel only stops the producer; up to the 1 MiB already queued may still
 * drain to the Mac, which drops frames for an abandoned id.
 */
class FsReader(
    private val paths: FsPaths,
    private val sendBulk: (ByteArray) -> Boolean,
    private val sendJson: (Map<String, Any?>) -> Unit,
    private val log: (String) -> Unit = {},
    private val chunkBytes: Int = CHUNK_BYTES,
    private val maxReads: Int = MAX_READS,
) {
    private class Job(val id: Long, val file: File, val offset: Long, val length: Long) {
        val cancelled = AtomicBoolean(false)
        var thread: Thread? = null
    }

    private val lock = Object()
    private val jobs = HashMap<Long, Job>()

    /** Starts one range read; refusals answer `error` and stream nothing. */
    fun begin(obj: Map<String, Any?>) {
        // The wire id is a u32: keep it unsigned in JSON replies (an Int would
        // answer a negative number for half of all ids, and the Mac matches on it).
        val id = (obj["id"] as? Number)?.toLong()?.takeIf { it in 1..0xFFFF_FFFFL } ?: return
        val offset = Json.long(obj["offset"]) ?: -1L
        val length = Json.long(obj["length"]) ?: -1L
        val file = try {
            paths.resolve(Json.str(obj["path"]))
        } catch (e: FsFailure) {
            return refuse(id, e)
        }
        val meta = paths.meta(file) ?: return refuse(id, FsPaths.notFound())
        if (meta.dir) return refuse(id, FsPaths.notADir())
        val etag = Json.str(obj["etag"])
        if (etag != null && etag != paths.etag(meta)) return refuse(id, FsPaths.stale())
        if (offset < 0 || length < 0 || offset > meta.size || length > meta.size - offset) {
            return refuse(id, FsPaths.denied("range outside the file"))
        }
        val job = Job(id, file, offset, length)
        synchronized(lock) {
            if (jobs.size >= maxReads) return refuse(id, FsPaths.busy())
            if (jobs.containsKey(id)) return refuse(id, FsPaths.busy())
            jobs[id] = job
        }
        job.thread = Thread({ run(job) }, "pocketdeck-fsread").also {
            it.isDaemon = true
            it.start()
        }
    }

    /** `fs.cancel`: the producer stops before its next chunk. */
    fun cancel(id: Long) {
        val job = synchronized(lock) { jobs[id] } ?: return
        job.cancelled.set(true)
    }

    /** Session end: abandon every read and wait briefly for the producers. */
    fun close() {
        val running = synchronized(lock) { jobs.values.toList() }
        running.forEach { it.cancelled.set(true) }
        running.forEach { runCatching { it.thread?.join(1_000) } }
    }

    private fun refuse(id: Long, failure: FsFailure) {
        log("fs: read id=$id ${failure.code}")
        sendJson(mapOf("t" to "error", "code" to failure.code,
            "message" to (failure.message ?: ""), "id" to id))
    }

    private fun run(job: Job) {
        try {
            FileInputStream(job.file).use { input ->
                input.channel.position(job.offset)
                val digest = MessageDigest.getInstance("SHA-256")
                val buffer = ByteArray(minOf(chunkBytes.toLong(), maxOf(job.length, 1L)).toInt())
                var done = 0L
                while (done < job.length) {
                    if (job.cancelled.get()) return
                    val want = minOf(buffer.size.toLong(), job.length - done).toInt()
                    val n = input.read(buffer, 0, want)
                    if (n < 0) {
                        // The file shrank under us: the range is no longer there.
                        return refuse(job.id, FsPaths.stale())
                    }
                    if (n == 0) continue
                    digest.update(buffer, 0, n)
                    if (!sendBulk(Frames.encode(Frames.TYPE_FS_DATA, job.id.toInt(), buffer.copyOf(n)))) {
                        log("fs: read id=${job.id} abandoned at $done bytes")
                        return
                    }
                    done += n
                }
                if (job.cancelled.get()) return
                val end = mapOf(
                    "t" to "fs.read.end",
                    "id" to job.id,
                    "size" to done,
                    "sha256" to Crypto.toHex(digest.digest()),
                )
                sendBulk(Frames.encodeJson(0, Json.encode(end)))
                log("fs: read id=${job.id} $done bytes")
            }
        } catch (e: Exception) {
            log("fs: read id=${job.id} failed: ${e.javaClass.simpleName}")
            refuse(job.id, FsFailure("fs_denied", "the file could not be read"))
        } finally {
            synchronized(lock) { jobs.remove(job.id) }
        }
    }

    companion object {
        /** The drop/share chunk size: four fit the bulk lane's 1 MiB. */
        const val CHUNK_BYTES = 256 * 1024
        const val MAX_READS = 8
    }
}
