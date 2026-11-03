package dev.pocketdeck.server

import dev.pocketdeck.proto.Crypto
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * One file drop at a time, streamed from `drop.start` + `DROP_DATA` frames into
 * `/sdcard/Download/PocketDeck/` (docs/design/dragdrop.md). The session's reader
 * thread calls [begin], [data] and [cancel]; writing runs on this class's own
 * thread so a slow disk only blocks the reader once the bounded queue is full —
 * the same shape as [ApkInstaller]. The landing steps (media scan, SEND) are the
 * injected [Landing]; at shell UID the filesystem of `/sdcard/Download` needs no
 * extra privilege.
 *
 * The bytes go into a hidden temp keyed by `(size, sha256)`. A later `drop.start`
 * with `resume:bytes` for the same file hashes the prefix against the announced
 * digest, appends from there, and keeps the temp when the session dies; an
 * explicit cancel, a checksum mismatch or an over-cap drop removes it.
 */
class DropReceiver(
    private val landing: Landing,
    private val send: (Map<String, Any?>) -> Unit,
    private val log: (String) -> Unit = {},
    private val wallClock: () -> Long = { System.currentTimeMillis() },
    private val stallTimeoutMs: Long = 60_000,
) {
    /**
     * What happens once the file is renamed in place (the real one scans, then
     * collects the batch and offers one SEND after its last file).
     */
    fun interface Landing {
        fun land(file: File, mime: String, target: String?, index: Int, count: Int)
    }

    private class Job(
        val id: Long,
        val desk: DropPolicy.Desk,
        /** The offset the Mac asked to resume at; 0 streams from zero. */
        val resume: Long,
    ) {
        /**
         * The most bytes this run may accept: what follows the requested resume
         * offset. The temp can be longer than that (progress lags the disk), so
         * [run] accepts and expects only `size - temp.length()` when it resumes.
         */
        val allowed: Long = desk.size - resume
        val chunks = ArrayBlockingQueue<ByteArray>(QUEUE_CHUNKS)
        @Volatile var cancelled = false
        @Volatile var failed = false
        /** Set when the whole session went away: the temp stays for the next attempt. */
        @Volatile var abandoned = false
        var received = 0L
        var thread: Thread? = null
    }

    private val lock = Object()
    private var job: Job? = null

    /**
     * Starts the transfer. Invalid or busy drops answer `drop.result` and change
     * nothing on disk.
     */
    fun begin(obj: Map<String, Any?>) {
        val announcedId = (obj["id"] as? Number)?.toLong() ?: 0L
        val transfer = try {
            DropPolicy.parse(obj)
        } catch (e: DropPolicy.Rejected) {
            return result(announcedId, ok = false, code = e.code, message = e.message ?: "")
        }
        val request = (obj["resume"] as? Number)?.toLong()?.coerceAtLeast(0) ?: 0L
        // A resume at or past the size is nonsense: it arrives as a restart.
        val next = Job(transfer.id, transfer.desk, request.takeIf { it in 1 until transfer.desk.size } ?: 0L)
        synchronized(lock) {
            if (job != null) return result(next.id, false, "busy", "another drop is running")
            job = next
        }
        next.thread = Thread({ run(next) }, "pocketdeck-drop").also {
            it.isDaemon = true
            it.start()
        }
    }

    /** Bytes for drop [id]; frames for an unknown or finished drop are dropped. */
    fun data(id: Long, payload: ByteArray) {
        val current = synchronized(lock) { job } ?: return
        if (current.id != id || current.cancelled || current.failed || payload.isEmpty()) return
        current.received += payload.size
        if (current.received > current.allowed) {
            log("drop $id: more bytes than announced")
            current.failed = true
            return
        }
        while (!current.cancelled && !current.failed) {
            if (current.chunks.offer(payload, 200, TimeUnit.MILLISECONDS)) return
        }
    }

    fun cancel(id: Long) {
        val current = synchronized(lock) { job } ?: return
        if (current.id == id) current.cancelled = true
    }

    /** Session teardown: abandons what is running; the temp survives for a resume. */
    fun close() {
        val current = synchronized(lock) { job } ?: return
        current.abandoned = true
        current.cancelled = true
        runCatching { current.thread?.join(2_000) }
    }

    private fun run(job: Job) {
        val temp = DropPolicy.tempFile(job.desk)
        try {
            File(DropPolicy.DIRECTORY).mkdirs()
            val resume = job.resume > 0 && temp.isFile && temp.length() >= job.resume
            val digest = MessageDigest.getInstance("SHA-256")
            var offset = 0L
            if (resume) {
                offset = temp.length()
                send(mapOf("t" to "drop.progress", "id" to job.id, "bytes" to offset))
                log("drop ${job.id}: resuming at $offset")
                // The final hash covers the whole file, so the prefix is read in.
                FileInputStream(temp).use { input ->
                    val existing = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(existing)
                        if (n < 0) break
                        if (n > 0) digest.update(existing, 0, n)
                    }
                }
            } else {
                // Not resuming (or the temp can't back that offset): a husk of
                // another attempt is worthless, and the Mac restarts at zero.
                temp.delete()
                send(mapOf("t" to "drop.progress", "id" to job.id, "bytes" to 0L))
                log("drop ${job.id}: streaming ${job.desk.size} bytes")
            }
            FileOutputStream(temp, resume).use { writer ->
                var lastProgress = wallClock() - PROGRESS_INTERVAL_MS
                var done = offset
                var pending: ByteArray? = null
                var pendingOffset = 0
                // The phone's own resume point, not the Mac's request: the temp
                // may hold more than the Mac had confirmed, and the Mac seeks to
                // the offset this run announced.
                var left = job.desk.size - offset
                while (left > 0) {
                    if (pending == null || pendingOffset == pending!!.size) {
                        pending = take(job) ?: run {
                            // An explicit cancel deletes; a stall or a lost session
                            // leaves the temp as the resume for the next try.
                            val cancelled = job.cancelled && !job.abandoned
                            return finish(job, temp, keep = job.abandoned || !job.cancelled,
                                if (cancelled) "cancelled" else "failed",
                                if (cancelled) "cancelled" else "the stream stopped")
                        }
                        pendingOffset = 0
                    }
                    val n = minOf(left, (pending!!.size - pendingOffset).toLong()).toInt()
                    writer.write(pending, pendingOffset, n)
                    digest.update(pending, pendingOffset, n)
                    pendingOffset += n
                    left -= n
                    done += n
                    val now = wallClock()
                    if (now - lastProgress >= PROGRESS_INTERVAL_MS) {
                        lastProgress = now
                        send(mapOf("t" to "drop.progress", "id" to job.id, "bytes" to done))
                    }
                }
                writer.fd.sync()
            }
            // The last byte, as one more progress; the result follows it.
            send(mapOf("t" to "drop.progress", "id" to job.id, "bytes" to job.desk.size))
            if (Crypto.toHex(digest.digest()) != job.desk.sha256) {
                return finish(job, temp, keep = false, "checksum", "the file arrived damaged")
            }
            val target = DropPolicy.target(DropPolicy.DIRECTORY, job.desk.name)
            if (!temp.renameTo(File(target))) {
                return finish(job, temp, keep = false, "failed", "could not name the file in the folder")
            }
            runCatching {
                landing.land(File(target), job.desk.mime, job.desk.target,
                             job.desk.index, job.desk.count)
            }
            log("drop ${job.id}: saved $target")
            send(mapOf("t" to "drop.result", "id" to job.id, "ok" to true, "path" to target))
            synchronized(lock) { if (this.job === job) this.job = null }
        } catch (e: Exception) {
            log("drop ${job.id} failed: ${e.message}")
            finish(job, temp, keep = job.abandoned && temp.isFile, "failed", e.message ?: "write failed")
        }
    }

    private fun take(job: Job): ByteArray? {
        var waited = 0L
        while (!job.cancelled && !job.failed) {
            job.chunks.poll(200, TimeUnit.MILLISECONDS)?.let { return it }
            waited += 200
            if (waited >= stallTimeoutMs) return null
        }
        return null
    }

    /**
     * Ends [job]; `keep` is false for every failure the Mac chose or that left
     * unusable data (cancel, checksum, write error) and true when the temp is a
     * resume — a stall and a session loss.
     */
    private fun finish(job: Job, temp: File, keep: Boolean, code: String, message: String) {
        if (!keep) runCatching { temp.delete() }
        job.failed = true
        synchronized(lock) { if (this.job === job) this.job = null }
        result(job.id, ok = false, code = code, message = message)
    }

    private fun result(id: Long, ok: Boolean, code: String, message: String) {
        if (ok) {
            send(mapOf("t" to "drop.result", "id" to id, "ok" to true))
        } else {
            send(mapOf("t" to "drop.result", "id" to id, "ok" to false, "code" to code, "message" to message))
        }
    }

    companion object {
        /** ≤ 8 MiB in flight between the socket and the file (frames are ≤ 1 MiB). */
        const val QUEUE_CHUNKS = 8
        const val PROGRESS_INTERVAL_MS = 250L
    }
}
