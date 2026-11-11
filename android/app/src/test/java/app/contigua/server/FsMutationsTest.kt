package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.file.FileAlreadyExistsException
import java.util.concurrent.CopyOnWriteArrayList

/**
 * `fs.move`, `fs.delete`, `fs.mkdir` and `fs.setAttrs` (docs/PROTOCOL.md "Phone
 * files"): the media-aware rename and its fallback, the recursive-delete rule,
 * `fs_exists`, and the path rules. The platform records what it was asked to do.
 */
class FsMutationsTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private lateinit var paths: FsPaths
    private lateinit var platform: FakePlatform
    private lateinit var ops: FsMutations

    private class FakePlatform : FsPlatform {
        val renamed = CopyOnWriteArrayList<Pair<File, File>>()
        val plain = CopyOnWriteArrayList<Pair<File, File>>()
        val scanned = CopyOnWriteArrayList<File>()
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

        override fun setLastModified(file: File, mtimeMs: Long): Boolean =
            file.setLastModified(mtimeMs)
    }

    private fun setup(): FsPaths {
        paths = FsPaths(tmp.newFolder("sdcard"))
        platform = FakePlatform()
        ops = FsMutations(paths, platform)
        return paths
    }

    private fun code(block: () -> Unit): String = try {
        block()
        fail("expected a failure")
        ""
    } catch (e: FsFailure) {
        e.code
    }

    @Test
    fun aRenameGoesThroughTheMediaSeamAndKeepsTheBytes() {
        setup()
        val source = File(paths.rootPath, "a.txt").also { it.writeText("hello") }
        val item = ops.move("a.txt", "b.txt", null)
        assertEquals("b.txt", item.name)
        assertEquals(1, platform.renamed.size)
        assertEquals(source, platform.renamed[0].first)
        assertFalse(source.exists())
        assertEquals("hello", File(paths.rootPath, "b.txt").readText())
        // The media-aware rename keeps MediaStore's rows in step by itself.
        assertEquals(0, platform.scanned.size)
        // A move never asks the seam to replace; a taken name is a refusal.
        assertEquals(listOf(false), platform.replaceFlags.toList())
    }

    @Test
    fun aFileThatAppearsAtTheRenameIsNotReplaced() {
        setup()
        val source = File(paths.rootPath, "a.txt").also { it.writeText("a") }
        val other = File(paths.rootPath, "b.txt")
        // The name lands after the move's own check and before the rename.
        platform.beforeRename = { other.writeText("the phone's copy") }
        assertEquals("fs_exists", code { ops.move("a.txt", "b.txt", null) })
        assertEquals("the phone's copy", other.readText())
        assertEquals("a", source.readText())
        assertTrue(source.exists())
        assertEquals(0, platform.scanned.size)
    }

    @Test
    fun thePlainRenameIsTheFallbackWhenTheMediaPathRefuses() {
        setup()
        platform.refuseRename = true
        File(paths.rootPath, "a.txt").writeText("x")
        ops.move("a.txt", "b.txt", null)
        assertEquals(1, platform.plain.size)
        assertTrue(File(paths.rootPath, "b.txt").exists())
        // The fallback bypassed MediaProvider: the new path is scanned and the
        // old one too, so its row does not stay behind.
        assertEquals(
            listOf(File(paths.rootPath, "b.txt"), File(paths.rootPath, "a.txt")),
            platform.scanned.toList(),
        )
    }

    @Test
    fun aMoveOntoAnExistingNameIsExists() {
        setup()
        File(paths.rootPath, "a.txt").writeText("a")
        File(paths.rootPath, "b.txt").writeText("b")
        assertEquals("fs_exists", code { ops.move("a.txt", "b.txt", null) })
        assertEquals("b", File(paths.rootPath, "b.txt").readText())
        assertTrue(platform.renamed.isEmpty())
    }

    @Test
    fun aStaleMoveEtagIsRefused() {
        setup()
        File(paths.rootPath, "a.txt").writeText("a")
        File(paths.rootPath, "a.txt").writeText("changed")
        assertEquals("fs_stale", code { ops.move("a.txt", "b.txt", "0".repeat(32)) })
        assertEquals("fs_not_found", code { ops.move("nope", "b.txt", null) })
        assertEquals("fs_denied", code { ops.move("a.txt", "Android/b.txt", null) })
        assertTrue(File(paths.rootPath, "a.txt").exists())
    }

    @Test
    fun aMoveIntoItselfIsRefused() {
        setup()
        File(paths.rootPath, "folder").mkdirs()
        assertEquals("fs_denied", code { ops.move("folder", "folder/sub", null) })
        assertTrue(File(paths.rootPath, "folder").isDirectory)
    }

    @Test
    fun aFolderMovesWithItsContents() {
        setup()
        File(paths.rootPath, "folder").mkdirs()
        File(paths.rootPath, "folder/a.txt").writeText("a")
        ops.move("folder", "renamed", null)
        assertEquals("a", File(paths.rootPath, "renamed/a.txt").readText())
        assertFalse(File(paths.rootPath, "folder").exists())
    }

    @Test
    fun aNonEmptyFolderNeedsRecursive() {
        setup()
        File(paths.rootPath, "folder").mkdirs()
        File(paths.rootPath, "folder/a.txt").writeText("a")
        assertEquals("fs_denied", code { ops.delete("folder", false) })
        assertTrue(File(paths.rootPath, "folder/a.txt").exists())
        ops.delete("folder", true)
        assertFalse(File(paths.rootPath, "folder").exists())
    }

    @Test
    fun aStaleDeleteEtagLeavesTheFileAlone() {
        setup()
        val file = File(paths.rootPath, "a.txt").also { it.writeText("a") }
        val etag = paths.item(file).etag
        // The phone's file changes after the Mac last saw it.
        file.writeText("changed on the phone")
        assertEquals("fs_stale", code { ops.delete("a.txt", false, etag) })
        assertEquals("changed on the phone", file.readText())
        // The version the Mac saw is what deletes it.
        ops.delete("a.txt", false, paths.item(file).etag)
        assertFalse(file.exists())
    }

    @Test
    fun aFolderDeleteEtagCatchesChildrenAddedInIt() {
        setup()
        val folder = File(paths.rootPath, "folder").also { it.mkdirs() }
        File(folder, "a.txt").writeText("a")
        val etag = paths.item(folder).etag
        // The ms clock in the etag needs a tick before the child changes it.
        Thread.sleep(20)
        File(folder, "b.txt").writeText("b")
        assertEquals("fs_stale", code { ops.delete("folder", true, etag) })
        assertTrue(File(folder, "b.txt").exists())
        // Deleting a folder removes what is in it at that moment, children
        // added since the listing included.
        ops.delete("folder", true, paths.item(folder).etag)
        assertFalse(folder.exists())
    }

    @Test
    fun anEmptyFolderAndAFileDeleteWithoutRecursive() {
        setup()
        File(paths.rootPath, "folder").mkdirs()
        File(paths.rootPath, "a.txt").writeText("a")
        ops.delete("folder", false)
        ops.delete("a.txt", false)
        assertFalse(File(paths.rootPath, "folder").exists())
        assertFalse(File(paths.rootPath, "a.txt").exists())
        assertEquals("fs_not_found", code { ops.delete("a.txt", false) })
        assertEquals("fs_denied", code { ops.delete("", true) })
        assertEquals("fs_denied", code { ops.delete("Android", true) })
    }

    @Test
    fun aSymlinkedFolderIsRemovedAsItselfNotFollowed() {
        setup()
        val outside = tmp.newFolder("outside")
        val kept = File(outside, "kept.txt").also { it.writeText("keep") }
        File(paths.rootPath, "folder").mkdirs()
        java.nio.file.Files.createSymbolicLink(
            File(paths.rootPath, "folder/link").toPath(), outside.toPath(),
        )
        ops.delete("folder", true)
        assertTrue(kept.exists())
        assertFalse(File(paths.rootPath, "folder").exists())
    }

    @Test
    fun mkdirCreatesOneFolderAndRefusesTheRest() {
        setup()
        val item = ops.mkdir("new")
        assertTrue(item.dir)
        assertTrue(File(paths.rootPath, "new").isDirectory)
        assertEquals("fs_exists", code { ops.mkdir("new") })
        assertEquals("fs_not_found", code { ops.mkdir("missing/child") })
        assertEquals("fs_denied", code { ops.mkdir("Android/x") })
        assertEquals("fs_denied", code { ops.mkdir(".hidden") })
        assertEquals("fs_exists", code { ops.mkdir("") })
    }

    @Test
    fun setAttrsSetsTheTimeBestEffort() {
        setup()
        val file = File(paths.rootPath, "a.txt").also { it.writeText("a") }
        val item = ops.setAttrs("a.txt", 1_600_000_000_000)
        assertTrue(item.mtime > 0)
        assertTrue(file.lastModified() > 0)
        assertEquals("fs_not_found", code { ops.setAttrs("nope", 1L) })
        assertEquals("fs_denied", code { ops.setAttrs("../x", 1L) })
    }
}
