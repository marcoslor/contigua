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
    private val folderPollMs: Long = FOLDER_POLL_MS,
    private val log: (String) -> Unit = {},
) {
    private val lock = Any()

    /** Wanted folder → its live watch, or null when the fallback covers it. */
    private val wanted = LinkedHashMap<String, FsWatchHandle?>()
    /** Wanted folder → its directory, for the poll (design §5 round 2). */
    private val dirs = HashMap<String, File>()
    /** Each watched folder's last reported shape, so the poll can see a move. */
    private val fingerprints = HashMap<String, Long>()
    private var folderPoll: FsWatchHandle? = null
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
                dirs[rel] = dir
                wanted[rel] = startLocked(rel, dir)
            }
            ensurePollLocked()
            scheduleFolderPollLocked()
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
                dirs.remove(rel)
                fingerprints.remove(rel)
                pending.remove(rel)
            }
            if (wanted.isEmpty()) {
                pending.clear()
                lastGeneration = null
                stopFolderPollLocked()
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
            dirs.clear()
            fingerprints.clear()
            pending.clear()
            lastGeneration = null
            stopFolderPollLocked()
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
        // This batch *is* the change: the poll's next look starts from here, so
        // one change is one message whether inotify, the poll or both saw it.
        synchronized(lock) {
            for (rel in batch) {
                val dir = dirs[rel] ?: continue
                fingerprint(dir)?.let { fingerprints[rel] = it }
            }
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

    // MARK: the folder poll (S5 round 2)

    /**
     * One tick of the folder poll while anything is watched. Only a timer is
     * scheduled here — no thread of our own — and nothing is scheduled at all
     * when no folder is wanted.
     */
    private fun scheduleFolderPollLocked() {
        if (closed || folderPoll != null || wanted.isEmpty()) return
        folderPoll = timers.after(folderPollMs) { pollFolders() }
    }

    private fun stopFolderPollLocked() {
        folderPoll?.close()
        folderPoll = null
    }

    /**
     * Compares every wanted folder with the shape it had last time. The first
     * look at a folder is its baseline, not a change. A folder that moved is
     * reported through the same pending set as the watches, so a change seen by
     * both is still one `fs.changes`.
     */
    private fun pollFolders() {
        val due: List<Pair<String, File>>
        synchronized(lock) {
            folderPoll = null
            if (closed || wanted.isEmpty()) return
            due = wanted.keys.mapNotNull { rel -> dirs[rel]?.let { rel to it } }
        }
        val moved = ArrayList<String>(1)
        for ((rel, dir) in due) {
            val now = fingerprint(dir) ?: continue
            synchronized(lock) {
                val before = fingerprints.put(rel, now)
                if (before != null && before != now && wanted.containsKey(rel)) moved += rel
            }
        }
        for (rel in moved) changed(rel)
        synchronized(lock) { scheduleFolderPollLocked() }
    }

    /**
     * A folder's shape, never its names: a hash over the entry names (our own
     * staging names left out), the folder's own mtime and the entry count, plus
     * each entry's size and mtime while the folder is small enough for the
     * stats to stay cheap.
     */
    private fun fingerprint(dir: File): Long? {
        val names = dir.list()?.filterNot { FsPaths.isTempName(it) } ?: return null
        var hash = 1125899906842597L
        for (name in names) hash = 31 * hash + name.hashCode()
        hash = 31 * hash + dir.lastModified()
        hash = 31 * hash + names.size
        if (names.size <= MAX_STAT_ENTRIES) {
            for (name in names) {
                val entry = File(dir, name)
                hash = 31 * hash + entry.length()
                hash = 31 * hash + entry.lastModified()
            }
        }
        return hash
    }

    companion object {
        /** Live watches per session (docs/design/files.md §2, §5). */
        const val MAX_WATCHES = 256
        /** One `fs.changes` per this window at most (≤ 4 per second). */
        const val FLUSH_MS = 250L
        /** The media-generation fallback's period. */
        const val GENERATION_POLL_MS = 5_000L
        /**
         * How often a watched folder is compared by hand (S5 round 2). inotify
         * is silent on the FUSE mount for changes another process makes, so the
         * watch alone cannot be trusted; this poll is the guarantee behind it.
         */
        const val FOLDER_POLL_MS = 2_000L
        /** Entries whose size and mtime the poll looks at (big folders: names only). */
        const val MAX_STAT_ENTRIES = 300
    }
}
