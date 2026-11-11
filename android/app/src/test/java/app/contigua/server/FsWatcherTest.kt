package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.Collections

/**
 * `fs.watch` / `fs.unwatch` / `fs.changes` (docs/PROTOCOL.md "Watching",
 * docs/design/files.md §2/§5): nothing watched while idle, only the requested
 * folders, teardown, coalescing, temp files ignored, the cap's generation
 * fallback, and the Android/hidden refusals. A fake source and a hand-moved
 * clock stand in for inotify.
 */
class FsWatcherTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private lateinit var paths: FsPaths
    private lateinit var source: FakeSource
    private lateinit var timers: ManualTimers
    private lateinit var watcher: FsWatcher
    private lateinit var root: File
    private val sent = Collections.synchronizedList(mutableListOf<Map<String, Any?>>())

    private class FakeHandle(val dir: File, val fire: (String?) -> Unit) : FsWatchHandle {
        var closed = false
        override fun close() {
            closed = true
        }
    }

    private class FakeSource(var generation: Long? = null) : FsWatchSource {
        val handles = Collections.synchronizedList(mutableListOf<FakeHandle>())
        var fail = false

        override fun observe(dir: File, onEvent: (String?) -> Unit): FsWatchHandle {
            if (fail) throw IllegalStateException("no inotify")
            return FakeHandle(dir, onEvent).also { handles += it }
        }

        override fun generation(): Long? = generation

        fun emit(dir: String, name: String?) {
            synchronized(handles) {
                handles.filter { it.dir.name == dir && !it.closed }.forEach { it.fire(name) }
            }
        }
    }

    /** A clock the test moves by hand; `after` tasks run on `advance`. */
    private class ManualTimers : FsTimers {
        private var clock = 1_000L
        private var generation = 0
        private val tasks = mutableListOf<Pair<Long, Pair<Int, () -> Unit>>>()

        override fun now(): Long = clock

        override fun after(delayMs: Long, task: () -> Unit): FsWatchHandle {
            val id = generation++
            tasks += clock + delayMs to (id to task)
            return FsWatchHandle { tasks.removeAll { it.second.first == id } }
        }

        /** Tasks still waiting to run: a watcher that is idle schedules none. */
        fun pending(): Int = tasks.size

        fun advance(ms: Long) {
            val target = clock + ms
            while (true) {
                clock = target
                val due = tasks.filter { it.first <= target }.sortedBy { it.first }
                if (due.isEmpty()) return
                for ((_, entry) in due) {
                    tasks.removeAll { it.second.first == entry.first }
                    entry.second()
                }
            }
        }
    }

    private fun setUp(source: FakeSource = FakeSource(), max: Int = 256): FsWatcher {
        root = tmp.newFolder("sdcard")
        File(root, "A").mkdir()
        File(root, "B").mkdir()
        File(root, "Android/data").mkdirs()
        File(root, ".hidden").mkdir()
        paths = FsPaths(root)
        this.source = source
        timers = ManualTimers()
        sent.clear()
        return FsWatcher(paths, source, { sent += it }, timers, maxWatches = max)
    }

    private fun changes(): List<List<String>> = sent
        .filter { it["t"] == "fs.changes" }
        .map { message ->
            @Suppress("UNCHECKED_CAST")
            (message["paths"] as List<String>)
        }

    @Test
    fun nothingWasWatchedBeforeTheFirstRequest() {
        watcher = setUp()
        assertEquals(0, source.handles.size)
        assertEquals(0, sent.size)
        assertEquals(0 to 0, watcher.counts())
    }

    @Test
    fun watchesOnlyTheRequestedFolders() {
        watcher = setUp()
        watcher.watch(listOf("A"))
        assertEquals(listOf("A"), source.handles.map { it.dir.name })
        source.emit("A", "one.txt")
        source.emit("B", "two.txt")
        timers.advance(250)
        assertEquals(listOf(listOf("A")), changes())
        watcher.close()
    }

    @Test
    fun unwatchStopsTheWatchAndSessionEndClosesTheRest() {
        watcher = setUp()
        watcher.watch(listOf("A", "B"))
        val a = source.handles.first()
        watcher.unwatch(listOf("A"))
        assertTrue(a.closed)
        source.emit("A", "one.txt")
        timers.advance(250)
        assertEquals(0, changes().size)
        val b = source.handles.last()
        watcher.close()
        assertTrue(b.closed)
        assertEquals(0 to 0, watcher.counts())
        source.emit("B", "two.txt")
        timers.advance(1_000)
        assertEquals(0, changes().size)
    }

    @Test
    fun coalescesABurstIntoOneMessagePerWindow() {
        watcher = setUp()
        watcher.watch(listOf("A"))
        repeat(20) { source.emit("A", "f$it.txt") }
        timers.advance(250)
        assertEquals(1, changes().size)
        assertEquals(1, changes()[0].size)
        // A second burst inside the same 250 ms window waits for it.
        source.emit("A", "again.txt")
        timers.advance(100)
        assertEquals(1, changes().size)
        timers.advance(150)
        assertEquals(2, changes().size)
        watcher.close()
    }

    @Test
    fun ourOwnStagingTempNeverSignals() {
        watcher = setUp()
        watcher.watch(listOf("A"))
        source.emit("A", ".contigua-1234.part")
        timers.advance(500)
        assertEquals(0, changes().size)
        source.emit("A", "real.txt")
        timers.advance(250)
        assertEquals(1, changes().size)
        watcher.close()
    }

    @Test
    fun capFallsBackToTheGenerationPoll() {
        watcher = setUp(FakeSource(generation = 7), max = 1)
        watcher.watch(listOf("A"))
        watcher.watch(listOf("B"))
        assertEquals(1, source.handles.size)
        assertEquals(2 to 1, watcher.counts())
        // Nothing on the first poll: it only learns the baseline.
        timers.advance(5_000)
        assertEquals(0, changes().size)
        source.generation = 8
        timers.advance(5_000)
        assertEquals(1, changes().size)
        assertEquals(setOf("A", "B"), changes()[0].toSet())
        watcher.close()
    }

    @Test
    fun aFailedWatchIsCoveredByTheGenerationPoll() {
        val fake = FakeSource(generation = 1)
        watcher = setUp(fake)
        fake.fail = true
        watcher.watch(listOf("A"))
        assertEquals(0, source.handles.size)
        fake.generation = 2
        timers.advance(5_000)
        fake.generation = 3
        timers.advance(5_000)
        assertEquals(listOf(listOf("A")), changes())
        watcher.close()
    }

    @Test
    fun androidAndHiddenFoldersAreRefused() {
        watcher = setUp()
        for (path in listOf("Android", "Android/data", ".hidden", "../x")) {
            try {
                watcher.watch(listOf("A", path))
                throw AssertionError("$path should be refused")
            } catch (e: FsFailure) {
                assertEquals("fs_denied", e.code)
            }
        }
        // The refused batch changed nothing.
        assertEquals(0 to 0, watcher.counts())
        assertEquals(0, source.handles.size)
        watcher.close()
    }

    @Test
    fun aFileIsNotAFolder() {
        watcher = setUp()
        File(root, "A/file.txt").writeText("x")
        try {
            watcher.watch(listOf("A/file.txt"))
            throw AssertionError("a file is not watchable")
        } catch (e: FsFailure) {
            assertEquals("fs_not_a_dir", e.code)
        }
        assertEquals(0, source.handles.size)
        watcher.close()
    }

    @Test
    fun watchingTwiceIsIdempotent() {
        watcher = setUp()
        watcher.watch(listOf("A"))
        watcher.watch(listOf("A"))
        assertEquals(1, source.handles.size)
        assertEquals(1 to 1, watcher.counts())
        watcher.close()
    }

    // MARK: the folder poll (S5 round 2: inotify is silent on the FUSE mount)

    /** An inotify source that never fires: the emulator's behaviour on /sdcard. */
    @Test
    fun aSilentWatchSourceIsCoveredByTheFolderPoll() {
        watcher = setUp()
        File(root, "A/one.txt").writeText("1")
        watcher.watch(listOf("A"))
        // The first look is the baseline, not a change.
        timers.advance(FsWatcher.FOLDER_POLL_MS)
        assertEquals(0, changes().size)
        File(root, "A/two.txt").writeText("2")
        timers.advance(FsWatcher.FOLDER_POLL_MS)
        assertEquals(listOf(listOf("A")), changes())
        // An in-place edit moves a size, and a delete removes a name.
        File(root, "A/two.txt").writeText("more bytes")
        timers.advance(FsWatcher.FOLDER_POLL_MS)
        assertEquals(2, changes().size)
        File(root, "A/two.txt").delete()
        timers.advance(FsWatcher.FOLDER_POLL_MS)
        assertEquals(3, changes().size)
        watcher.close()
    }

    /** The baseline is the folder at watch time, so the first period counts too. */
    @Test
    fun aChangeBeforeTheFirstPollIsReported() {
        watcher = setUp()
        File(root, "A/one.txt").writeText("1")
        watcher.watch(listOf("A"))
        File(root, "A/two.txt").writeText("2")
        timers.advance(FsWatcher.FOLDER_POLL_MS)
        assertEquals(listOf(listOf("A")), changes())
        watcher.close()
    }

    @Test
    fun theFolderPollLooksOnlyAtTheWatchedFolders() {
        watcher = setUp()
        watcher.watch(listOf("A"))
        timers.advance(FsWatcher.FOLDER_POLL_MS)
        File(root, "B/unwatched.txt").writeText("x")
        File(root, "A/watched.txt").writeText("x")
        timers.advance(FsWatcher.FOLDER_POLL_MS)
        assertEquals(listOf(listOf("A")), changes())
        watcher.close()
    }

    @Test
    fun oneChangeSeenByTheWatchAndThePollIsOneMessage() {
        watcher = setUp()
        watcher.watch(listOf("A"))
        timers.advance(FsWatcher.FOLDER_POLL_MS)
        // inotify fires first (the fast path)…
        File(root, "A/one.txt").writeText("1")
        source.emit("A", "one.txt")
        timers.advance(FsWatcher.FLUSH_MS)
        assertEquals(1, changes().size)
        // …and the poll that looks afterwards must not report it again.
        timers.advance(FsWatcher.FOLDER_POLL_MS)
        assertEquals(1, changes().size)
        watcher.close()
    }

    @Test
    fun anIdleWatcherSchedulesNoPollAtAll() {
        watcher = setUp()
        assertEquals(0, timers.pending())
        timers.advance(10 * FsWatcher.FOLDER_POLL_MS)
        assertEquals(0, timers.pending())
        assertEquals(0, changes().size)
        assertEquals(0, source.handles.size)
    }

    @Test
    fun unwatchStopsTheFolderPoll() {
        watcher = setUp()
        watcher.watch(listOf("A"))
        timers.advance(FsWatcher.FOLDER_POLL_MS)
        assertEquals(1, timers.pending())
        watcher.unwatch(listOf("A"))
        assertEquals(0, timers.pending())
        File(root, "A/after.txt").writeText("x")
        timers.advance(10 * FsWatcher.FOLDER_POLL_MS)
        assertEquals(0, changes().size)
        watcher.close()
    }

    @Test
    fun sessionEndStopsTheFolderPoll() {
        watcher = setUp()
        watcher.watch(listOf("A"))
        watcher.close()
        assertEquals(0, timers.pending())
        File(root, "A/after.txt").writeText("x")
        timers.advance(10 * FsWatcher.FOLDER_POLL_MS)
        assertEquals(0, changes().size)
    }
}
