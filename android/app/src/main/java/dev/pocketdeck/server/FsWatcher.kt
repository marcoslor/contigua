package dev.pocketdeck.server

import java.io.File

/** One running platform watch; [close] stops it and tolerates being called twice. */
fun interface FsWatchHandle {
    fun close()
}

/**
 * The platform's change source (docs/design/files.md §2, §5): one non-recursive
 * watch per folder, plus a media-generation value for the fallback when a watch
 * cannot be placed.
 *
 * A seam, not an implementation detail: the JVM tests drive a fake source with
 * no Android in sight.
 */
interface FsWatchSource {
    /**
     * Starts one watch on [dir]'s own entries and calls [onEvent] with the
     * changed entry's name (null when the platform does not know it) for every
     * event after this call. Throws when the watch cannot be placed.
     */
    fun observe(dir: File, onEvent: (String?) -> Unit): FsWatchHandle

    /**
     * A number that moves whenever the shared volume's media database does
     * (the phone reads MediaStore's generation), or null on a platform without
     * one. Polled only while the fallback is needed.
     */
    fun generation(): Long?

    companion object {
        /** A platform that cannot watch: every watch request is refused. */
        val None = object : FsWatchSource {
            override fun observe(dir: File, onEvent: (String?) -> Unit): FsWatchHandle =
                throw FsPaths.denied("watching is not available")

            override fun generation(): Long? = null
        }
    }
}

/** The clock the watcher coalesces with; the tests move it by hand. */
interface FsTimers {
    /** Monotonic milliseconds. */
    fun now(): Long

    /** Runs [task] once after [delayMs]. */
    fun after(delayMs: Long, task: () -> Unit): FsWatchHandle

    companion object {
        /** One daemon timer thread for every session's watcher. */
        val Real = object : FsTimers {
            private val executor = java.util.concurrent.ScheduledThreadPoolExecutor(1) { runnable ->
                Thread(runnable, "pocketdeck-fs-watch").apply { isDaemon = true }
            }.apply { removeOnCancelPolicy = true }

            override fun now(): Long = System.nanoTime() / 1_000_000

            override fun after(delayMs: Long, task: () -> Unit): FsWatchHandle {
                val future = executor.schedule({ task() }, delayMs, java.util.concurrent.TimeUnit.MILLISECONDS)
                return FsWatchHandle { future.cancel(false) }
            }
        }
    }
}

/**
 * Watches exactly the folders the Mac has open (docs/design/files.md §2, §5):
 * one [FsWatchSource] watch per folder, event coalescing into `fs.changes`, and
 * the media-generation fallback when a folder cannot get a watch (the cap, or a
 * failed start).
 *
 * Nothing is watched before the first `fs.watch`: construction only builds the
 * bookkeeping. Every watch is gone after `fs.unwatch` of the last folder or a
 * session end ([close]).
 *
 * [send] is handed counts and folder paths only — never an entry name.
 */
class FsWatcher(
    private val paths: FsPaths,
    private val source: FsWatchSource,
    private val send: (Map<String, Any?>) -> Unit,
    private val timers: FsTimers = FsTimers.Real,
    private val maxWatches: Int = MAX_WATCHES,
    private val pollMs: Long = GENERATION_POLL_MS,
    private val log: (String) -> Unit = {},
) {
    private val lock = Any()

    /** Wanted folder → its live watch, or null when the fallback covers it. */
    private val wanted = LinkedHashMap<String, FsWatchHandle?>()
    private val pending = LinkedHashSet<String>()
    private var flushScheduled = false
    private var lastFlush = Long.MIN_VALUE / 4
    private var pollScheduled = false
    private var lastGeneration: Long? = null
    private var closed = false

    /**
     * Adds [requested] folders. Any path the shape rules reject refuses the
     * whole batch and changes nothing.
     */
    fun watch(requested: List<String?>) {
        val folders = requested.map { folder(it) }
        synchronized(lock) {
            if (closed) return
            for ((rel, dir) in folders) {
                if (wanted.containsKey(rel)) continue
                wanted[rel] = startLocked(rel, dir)
            }
            ensurePollLocked()
        }
    }

    /** Forgets [requested] folders; one that is not watched is ignored. */
    fun unwatch(requested: List<String?>) {
        val folders = requested.map { paths.resolve(it) }.map { file ->
            if (file.path == paths.rootPath) "" else file.path.removePrefix(paths.rootPath + File.separator)
        }
        synchronized(lock) {
            if (closed) return
            for (rel in folders) {
                wanted.remove(rel)?.close()
                pending.remove(rel)
            }
            if (wanted.isEmpty()) {
                pending.clear()
                lastGeneration = null
            }
        }
    }

    /** The session ended: no watch, no timer and no poll survives. */
    fun close() {
        synchronized(lock) {
            if (closed) return
            closed = true
            for (handle in wanted.values) handle?.close()
            wanted.clear()
            pending.clear()
            lastGeneration = null
        }
    }

    /** How many folders are wanted and how many have a kernel watch (tests). */
    fun counts(): Pair<Int, Int> = synchronized(lock) {
        wanted.size to wanted.values.count { it != null }
    }

    // MARK: internals

    /** A relative folder path and its canonical file; refuses a file or a miss. */
    private fun folder(raw: String?): Pair<String, File> {
        val file = paths.resolve(raw)
        val meta = paths.meta(file) ?: throw FsPaths.notFound()
        if (!meta.dir) throw FsPaths.notADir()
        if (file.path == paths.rootPath) return "" to file
        return file.path.removePrefix(paths.rootPath + File.separator) to file
    }

    private fun startLocked(rel: String, dir: File): FsWatchHandle? {
        if (wanted.values.count { it != null } >= maxWatches) {
            log("fs: watch cap reached")
            return null
        }
        return try {
            source.observe(dir) { name ->
                // Our own staging file is not a change the Mac may see.
                if (name == null || !FsPaths.isTempName(name)) changed(rel)
            }
        } catch (e: Throwable) {
            if (e is VirtualMachineError) throw e
            log("fs: a watch failed (${e.javaClass.simpleName})")
            null
        }
    }

    private fun changed(rel: String) {
        synchronized(lock) {
            if (closed || !wanted.containsKey(rel)) return
            pending += rel
            scheduleFlushLocked()
        }
    }

    private fun scheduleFlushLocked() {
        if (flushScheduled || pending.isEmpty()) return
        flushScheduled = true
        val wait = (lastFlush + FLUSH_MS - timers.now()).coerceAtLeast(0)
        timers.after(wait) { flush() }
    }

    private fun flush() {
        val batch: List<String>
        synchronized(lock) {
            flushScheduled = false
            if (closed || pending.isEmpty()) return
            lastFlush = timers.now()
            batch = pending.toList()
            pending.clear()
        }
        send(mapOf("t" to "fs.changes", "paths" to batch))
        log("fs: changes ${batch.size} folders")
    }

    /** The fallback needs a poll only while a wanted folder has no watch. */
    private fun ensurePollLocked() {
        if (closed || pollScheduled || wanted.isEmpty()) return
        if (!wanted.values.any { it == null }) return
        if (runCatching { source.generation() }.getOrNull() == null) return
        pollScheduled = true
        timers.after(pollMs) { poll() }
    }

    private fun poll() {
        synchronized(lock) {
            pollScheduled = false
            if (closed || wanted.isEmpty() || !wanted.values.any { it == null }) {
                lastGeneration = null
                return
            }
        }
        val generation = runCatching { source.generation() }.getOrNull()
        synchronized(lock) {
            if (closed) return
            val moved = generation != null && lastGeneration != null && generation != lastGeneration
            lastGeneration = generation
            if (moved) {
                pending += wanted.keys
                scheduleFlushLocked()
            }
            if (wanted.isEmpty() || !wanted.values.any { it == null }) {
                lastGeneration = null
                return
            }
            pollScheduled = true
            timers.after(pollMs) { poll() }
        }
    }

    companion object {
        /** Live watches per session (docs/design/files.md §2, §5). */
        const val MAX_WATCHES = 256
        /** One `fs.changes` per this window at most (≤ 4 per second). */
        const val FLUSH_MS = 250L
        /** The media-generation fallback's period. */
        const val GENERATION_POLL_MS = 5_000L
    }
}
