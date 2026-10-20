package dev.pocketdeck.server

import dev.pocketdeck.proto.Crypto
import dev.pocketdeck.proto.Json
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * `fs.write` → `FS_DATA` chunks → verification → rename → media scan
 * (docs/PROTOCOL.md "Phone files", docs/design/files.md §2/§5).
 *
 * The bytes go into a hidden temp in the target's own folder, so the rename is
 * same-filesystem and atomic from the person's point of view. The temp is
 * verified against the announced size and SHA-256, the etag the Mac believed in
 * is checked again right before the rename, and only then does the finished
 * file replace the target. A cancel, a session end, a mismatch or a refusal
 * deletes the temp; the target is left exactly as it was.
 *
 * One write at a time: a second id answers `fs_busy`. Frames are taken on the
 * session's reader thread, so the phone pushes back on the Mac exactly where
 * the drop path does (a bounded queue, at most 8 × 256 KiB).
 */
class FsWriter(
    private val paths: FsPaths,
    private val platform: FsPlatform,
    private val sendJson: (Map<String, Any?>) -> Unit,
    private val log: (String) -> Unit = {},
    private val wallClock: () -> Long = { System.currentTimeMillis() },
    private val maxBytes: Long = MAX_WRITE_BYTES,
) {
    private class Job(
        val id: Long,
        val target: File,
        val temp: File,
        val size: Long,
        val sha256: String,
        val etag: String?,
        val exclusive: Boolean,
    ) {
        val chunks = ArrayBlockingQueue<ByteArray>(QUEUE_CHUNKS)
        val cancelled = AtomicBoolean(false)
        var received = 0L
        var thread: Thread? = null
    }

    private val lock = Object()
    private var job: Job? = null

    /** Starts the write; every refusal answers `fs.result` and touches nothing. */
    fun begin(obj: Map<String, Any?>) {
        val id = (obj["id"] as? Number)?.toLong()?.takeIf { it in 1..0xFFFF_FFFFL } ?: return
        val size = Json.long(obj["size"]) ?: -1L
        val sha256 = Json.str(obj["sha256"])?.lowercase()
        if (size < 0) return refusal(id, FsPaths.denied("no size"))
        if (size > maxBytes) {
            // The cap is checked before a byte arrives (design §3).
            return refusal(id, FsFailure("fs_too_large", "over the write cap"))
        }
        if (sha256 == null || !SHA256_HEX.matches(sha256)) {
            return refusal(id, FsPaths.denied("bad digest"))
        }
        val target = try {
            paths.resolve(Json.str(obj["path"]))
        } catch (e: FsFailure) {
            return refusal(id, e)
        }
        val meta = paths.meta(target)
        if (meta == null) {
            val parent = target.parentFile
            if (parent == null || !parent.isDirectory) {
                return refusal(id, FsPaths.notFound())
            }
        }
        if (meta?.dir == true) {
            // A write never replaces a directory (design §4).
            return refusal(id, FsPaths.denied("a directory is not a file"))
        }
        val etag = Json.str(obj["etag"])
        // A create never replaces what is already there: the file may have
        // appeared since the Mac's last listing (a photo taken meanwhile). A
        // replace must name the version it replaces (design §4).
        val exclusive = Json.bool(obj["exclusive"]) == true
        if (exclusive || etag == null) {
            if (meta != null) return refusal(id, FsPaths.exists())
        } else if (meta == null || etag != paths.etag(meta)) {
            return refusal(id, FsPaths.stale())
        }
        sweepStaleTemps(target)
        val next = Job(id, target, tempFor(target), size, sha256, etag, exclusive)
        synchronized(lock) {
            if (job != null) return refusal(id, FsPaths.busy())
            job = next
        }
        next.thread = Thread({ run(next) }, "pocketdeck-fswrite").also {
            it.isDaemon = true
            it.start()
        }
    }

    /** Bytes for write [id]; frames for an unknown or finished id are dropped. */
    fun data(id: Long, payload: ByteArray) {
        val current = synchronized(lock) { job } ?: return
        if (current.id != id || current.cancelled.get() || payload.isEmpty()) return
        current.received += payload.size
        if (current.received > current.size) {
            log("fs: write id=$id more bytes than announced")
            current.cancelled.set(true)
            return
        }
        while (!current.cancelled.get()) {
            if (current.chunks.offer(payload, 200, TimeUnit.MILLISECONDS)) return
        }
    }

    /** `fs.cancel`: the temp goes, the target stays. */
    fun cancel(id: Long) {
        val current = synchronized(lock) { job } ?: return
        if (current.id == id) current.cancelled.set(true)
    }

    /** Session end: stop every write and remove its temp. */
    fun close() {
        val current = synchronized(lock) { job } ?: return
        current.cancelled.set(true)
        runCatching { current.thread?.join(2_000) }
        runCatching { if (current.temp.isFile) current.temp.delete() }
    }

    private fun run(job: Job) {
        var ok = false
        try {
            FileOutputStream(job.temp).use { writer ->
                val digest = MessageDigest.getInstance("SHA-256")
                var done = 0L
                var lastProgress = wallClock() - PROGRESS_INTERVAL_MS
                while (done < job.size) {
                    if (job.cancelled.get()) return
                    val chunk = job.chunks.poll(200, TimeUnit.MILLISECONDS) ?: continue
                    val take = minOf(job.size - done, chunk.size.toLong()).toInt()
                    writer.write(chunk, 0, take)
                    digest.update(chunk, 0, take)
                    done += take
                    val now = wallClock()
                    if (now - lastProgress >= PROGRESS_INTERVAL_MS) {
                        lastProgress = now
                        sendJson(mapOf("t" to "fs.progress", "id" to job.id, "bytes" to done))
                    }
                }
                if (job.cancelled.get()) return
                writer.fd.sync()
                // The last byte, as one more progress (the drop rule).
                sendJson(mapOf("t" to "fs.progress", "id" to job.id, "bytes" to job.size))
                if (Crypto.toHex(digest.digest()) != job.sha256) {
                    log("fs: write id=${job.id} checksum mismatch")
                    return refusal(job.id, FsPaths.denied("the file arrived damaged"))
                }
                // The etag moved while the bytes were arriving: keep the
                // person's current file, drop ours.
                if (job.etag != null) {
                    val current = paths.meta(job.target) ?: return refusal(job.id, FsPaths.stale())
                    if (current.dir || paths.etag(current) != job.etag) {
                        return refusal(job.id, FsPaths.stale())
                    }
                }
                if (job.cancelled.get()) return
                // A create checked again right here: a file that appeared under
                // the same name while the bytes were streaming stays untouched.
                if (job.exclusive && paths.meta(job.target) != null) {
                    return refusal(job.id, FsPaths.exists())
                }
                if (!platform.rename(job.temp, job.target) && !platform.plainRename(job.temp, job.target)) {
                    log("fs: write id=${job.id} could not name the file")
                    return refusal(job.id, FsPaths.denied("could not name the file"))
                }
                ok = true
                runCatching { platform.scan(listOf(job.target)) }
                val item = paths.item(job.target)
                sendJson(mapOf("t" to "fs.result", "id" to job.id, "ok" to true,
                    "item" to item.toJson(), "etag" to item.etag))
                log("fs: write id=${job.id} ${job.size} bytes")
            }
        } catch (e: Exception) {
            log("fs: write id=${job.id} failed: ${e.javaClass.simpleName}")
            refusal(job.id, FsPaths.denied("the write failed"))
        } finally {
            synchronized(lock) { if (this.job === job) this.job = null }
            if (!ok) runCatching { if (job.temp.isFile) job.temp.delete() }
        }
    }

    private fun refusal(id: Long, failure: FsFailure) {
        log("fs: write id=$id ${failure.code}")
        sendJson(mapOf("t" to "fs.result", "id" to id, "ok" to false,
            "code" to failure.code, "message" to (failure.message ?: "")))
    }

    /**
     * Removes staging files a killed process left in the target's folder. One
     * directory per write, and only files older than a day: a live write's temp
     * is never touched, and no one has to walk the whole card.
     */
    private fun sweepStaleTemps(target: File) {
        val cutoff = wallClock() - STALE_TEMP_MS
        target.parentFile?.listFiles()?.forEach { file ->
            if (FsPaths.isTempName(file.name) && file.lastModified() < cutoff) {
                runCatching { file.delete() }
            }
        }
    }

    private fun tempFor(target: File): File =
        File(target.parentFile ?: paths.rootFile(), FsPaths.TEMP_PREFIX +
            java.util.UUID.randomUUID().toString().replace("-", "") + FsPaths.TEMP_SUFFIX)

    companion object {
        /** The 1 GiB announced-size cap (design §3); larger is refused before a byte. */
        const val MAX_WRITE_BYTES = 1L shl 30
        const val QUEUE_CHUNKS = 8
        const val PROGRESS_INTERVAL_MS = 250L
        /** A staging file older than this is a crash leftover, not a live write. */
        const val STALE_TEMP_MS = 24 * 60 * 60 * 1000L
        private val SHA256_HEX = Regex("^[0-9a-f]{64}$")
    }
}

/**
 * What a write or a move needs from the platform (docs/design/files.md §2):
 * the media-aware rename, a plain rename as the fallback, the media scan that
 * makes a new file show up in Files/Photos, and the timestamp setter.
 */
interface FsPlatform {
    /**
     * Rename [from] onto [to] through the media-aware path. At shell uid the
     * shared-storage mount routes a rename through MediaProvider, which keeps
     * its database rows in step (design §2).
     */
    fun rename(from: File, to: File): Boolean

    /** The fallback when [rename] refuses: a plain filesystem rename. */
    fun plainRename(from: File, to: File): Boolean

    /** Makes finished files visible without a remount; best effort. */
    fun scan(files: List<File>)

    /** Sets the modification time; false when the platform refused. */
    fun setLastModified(file: File, mtimeMs: Long): Boolean

    companion object {
        /** A platform for a host that has none (JVM tests): plain renames, no scan. */
        val None = object : FsPlatform {
            override fun rename(from: File, to: File): Boolean = from.renameTo(to)
            override fun plainRename(from: File, to: File): Boolean = from.renameTo(to)
            override fun scan(files: List<File>) {}
            override fun setLastModified(file: File, mtimeMs: Long): Boolean = file.setLastModified(mtimeMs)
        }
    }
}
