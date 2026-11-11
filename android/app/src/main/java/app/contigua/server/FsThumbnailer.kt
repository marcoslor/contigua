package app.contigua.server

import app.contigua.proto.Crypto
import app.contigua.proto.Frames
import app.contigua.proto.Json
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean

/**
 * `fs.thumb` (docs/PROTOCOL.md "Phone files" › "Thumbnails"): one thumbnail at
 * a time on one worker, at most [MAX_LIVE] live ids in arrival order, each
 * answer on the bulk lane `fs.read` uses.
 *
 * The platform's decode hides behind [ThumbSource] so the JVM tests can drive
 * the caps and the queue. Sending runs outside the lock: a blocked bulk lane
 * must not stop a cancel.
 */
class FsThumbnailer(
    private val paths: FsPaths,
    private val source: ThumbSource,
    private val sendBulk: (ByteArray) -> Boolean,
    private val sendJson: (Map<String, Any?>) -> Unit,
    private val log: (String) -> Unit = {},
    private val maxLive: Int = MAX_LIVE,
    private val maxBytes: Int = MAX_BYTES,
    private val longSideCap: Int = LONG_SIDE_CAP,
) {
    /** One accepted request; cancel follows the platform's signal through [onCancel]. */
    private class Job(val id: Long, val file: File, val video: Boolean, val size: Int) :
        ThumbCancellation {
        private val cancelled = AtomicBoolean(false)
        private val actions = CopyOnWriteArrayList<() -> Unit>()

        override fun isCancelled(): Boolean = cancelled.get()

        override fun onCancel(action: () -> Unit) {
            actions += action
            if (cancelled.get()) runCatching(action)
        }

        fun cancel() {
            if (cancelled.compareAndSet(false, true)) {
                actions.forEach { runCatching(it) }
            }
        }
    }

    private val lock = Object()
    /** Arrival order: the worker takes the first, so the queue is FIFO. */
    private val jobs = LinkedHashMap<Long, Job>()
    private var running = false
    private var worker: Thread? = null

    /** Starts one thumbnail; refusals answer `error` and generate nothing. */
    fun begin(obj: Map<String, Any?>) {
        // The wire id is a u32: keep it unsigned in JSON replies (an Int would
        // answer a negative number for half of all ids).
        val id = (obj["id"] as? Number)?.toLong()?.takeIf { it in 1..0xFFFF_FFFFL } ?: return
        val job = try {
            parse(id, obj)
        } catch (e: FsFailure) {
            return refuse(id, e)
        }
        synchronized(lock) {
            if (jobs.size >= maxLive) return refuse(id, FsPaths.busy())
            if (jobs.containsKey(id)) return refuse(id, FsPaths.busy())
            jobs[id] = job
        }
        startWorker()
    }

    /** `fs.cancel`: a queued job never starts; a running one signals the platform. */
    fun cancel(id: Long) {
        val job = synchronized(lock) { jobs[id] } ?: return
        job.cancel()
    }

    /** Session end: abandon every job and wait briefly for the worker. */
    fun close() {
        val open = synchronized(lock) { jobs.values.toList() }
        open.forEach { it.cancel() }
        synchronized(lock) { worker }?.join(1_000)
    }

    private fun parse(id: Long, obj: Map<String, Any?>): Job {
        val file = paths.resolve(Json.str(obj["path"]))
        val meta = paths.meta(file) ?: throw FsPaths.notFound()
        if (meta.dir) throw FsPaths.notADir()
        val etag = Json.str(obj["etag"])
        if (etag != null && etag != paths.etag(meta)) throw FsPaths.stale()
        val size = Json.long(obj["size"]) ?: -1L
        if (size < 1 || size > MAX_SIZE) throw FsPaths.denied("size outside 1-$MAX_SIZE")
        // A folder or a name the platform has no image/video type for has no
        // thumbnail; the Mac filters first, this is the phone's own check.
        val video = source.kind(file.name) ?: throw FsPaths.noThumb()
        return Job(id, file, video, size.toInt())
    }

    private fun startWorker() {
        synchronized(lock) {
            if (running) return
            running = true
            val thread = Thread({ drain() }, "contigua-fsthumb")
            thread.isDaemon = true
            worker = thread
            thread.start()
        }
    }

    private fun drain() {
        while (true) {
            val job = synchronized(lock) {
                jobs.entries.removeAll { it.value.isCancelled() }
                val first = jobs.values.firstOrNull()
                if (first == null) {
                    running = false
                    worker = null
                }
                first
            } ?: return
            val answer = render(job)
            val cancelled = job.isCancelled()
            synchronized(lock) { jobs.remove(job.id) }
            if (cancelled) {
                log("fs: thumb id=${job.id} cancelled")
                continue
            }
            if (answer == null) {
                refuse(job.id, FsPaths.noThumb())
                continue
            }
            send(job.id, answer)
        }
    }

    /** One encode, then the single q60 retry past the cap; null means no picture. */
    private fun render(job: Job): ThumbBytes? {
        val longSide = minOf(job.size, longSideCap)
        val first = source.render(job.file, job.video, longSide, QUALITY,
                                  allowPng = !job.video, cancel = job)
            ?: return null
        if (first.bytes.size <= maxBytes) return first
        if (job.isCancelled()) return null
        return source.render(job.file, job.video, longSide, RECODE_QUALITY, allowPng = false, cancel = job)
            ?.takeIf { it.bytes.size <= maxBytes }
    }

    private fun send(id: Long, answer: ThumbBytes) {
        val digest = Crypto.toHex(MessageDigest.getInstance("SHA-256").digest(answer.bytes))
        val end = mapOf(
            "t" to "fs.thumb.end",
            "id" to id,
            "mime" to answer.mime,
            "size" to answer.bytes.size,
            "sha256" to digest,
        )
        // The frame and the end both ride the bulk lane: a JSON-lane reply
        // would overtake the bytes (the fs.read rule).
        if (!sendBulk(Frames.encode(Frames.TYPE_FS_DATA, id.toInt(), answer.bytes))) {
            log("fs: thumb id=$id abandoned")
            return
        }
        sendBulk(Frames.encodeJson(0, Json.encode(end)))
        log("fs: thumb id=$id ${answer.bytes.size} bytes ${answer.mime}")
    }

    private fun refuse(id: Long, failure: FsFailure) {
        log("fs: thumb id=$id ${failure.code}")
        sendJson(mapOf("t" to "error", "code" to failure.code,
            "message" to (failure.message ?: ""), "id" to id))
    }

    companion object {
        /** The Mac may ask for 2048; past 512 the answer is only a waste of bytes. */
        const val LONG_SIDE_CAP = 512
        const val MAX_BYTES = 256 * 1024
        const val MAX_LIVE = 3
        /** The wire's own bound (docs/PROTOCOL.md "Thumbnails"). */
        const val MAX_SIZE = 4096L
        const val QUALITY = 80
        const val RECODE_QUALITY = 60
    }
}
