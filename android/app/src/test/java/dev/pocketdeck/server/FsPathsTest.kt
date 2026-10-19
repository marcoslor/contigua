package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.file.Files

/**
 * The path rules of docs/PROTOCOL.md "Phone files" / docs/design/files.md §4:
 * relative only, no `.`/`..`, no hidden or `Android` entries, and a symlink
 * that leaves the root is refused rather than followed. A temporary folder
 * stands in for /storage/emulated/0, the way DropReceiverTest stands in for
 * /sdcard/Download.
 */
class FsPathsTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private lateinit var outside: File
    private lateinit var paths: FsPaths

    private fun setup(): FsPaths {
        val root = tmp.newFolder("sdcard")
        File(root, "a.txt").writeText("hello")
        File(root, "dir/sub").mkdirs()
        File(root, "dir/sub/b.txt").writeText("b")
        File(root, "Android/data/x").mkdirs()
        File(root, ".hidden").writeText("h")
        File(root, "visible").mkdirs()
        outside = tmp.newFolder("outside")
        File(outside, "secret.txt").writeText("s")
        paths = FsPaths(root)
        return paths
    }

    private fun denied(path: String?) {
        try {
            paths.resolve(path)
            fail("expected fs_denied for '$path'")
        } catch (e: FsFailure) {
            assertEquals("fs_denied", e.code)
        }
    }

    @Test
    fun rootIsTheEmptyPath() {
        val paths = setup()
        val root = paths.resolve("")
        assertEquals(paths.rootPath, root.path)
        assertEquals("", paths.item(root).name)
    }

    @Test
    fun relativePathsResolveUnderTheRoot() {
        val paths = setup()
        assertEquals(File(paths.rootPath, "a.txt").canonicalPath, paths.resolve("a.txt").path)
        assertEquals(File(paths.rootPath, "dir/sub/b.txt").canonicalPath,
            paths.resolve("dir/sub/b.txt").path)
    }

    @Test
    fun absolutePathsAreDenied() {
        val paths = setup()
        denied("/sdcard/a.txt")
        denied("/")
    }

    @Test
    fun dotAndParentComponentsAreDenied() {
        val paths = setup()
        denied(".")
        denied("..")
        denied("../outside")
        denied("dir/../a.txt")
        denied("./a.txt")
        denied("dir/./sub")
    }

    @Test
    fun emptyComponentsAndTrailingSlashAreDenied() {
        val paths = setup()
        denied("dir//sub")
        denied("dir/")
        denied("a.txt/")
    }

    @Test
    fun backslashAndNulAreDenied() {
        val paths = setup()
        denied("dir\\sub")
        denied("a\u0000b")
    }

    @Test
    fun longPathsAreDenied() {
        val paths = setup()
        denied("n".repeat(FsPaths.MAX_PATH_BYTES + 1))
        assertEquals(
            File(paths.rootPath, "n".repeat(200)).canonicalPath,
            paths.resolve("n".repeat(200)).path,
        )
    }

    @Test
    fun tooManyComponentsAreDenied() {
        val paths = setup()
        val atCap = List(FsPaths.MAX_COMPONENTS) { "d" }.joinToString("/")
        paths.resolve(atCap)
        denied(List(FsPaths.MAX_COMPONENTS + 1) { "d" }.joinToString("/"))
    }

    @Test
    fun androidIsDeniedAtEveryDepth() {
        val paths = setup()
        denied("Android")
        denied("Android/data")
        denied("Android/data/x")
        denied("Android/obb")
    }

    @Test
    fun hiddenTopLevelEntriesAreDenied() {
        val paths = setup()
        denied(".hidden")
        denied(".git/config")
    }

    @Test
    fun aSymlinkOutOfTheRootIsRefused() {
        val root = tmp.newFolder("sdcard2")
        outside = tmp.newFolder("outside2")
        File(outside, "secret.txt").writeText("s")
        Files.createSymbolicLink(File(root, "escape").toPath(), outside.toPath())
        Files.createSymbolicLink(File(root, "escape.txt").toPath(), File(outside, "secret.txt").toPath())
        paths = FsPaths(root)
        denied("escape")
        denied("escape/secret.txt")
        denied("escape.txt")
    }

    @Test
    fun aSymlinkInsideTheRootIsAllowed() {
        val root = tmp.newFolder("sdcard3")
        File(root, "real").mkdirs()
        File(root, "real/f.txt").writeText("ok")
        Files.createSymbolicLink(File(root, "alias").toPath(), File(root, "real").toPath())
        paths = FsPaths(root)
        assertEquals(File(root, "real/f.txt").canonicalPath, paths.resolve("alias/f.txt").path)
        assertTrue(paths.item(paths.resolve("alias")).dir)
    }

    @Test
    fun etagChangesWithEveryPartOfTheVersion() {
        val base = FsPaths.etag(ino = 7, size = 100, mtimeMs = 1_700_000_000_000)
        assertEquals(32, base.length)
        assertTrue(base != FsPaths.etag(ino = 8, size = 100, mtimeMs = 1_700_000_000_000))
        assertTrue(base != FsPaths.etag(ino = 7, size = 101, mtimeMs = 1_700_000_000_000))
        assertTrue(base != FsPaths.etag(ino = 7, size = 100, mtimeMs = 1_700_000_000_001))
        assertEquals(base, FsPaths.etag(ino = 7, size = 100, mtimeMs = 1_700_000_000_000))
    }
}
