package dev.pocketdeck.server

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.security.MessageDigest
import java.util.Collections

/**
 * The `drop.*` rules (docs/design/dragdrop.md): validation, chunking, progress,
 * resume, the cap, cancel and the checksum. The receiver writes into a temporary
 * folder standing in for /sdcard/Download/PocketDeck (the folder is one var in
 * the shipped object, restored after every test).
 */
class DropReceiverTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val frames = Collections.synchronizedList(mutableListOf<Map<String, Any?>>())

    /** The writer appends from its own thread, so every read takes a stable copy. */
    private fun snapshot(): List<Map<String, Any?>> = synchronized(frames) { frames.toList() }

    private data class Landed(
        val file: File,
        val mime: String,
        val target: String?,
        val index: Int,
        val count: Int,
    )

    private val landed = Collections.synchronizedList(mutableListOf<Landed>())

    private val landing = DropReceiver.Landing { file, mime, target, index, count ->
        landed += Landed(file, mime, target, index, count)
    }

    @Before
    fun pointDirAtTmp() {
        DropPolicy.DIRECTORY = tmp.root.absolutePath
        frames.clear()
        landed.clear()
    }

    @After
    fun restoreDir() {
        DropPolicy.DIRECTORY = "/sdcard/Download/PocketDeck"
    }

    private fun receiver(stall: Long = 60_000) =
        DropReceiver(landing, { frames += it }, stallTimeoutMs = stall)

    private fun sha(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun generated(size: Int): ByteArray = ByteArray(size) { (it % 251).toByte() }

    private fun start(name: String, size: Long, resume: Long = 0) = mapOf(
        "t" to "drop.start", "id" to 7L, "name" to name, "mime" to "text/plain",
        "size" to size, "sha256" to sha(generated(size.toInt())), "resume" to resume,
    )

    private fun startWith(name: String, bytes: ByteArray, resume: Long = 0,
                          target: String? = null, index: Int = 1, count: Int = 1) =
        mapOf(
            "t" to "drop.start", "id" to 7L, "name" to name, "mime" to "text/plain",
            "size" to bytes.size.toLong(), "sha256" to sha(bytes), "resume" to resume,
            "index" to index, "count" to count,
        ) + (if (target == null) emptyMap() else mapOf("target" to target))

    /** Polls until [count] progress frames have landed (the writer runs on its own thread). */
    private fun awaitProgress(count: Int = 1): List<Map<String, Any?>> {
        repeat(200) {
            val found = snapshot().filter { it["t"] == "drop.progress" }
            if (found.size >= count) return found
            Thread.sleep(20)
        }
        throw AssertionError("no drop.progress arrived")
    }

    /** Polls until a `drop.result` shows up (the writer runs on its own thread). */
    private fun awaitResult(): Map<String, Any?> {
        repeat(200) {
            snapshot().lastOrNull { it["t"] == "drop.result" }?.let { return it }
            Thread.sleep(20)
        }
        throw AssertionError("no drop.result arrived")
    }

    @Test
    fun chunksAssembleWithProgressAndResult() {
        val bytes = generated(12)
        val receiver = receiver()
        receiver.begin(startWith("report.pdf", bytes))
        receiver.data(7, bytes.copyOfRange(0, 5))
        receiver.data(7, bytes.copyOfRange(5, 12))
        val result = awaitResult()
        assertEquals(true, result["ok"])
        assertEquals(tmp.root.resolve("report.pdf").path, result["path"])
        assertTrue(result.containsKey("code").not())
        val progress = snapshot().filter { it["t"] == "drop.progress" }.map { it["bytes"] as Long }
        assertEquals(0L, progress.first())
        assertEquals(12L, progress.last())
    }

    @Test
    fun rejectsJunkBeforeAnythingIsWritten() {
        val receiver = receiver()
        receiver.begin(mapOf("t" to "drop.start"))
        assertEquals("bad_request", awaitResult()["code"])
        receiver.begin(start("a.pdf", 8).plus("sha256" to "nothex"))
        assertEquals("bad_request", awaitResult()["code"])
        receiver.begin(start("a.pdf", DropPolicy.MAX_FILE_BYTES + 1))
        assertEquals("too_large", awaitResult()["code"])
        assertEquals(0, tmp.root.listFiles().orEmpty().size)
    }

    @Test
    fun busyWhileAnotherDropRuns() {
        val receiver = receiver()
        receiver.begin(start("first.pdf", 8))
        receiver.begin(mapOf("t" to "drop.start", "id" to 9L, "name" to "second.pdf",
                             "mime" to "text/plain", "size" to 8L, "sha256" to sha(generated(8))))
        val busy = awaitResult()
        assertEquals("busy", busy["code"])
        assertEquals(9L, busy["id"])
    }

    @Test
    fun cancelDeletesTheTemp() {
        val receiver = receiver()
        receiver.begin(start("a.pdf", 40))
        receiver.data(7, generated(10))
        receiver.cancel(7)
        assertEquals("cancelled", awaitResult()["code"])
        assertTrue(tmp.root.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun checksumMismatchDeletesTheFile() {
        val receiver = receiver()
        receiver.begin(start("a.pdf", 8))
        receiver.data(7, ByteArray(8) { 0x66 })
        assertEquals("checksum", awaitResult()["code"])
        assertTrue(tmp.root.listFiles().orEmpty().isEmpty())
    }

    /** A user cancel mid-run, then a resumable stall: the temp is the resume. */
    @Test
    fun stalledStreamKeepsTheTemp() {
        val receiver = receiver(stall = 150)
        receiver.begin(start("a.pdf", 8))
        assertEquals("failed", awaitResult()["code"])
        assertTrue(tmp.root.listFiles().orEmpty().any { it.name.startsWith(".part-") })
    }

    @Test
    fun resumePrefersTheTempAndSkipsThePrefix() {
        val full = generated(12)
        val first = receiver(stall = 150)
        first.begin(startWith("tail.pdf", full))
        first.data(7, full.copyOfRange(0, 8))
        assertEquals("failed", awaitResult()["code"])
        val temp = tmp.root.listFiles().orEmpty().single { it.name.startsWith(".part-") }
        assertEquals(8L, temp.length())
        assertTrue(full.copyOfRange(0, 8).contentEquals(temp.readBytes()))

        frames.clear()
        val second = receiver()
        second.begin(startWith("tail.pdf", full, resume = temp.length()))
        second.data(7, full.copyOfRange(8, 12))
        val result = awaitResult()
        assertEquals(true, result["ok"])
        assertEquals(listOf(8L, 12L), snapshot().filter { it["t"] == "drop.progress" }
            .map { it["bytes"] as Long }.distinct().sorted())
        assertTrue(full.contentEquals(tmp.root.resolve("tail.pdf").readBytes()))
    }

    /**
     * The Mac's resume offset is a hint from the last progress frame; the temp
     * can be longer (progress is throttled). The phone announces the temp's
     * length and expects exactly the bytes after it, as the Mac seeks there.
     */
    @Test
    fun resumePastTheHintAnnouncesAndTakesOnlyTheTempsTail() {
        val full = generated(12)
        val first = receiver(stall = 150)
        first.begin(startWith("tail.pdf", full))
        first.data(7, full.copyOfRange(0, 8))
        assertEquals("failed", awaitResult()["code"])

        frames.clear()
        // The Mac asks for 6, but its lost progress frame means the temp is at 8.
        val second = receiver(stall = 300)
        second.begin(startWith("tail.pdf", full, resume = 6))
        val progress = awaitProgress()
        assertEquals(8L, progress.first()["bytes"])
        second.data(7, full.copyOfRange(8, 12))
        val result = awaitResult()
        assertEquals(true, result["ok"])
        assertTrue(full.contentEquals(tmp.root.resolve("tail.pdf").readBytes()))
    }

    /** `resume` of a file no temp backs: progress 0 and the Mac streams from zero. */
    @Test
    fun anUnbackedResumeRestartsFromZero() {
        val receiver = receiver()
        val other = ByteArray(6) { (7 * it).toByte() }
        receiver.begin(startWith("c.pdf", other, resume = 100))
        assertEquals(0L, awaitProgress().first()["bytes"])
        receiver.data(7, other)
        val result = awaitResult()
        assertEquals(true, result["ok"])
        assertTrue(other.contentEquals(tmp.root.resolve("c.pdf").readBytes()))
    }

    @Test
    fun theTargetAndBatchFieldsReachTheLanding() {
        val files = listOf("one.pdf", "two.pdf", "three.pdf")
        for ((position, name) in files.withIndex()) {
            val bytes = generated(6)
            val receiver = DropReceiver(landing, { frames += it })
            receiver.begin(startWith(name, bytes, target = "com.example.app",
                                     index = position + 1, count = files.size))
            receiver.data(7, bytes)
            assertEquals(true, awaitResult()["ok"])
            frames.clear()
        }
        assertEquals(listOf(1, 2, 3), landed.map { it.index })
        assertTrue(landed.all { it.count == 3 && it.target == "com.example.app" })
        assertEquals(files, landed.map { it.file.name })
    }

    /** The batch is shared once, after the third file lands and not before. */
    @Test
    fun onlyTheLastFileOfABatchTriggersTheShare() {
        val shared = mutableListOf<List<File>>()
        val batch = ShareBatch { files, _ -> shared += files.map { it.first } }
        val batchLanding = DropReceiver.Landing { file, mime, target, index, count ->
            batch.landed(file, mime, target, index, count)
        }
        for (position in 1..3) {
            val bytes = generated(4)
            val receiver = DropReceiver(batchLanding, { frames += it })
            receiver.begin(startWith("file-$position.pdf", bytes, target = "com.example.app",
                                     index = position, count = 3))
            receiver.data(7, bytes)
            assertEquals(true, awaitResult()["ok"])
            frames.clear()
            assertEquals(if (position < 3) 0 else 1, shared.size)
        }
        assertEquals(listOf("file-1.pdf", "file-2.pdf", "file-3.pdf"),
            shared.single().map { it.name })
    }

    @Test
    fun collisionNumberingMirrorsTheShareInReceiver() {
        tmp.newFile("report.pdf")
        val bytes = generated(4)
        val receiver = receiver()
        receiver.begin(startWith("report.pdf", bytes))
        receiver.data(7, bytes)
        assertEquals(tmp.root.resolve("report 2.pdf").path, awaitResult()["path"])
    }

    @Test
    fun theNameRulesMatchTheShareInReceiver() {
        assertEquals("Report.jpg", DropPolicy.sanitize("a/b/Report..jpg", "image/jpeg").toString())
        assertEquals("File", DropPolicy.sanitize("..", "text/plain").stem)
        assertEquals("File.pdf", DropPolicy.sanitize("写真.pdf", "application/pdf").toString())
        assertEquals("notes.pdf", DropPolicy.sanitize("notes", "application/pdf").toString())
        assertEquals("hidden.pdf", DropPolicy.sanitize(".hidden.pdf", "application/pdf").toString())
        assertEquals("-dash.pdf", DropPolicy.sanitize("-dash.pdf", "application/pdf").toString())
        val long = DropPolicy.sanitize("N".repeat(150) + ".pdf", "application/pdf")
        assertEquals(DropPolicy.NAME_MAX_CHARS, long.toString().length)
        assertEquals("N", long.stem.first().toString())
    }
}
