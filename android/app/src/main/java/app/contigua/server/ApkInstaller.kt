package app.contigua.server

import java.security.MessageDigest
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * One APK install at a time, streamed from `APK_DATA` frames into a pm install
 * session (docs/design/apk.md). The session's reader thread calls [begin],
 * [data] and [cancel]; pm runs on this class's own thread so a slow pm only
 * blocks the reader once the bounded queue is full.
 */
class ApkInstaller(
    private val shell: PackageShell,
    private val send: (Map<String, Any?>) -> Unit,
    private val log: (String) -> Unit = {},
    private val wallClock: () -> Long = { System.currentTimeMillis() },
    private val stallTimeoutMs: Long = 60_000,
) {
    private class Job(val id: Long, val parts: List<ApkPolicy.Part>, val total: Long) {
        val chunks = ArrayBlockingQueue<ByteArray>(QUEUE_CHUNKS)
        @Volatile var cancelled = false
        @Volatile var failed = false
        var received = 0L
        var thread: Thread? = null
    }

    private val lock = Object()
    private var job: Job? = null

    fun begin(obj: Map<String, Any?>) {
        val id = (obj["id"] as? Number)?.toLong() ?: 0L
        val parts = ApkPolicy.parts(obj["files"])
        when {
            id <= 0 || id > 0xFFFF_FFFFL || parts == null ->
                return result(id, false, "bad_request", "apk.install needs an id and .apk files with size and sha256")
            ApkPolicy.total(parts) > ApkPolicy.MAX_TOTAL_BYTES ->
                return result(id, false, "too_large", "over ${ApkPolicy.MAX_TOTAL_BYTES} bytes")
        }
        val next = Job(id, parts!!, ApkPolicy.total(parts))
        synchronized(lock) {
            if (job != null) return result(id, false, "busy", "another install is running")
            job = next
        }
        next.thread = Thread({ run(next) }, "contigua-apk").also { it.isDaemon = true; it.start() }
    }

    /** Bytes for install [id]; frames for an unknown or finished install are dropped. */
    fun data(id: Long, payload: ByteArray) {
        val current = synchronized(lock) { job } ?: return
        if (current.id != id || current.cancelled || current.failed || payload.isEmpty()) return
        current.received += payload.size
        if (current.received > current.total) {
            log("apk $id: more bytes than announced")
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

    /** Session teardown: abandon whatever is running, without replying. */
    fun close() {
        val current = synchronized(lock) { job } ?: return
        current.cancelled = true
        runCatching { current.thread?.join(2_000) }
    }

    private fun run(job: Job) {
        val started = wallClock()
        var session: Int? = null
        try {
            val created = shell.create(job.total)
            session = ApkPolicy.sessionId(created) ?: run {
                val (code, message) = ApkPolicy.failure(created)
                return finish(job, null, false, code, message)
            }
            var pending: ByteArray? = null
            var pendingOffset = 0
            var done = 0L
            var lastProgress = 0L
            for (part in job.parts) {
                val writer = shell.write(session, part.name, part.size)
                val digest = MessageDigest.getInstance("SHA-256")
                var left = part.size
                while (left > 0) {
                    if (pending == null || pendingOffset == pending.size) {
                        pending = take(job) ?: run {
                            writer.abort()
                            return finish(job, session, false, if (job.cancelled) "cancelled" else "failed",
                                if (job.cancelled) "cancelled" else "the stream stopped")
                        }
                        pendingOffset = 0
                    }
                    val n = minOf(left, (pending.size - pendingOffset).toLong()).toInt()
                    writer.write(pending, pendingOffset, n)
                    digest.update(pending, pendingOffset, n)
                    pendingOffset += n
                    left -= n
                    done += n
                    val now = wallClock()
                    if (now - lastProgress >= PROGRESS_INTERVAL_MS) {
                        lastProgress = now
                        send(mapOf("t" to "apk.progress", "id" to job.id, "bytes" to done))
                    }
                }
                val written = writer.finish()
                if (!ApkPolicy.isSuccess(written)) {
                    val (code, message) = ApkPolicy.failure(written)
                    return finish(job, session, false, code, message)
                }
                val sha = digest.digest().joinToString("") { "%02x".format(it) }
                if (sha != part.sha256) return finish(job, session, false, "checksum", "${part.name} arrived damaged")
            }
            send(mapOf("t" to "apk.progress", "id" to job.id, "bytes" to done))
            val committed = shell.commit(session)
            if (!ApkPolicy.isSuccess(committed)) {
                val (code, message) = ApkPolicy.failure(committed)
                return finish(job, null, false, code, message)
            }
            val app = runCatching { shell.newestSince(started - CLOCK_SLACK_MS) }.getOrNull()
            finish(job, null, true, app = app)
        } catch (e: Exception) {
            log("apk ${job.id} failed: ${e.message}")
            finish(job, session, false, "failed", e.message ?: "install failed")
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

    /** Abandons [session] when given, clears the job and sends the one `apk.result`. */
    private fun finish(job: Job, session: Int?, ok: Boolean, code: String? = null, message: String? = null, app: InstalledApp? = null) {
        if (session != null) runCatching { shell.abandon(session) }
        synchronized(lock) { if (this.job === job) this.job = null }
        if (!ok) job.failed = true
        if (ok) {
            log("apk ${job.id} installed ${app?.pkg}")
            send(mapOf("t" to "apk.result", "id" to job.id, "ok" to true,
                "pkg" to app?.pkg, "label" to app?.label, "version" to app?.version))
        } else {
            log("apk ${job.id} failed: $code $message")
            result(job.id, false, code ?: "failed", message ?: "")
        }
    }

    private fun result(id: Long, ok: Boolean, code: String, message: String) {
        send(mapOf("t" to "apk.result", "id" to id, "ok" to ok, "code" to code, "message" to message))
    }

    companion object {
        /** ≤ 8 MiB in flight between the socket and pm (frames are ≤ 1 MiB). */
        const val QUEUE_CHUNKS = 8
        const val PROGRESS_INTERVAL_MS = 250L
        /** pm stamps lastUpdateTime from its own clock; allow a little skew. */
        const val CLOCK_SLACK_MS = 2_000L
    }
}
