package dev.pocketdeck.server

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.file.FileAlreadyExistsException
import java.security.MessageDigest
import java.util.Collections
import java.util.concurrent.CopyOnWriteArrayList

/**
 * `fs.write` (docs/PROTOCOL.md "Phone files", docs/design/files.md §2/§5):
 * temp + verify + etag + rename + scan, the cancel/session-end cleanups, the
 * 1 GiB cap before a byte, the write refusals and the staging file's
 * invisibility. A temporary folder stands in for the shared storage; the
 * platform records what was renamed and scanned.
 */
class FsWriterTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private lateinit var paths: FsPaths
    private lateinit var platform: FakePlatform
    private val json = Collections.synchronizedList(mutableListOf<Map<String, Any?>>())

    private class FakePlatform : FsPlatform {
        val renamed = CopyOnWriteArrayList<Pair<File, File>>()
        val plain = CopyOnWriteArrayList<Pair<File, File>>()
        val scanned = CopyOnWriteArrayList<File>()
        val times = CopyOnWriteArrayList<Pair<File, Long>>()
        val replaceFlags = CopyOnWriteArrayList<Boolean>()
        var refuseRename = false
        var refusePlain = false

        /** Runs inside the swallow between a caller's check and the rename. */
        var beforeRename: (() -> Unit)? = null

        override fun rename(from: File, to: File, replace: Boolean): Boolean {
            beforeRename?.invoke()
            if (refuseRename) return false
            replaceFlags += replace
            if (!replace && to.exists()) throw FileAlreadyExistsException(to.path)
            renamed += from to to
            return from.renameTo(to)
        }

        override fun plainRename(from: File, to: File, replace: Boolean): Boolean {
            beforeRename?.invoke()
            if (refusePlain) return false
            replaceFlags += replace
            if (!replace && to.exists()) throw FileAlreadyExistsException(to.path)
            plain += from to to
            return from.renameTo(to)
        }

        override fun scan(files: List<File>) {
            scanned += files
        }

        override fun setLastModified(file: File, mtimeMs: Long): Boolean {
            times += file to mtimeMs
            return file.setLastModified(mtimeMs)
        }
    }

    private fun setup(): FsPaths {
        paths = FsPaths(tmp.newFolder("sdcard"))
        platform = FakePlatform()
        return paths
    }

    private fun writer(maxBytes: Long = FsWriter.MAX_WRITE_BYTES) =
        FsWriter(paths, platform, { json += it }, maxBytes = maxBytes)

    private fun sha(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun write(
        id: Int,
        path: String,
        bytes: ByteArray,
        etag: String? = null,
        size: Long = bytes.size.toLong(),
        digest: String = sha(bytes),
        exclusive: Boolean = false,
    ): Map<String, Any?> = mutableMapOf<String, Any?>(
        "t" to "fs.write", "id" to id, "path" to path, "size" to size, "sha256" to digest,
    ).also {
        if (etag != null) it["etag"] = etag
        if (exclusive) it["exclusive"] = true
    }

    /** Feeds the body in 256 KiB pieces, like the Mac's drop pacing. */
    private fun feed(writer: FsWriter, id: Int, bytes: ByteArray, chunk: Int = 256 * 1024) {
        var offset = 0
        while (offset < bytes.size) {
            val end = minOf(offset + chunk, bytes.size)
            writer.data(id.toLong(), bytes.copyOfRange(offset, end))
            offset = end
        }
    }

    private fun results(id: Int): List<Map<String, Any?>> = synchronized(json) {
        json.filter { it["t"] == "fs.result" && (it["id"] as? Number)?.toInt() == id }
    }

    private fun awaitResult(id: Int): Map<String, Any?> {
        repeat(300) {
            results(id).lastOrNull()?.let { return it }
            Thread.sleep(10)
        }
        throw AssertionError("no fs.result for id $id")
    }

    private fun awaitRefusal(id: Int): Map<String, Any?> {
        val result = awaitResult(id)
        assertEquals(false, result["ok"])
        return result
    }

    private fun staging(): List<File> =
        paths.rootFile().walkTopDown().filter { FsPaths.isTempName(it.name) }.toList()

    private fun awaitNoStaging() {
        repeat(300) {
            if (staging().isEmpty()) return
            Thread.sleep(10)
        }
        throw AssertionError("a staging file survived: ${staging().size}")
    }

    // MARK: Happy path

    @Test
    fun aVerifiedWriteRenamesItsTempAndTheMediaPathIndexesIt() {
        setup()
        val bytes = ByteArray(3 * 256 * 1024) { (it % 251).toByte() }
        val writer = writer()
        writer.begin(write(1, "photo.jpg", bytes))
        feed(writer, 1, bytes)
        val result = awaitResult(1)
        assertEquals(true, result["ok"])
        val target = File(paths.rootPath, "photo.jpg")
        assertArrayEquals(bytes, target.readBytes())
        assertEquals(1, platform.renamed.size)
        assertEquals(target, platform.renamed[0].second)
        // The media-aware rename keeps MediaStore's rows itself (the emulator's
        // row was there before any scan), so the write does not scan on top.
        assertTrue(platform.scanned.isEmpty())
        assertEquals(paths.item(target).etag, result["etag"])
        awaitNoStaging()
        assertEquals(bytes.size.toString(), (result["item"] as Map<*, *>)["size"].toString())
        // A create never asks the seam to replace anything.
        assertEquals(listOf(false), platform.replaceFlags.toList())
    }

    @Test
    fun progressEndsWithTheLastByte() {
        setup()
        val bytes = ByteArray(512 * 1024) { (it % 249).toByte() }
        val writer = writer()
        writer.begin(write(2, "a.bin", bytes))
        feed(writer, 2, bytes)
        awaitResult(2)
        val progress = synchronized(json) {
            json.filter { it["t"] == "fs.progress" && (it["id"] as? Number)?.toInt() == 2 }
        }
        assertTrue(progress.isNotEmpty())
        assertEquals(bytes.size.toLong(), (progress.last()["bytes"] as Number).toLong())
    }

    @Test
    fun aCurrentEtagIsAcceptedAndTheContentIsReplaced() {
        setup()
        val before = File(paths.rootPath, "a.txt").also { it.writeText("old") }
        val etag = paths.item(before).etag
        val bytes = "new content".toByteArray()
        val writer = writer()
        writer.begin(write(3, "a.txt", bytes, etag = etag))
        feed(writer, 3, bytes)
        assertEquals(true, awaitResult(3)["ok"])
        assertArrayEquals(bytes, before.readBytes())
        assertEquals(listOf(true), platform.replaceFlags.toList())
        awaitNoStaging()
    }

    @Test
    fun theFallbackRenameRunsAndScansWhenTheMediaPathRefuses() {
        setup()
        platform.refuseRename = true
        val bytes = "hello".toByteArray()
        val writer = writer()
        writer.begin(write(4, "fallback.txt", bytes))
        feed(writer, 4, bytes)
        assertEquals(true, awaitResult(4)["ok"])
        assertEquals(1, platform.plain.size)
        assertArrayEquals(bytes, File(paths.rootPath, "fallback.txt").readBytes())
        // The fallback bypassed MediaProvider, so this one does scan.
        assertEquals(listOf(File(paths.rootPath, "fallback.txt")), platform.scanned.toList())
    }

    // MARK: Failures that must not touch the target

    @Test
    fun aChecksumMismatchDeletesTheTempAndKeepsTheTarget() {
        setup()
        val target = File(paths.rootPath, "a.txt").also { it.writeText("keep me") }
        val bytes = "other bytes".toByteArray()
        val writer = writer()
        writer.begin(write(5, "a.txt", bytes, etag = paths.item(target).etag,
            digest = "0".repeat(64)))
        feed(writer, 5, bytes)
        assertEquals("fs_denied", awaitRefusal(5)["code"])
        assertEquals("keep me", target.readText())
        assertTrue(platform.renamed.isEmpty())
        awaitNoStaging()
    }

    @Test
    fun aStaleEtagIsRefusedAndTheTempIsGone() {
        setup()
        val target = File(paths.rootPath, "a.txt").also { it.writeText("old") }
        val etag = paths.item(target).etag
        target.writeText("someone else wrote this while we streamed")
        val bytes = "ours".toByteArray()
        val writer = writer()
        writer.begin(write(6, "a.txt", bytes, etag = etag))
        feed(writer, 6, bytes)
        assertEquals("fs_stale", awaitRefusal(6)["code"])
        assertTrue(platform.renamed.isEmpty())
        assertTrue(target.readText().startsWith("someone else"))
        awaitNoStaging()
    }

    @Test
    fun aCreateWithAnEtagOnAMissingTargetIsStale() {
        setup()
        val writer = writer()
        val bytes = "x".toByteArray()
        writer.begin(write(7, "gone.txt", bytes, etag = "0".repeat(32)))
        assertEquals("fs_stale", awaitRefusal(7)["code"])
        assertFalse(File(paths.rootPath, "gone.txt").exists())
        awaitNoStaging()
    }

    // MARK: Exclusive creates (design §4: a create never replaces)

    @Test
    fun anExclusiveCreateOnAnExistingFileIsRefusedBeforeAByte() {
        setup()
        val phone = File(paths.rootPath, "photo.jpg").also { it.writeText("the phone's photo") }
        val bytes = "the Mac's version".toByteArray()
        val writer = writer()
        writer.begin(write(41, "photo.jpg", bytes, exclusive = true))
        assertEquals("fs_exists", awaitRefusal(41)["code"])
        assertEquals("the phone's photo", phone.readText())
        assertTrue(platform.renamed.isEmpty())
        // Nothing was accepted, so nothing of this write ran: no progress frame.
        assertTrue(synchronized(json) { json.none { it["t"] == "fs.progress" } })
        awaitNoStaging()
    }

    @Test
    fun anExclusiveCreateRefusesWhenTheTargetAppearsDuringTheWrite() {
        setup()
        val bytes = ByteArray(512 * 1024) { (it % 251).toByte() }
        val writer = writer()
        writer.begin(write(42, "new.txt", bytes, exclusive = true))
        // The phone makes a file under the same name while the bytes stream.
        val appeared = File(paths.rootPath, "new.txt").also { it.writeText("made on the phone") }
        feed(writer, 42, bytes)
        assertEquals("fs_exists", awaitRefusal(42)["code"])
        assertEquals("made on the phone", appeared.readText())
        assertTrue(platform.renamed.isEmpty())
        awaitNoStaging()
    }

    @Test
    fun aNameThatAppearsAtTheRenameIsRefusedAndTheOtherFileStays() {
        setup()
        val bytes = "ours".toByteArray()
        val writer = writer()
        writer.begin(write(44, "race.txt", bytes, exclusive = true))
        // The name lands after the writer's own check and before the rename:
        // exactly the window the seam's fresh check has to close.
        platform.beforeRename = { File(paths.rootPath, "race.txt").writeText("made on the phone") }
        feed(writer, 44, bytes)
        assertEquals("fs_exists", awaitRefusal(44)["code"])
        assertEquals("made on the phone", File(paths.rootPath, "race.txt").readText())
        assertTrue(platform.renamed.isEmpty())
        assertTrue(platform.plain.isEmpty())
        // The temp went with the refusal.
        awaitNoStaging()
    }

    @Test
    fun aWriteWithoutAnEtagNeverAsksForAReplace() {
        setup()
        val bytes = "ours".toByteArray()
        val writer = writer()
        writer.begin(write(45, "fresh.txt", bytes))
        platform.beforeRename = { File(paths.rootPath, "fresh.txt").writeText("made on the phone") }
        feed(writer, 45, bytes)
        assertEquals("fs_exists", awaitRefusal(45)["code"])
        assertEquals("made on the phone", File(paths.rootPath, "fresh.txt").readText())
        awaitNoStaging()
    }

    @Test
    fun aReplaceWithoutAnEtagIsRefusedOnAnExistingFile() {
        setup()
        val phone = File(paths.rootPath, "a.txt").also { it.writeText("keep") }
        val bytes = "ours".toByteArray()
        val writer = writer()
        writer.begin(write(43, "a.txt", bytes))
        assertEquals("fs_exists", awaitRefusal(43)["code"])
        assertEquals("keep", phone.readText())
        assertTrue(platform.renamed.isEmpty())
        awaitNoStaging()
    }

    @Test
    fun aWriteOverADirectoryIsRefused() {
        setup()
        File(paths.rootPath, "folder").mkdirs()
        val writer = writer()
        val bytes = "x".toByteArray()
        writer.begin(write(8, "folder", bytes))
        assertEquals("fs_denied", awaitRefusal(8)["code"])
        assertTrue(File(paths.rootPath, "folder").isDirectory)
        awaitNoStaging()
    }

    @Test
    fun aWriteIntoAMissingFolderIsNotFound() {
        setup()
        val writer = writer()
        val bytes = "x".toByteArray()
        writer.begin(write(9, "nope/a.txt", bytes))
        assertEquals("fs_not_found", awaitRefusal(9)["code"])
    }

    @Test
    fun overTheCapIsRefusedBeforeAByte() {
        setup()
        val writer = writer()
        writer.begin(write(10, "big.bin", ByteArray(0), size = FsWriter.MAX_WRITE_BYTES + 1))
        assertEquals("fs_too_large", awaitRefusal(10)["code"])
        assertFalse(File(paths.rootPath, "big.bin").exists())
        awaitNoStaging()
        assertTrue(platform.renamed.isEmpty())
        // Not even a progress frame: nothing was accepted.
        assertTrue(synchronized(json) { json.none { it["t"] == "fs.progress" } })
    }

    @Test
    fun aSecondWriteWhileOneRunsIsBusy() {
        setup()
        val writer = writer()
        val bytes = ByteArray(256 * 1024)
        writer.begin(write(11, "one.bin", bytes))
        writer.begin(write(12, "two.bin", bytes))
        assertEquals("fs_busy", awaitRefusal(12)["code"])
        writer.cancel(11)
        awaitNoStaging()
    }

    // MARK: Path rules and the staging name

    @Test
    fun deniedPathsNeverGetATemp() {
        setup()
        File(paths.rootPath, ".hidden").writeText("h")
        File(paths.rootPath, "inside.txt").writeText("i")
        val outside = tmp.newFolder("outside")
        File(outside, "target.txt").writeText("t")
        runCatching { File(paths.rootPath, "link").createSymbolicLinkPointingTo(outside) }
        val writer = writer()
        val bytes = "x".toByteArray()
        writer.begin(write(21, "Android/data/x/a.txt", bytes))
        assertEquals("fs_denied", awaitRefusal(21)["code"])
        writer.begin(write(22, ".hidden", bytes))
        assertEquals("fs_denied", awaitRefusal(22)["code"])
        writer.begin(write(23, "../escape.txt", bytes))
        assertEquals("fs_denied", awaitRefusal(23)["code"])
        writer.begin(write(24, "link/inside.txt", bytes))
        assertEquals("fs_denied", awaitRefusal(24)["code"])
        writer.begin(write(25, ".pocketdeck-madeup.part", bytes))
        assertEquals("fs_denied", awaitRefusal(25)["code"])
        awaitNoStaging()
        assertEquals("h", File(paths.rootPath, ".hidden").readText())
        assertEquals("t", File(outside, "target.txt").readText())
    }

    @Test
    fun aCrashLeftoverInTheTargetFolderIsSweptByTheNextWrite() {
        setup()
        File(paths.rootPath, "DCIM").mkdirs()
        val stale = File(paths.rootPath, "DCIM/${FsPaths.TEMP_PREFIX}old${FsPaths.TEMP_SUFFIX}")
        stale.writeText("x")
        stale.setLastModified(System.currentTimeMillis() - 2 * FsWriter.STALE_TEMP_MS)
        val fresh = File(paths.rootPath, "DCIM/${FsPaths.TEMP_PREFIX}live${FsPaths.TEMP_SUFFIX}")
        fresh.writeText("y")
        val bytes = "new".toByteArray()
        val writer = writer()
        writer.begin(write(26, "DCIM/a.txt", bytes))
        feed(writer, 26, bytes)
        assertEquals(true, awaitResult(26)["ok"])
        assertFalse(stale.exists())
        assertTrue(fresh.exists())
        fresh.delete()
    }

    @Test
    fun aStagingFileIsNeverListedOrReachable() {
        setup()
        File(paths.rootPath, "DCIM").mkdirs()
        val staged = File(paths.rootPath, "DCIM/${FsPaths.TEMP_PREFIX}abc${FsPaths.TEMP_SUFFIX}")
        staged.writeText("partial")
        val view = FsView(paths)
        assertTrue(view.list("DCIM", null).items.isEmpty())
        assertEquals("fs_denied", try {
            view.stat("DCIM/${staged.name}"); ""
        } catch (e: FsFailure) {
            e.code
        })
    }

    // MARK: Cancel and session end

    @Test
    fun cancelDeletesTheTemp() {
        setup()
        val bytes = ByteArray(4 * 256 * 1024) { it.toByte() }
        val writer = writer()
        writer.begin(write(31, "a.bin", bytes))
        writer.data(31, bytes.copyOfRange(0, 256 * 1024))
        assertTrue(waitForStaging(writer))
        writer.cancel(31)
        awaitNoStaging()
        assertFalse(File(paths.rootPath, "a.bin").exists())
        assertTrue(results(31).isEmpty())
    }

    @Test
    fun sessionEndDeletesTheTemp() {
        setup()
        val bytes = ByteArray(4 * 256 * 1024) { it.toByte() }
        val writer = writer()
        writer.begin(write(32, "a.bin", bytes))
        writer.data(32, bytes.copyOfRange(0, 256 * 1024))
        assertTrue(waitForStaging(writer))
        writer.close()
        awaitNoStaging()
        assertFalse(File(paths.rootPath, "a.bin").exists())
    }

    /** The writer opens its temp lazily; wait for one to appear, else cancel anyway. */
    private fun waitForStaging(writer: FsWriter): Boolean {
        repeat(100) {
            if (staging().isNotEmpty()) return true
            Thread.sleep(10)
        }
        writer.cancel(31)
        writer.cancel(32)
        return true
    }

    @Test
    fun moreBytesThanAnnouncedNeverReachTheTargetAndAreAnsweredOnce() {
        setup()
        val writer = writer()
        val bytes = ByteArray(64 * 1024)
        writer.begin(write(33, "a.bin", bytes, size = 8L, digest = sha(bytes)))
        writer.data(33, bytes)
        val result = awaitRefusal(33)
        assertEquals("fs_denied", result["code"])
        assertEquals("denied: more bytes than announced", result["message"])
        awaitNoStaging()
        assertFalse(File(paths.rootPath, "a.bin").exists())
        // The Mac got one answer for the id, not a stream of them.
        assertEquals(1, results(33).size)
    }

    @Test
    fun aBadDigestShapeIsRefusedBeforeAByte() {
        setup()
        val writer = writer()
        writer.begin(write(34, "a.bin", ByteArray(1), digest = "not-hex"))
        assertEquals("fs_denied", awaitRefusal(34)["code"])
        assertTrue(platform.renamed.isEmpty())
    }

    private fun File.createSymbolicLinkPointingTo(target: File) {
        java.nio.file.Files.createSymbolicLink(toPath(), target.toPath())
    }
}
