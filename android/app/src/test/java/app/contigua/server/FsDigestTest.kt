package app.contigua.server

import app.contigua.proto.Crypto
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.file.Files
import java.nio.file.attribute.BasicFileAttributes
import java.security.MessageDigest

/**
 * FILES-35's digest (docs/PROTOCOL.md "Phone files"): the first 16 bytes of
 * SHA-256 over the folder's visible entries in name-byte order, each written
 * `name \0 ino \0 size \0 mtime \n`. The test computes the same bytes itself,
 * so the phone's hash has an independent witness; a last listing page carries
 * it, a file answers `fs_not_found`, and a transient entry changes nothing.
 */
class FsDigestTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private lateinit var root: File

    private fun view(): FsView {
        root = tmp.newFolder("sdcard")
        return FsView(FsPaths(root))
    }

    private fun code(block: () -> Unit): String = try {
        block()
        fail("expected a failure")
        ""
    } catch (e: FsFailure) {
        e.code
    }

    @Test
    fun theDigestMatchesItsDocumentedBytesAndIsStableAcrossInstances() {
        val view = view()
        val folder = File(root, "DCIM")
        folder.mkdirs()
        File(folder, "b.jpg").writeText("bb")
        File(folder, "a.jpg").writeText("a")
        File(folder, "Z.txt").writeText("zzz")
        File(folder, ".trashed-1").writeText("gone")
        File(folder, ".pending-2").writeText("going")
        val expected = independentlyComputedDigest(folder)
        assertEquals(expected, view.digest("DCIM"))
        assertEquals(expected, view.digest("DCIM"))
        val second = FsView(FsPaths(root))
        assertEquals(expected, second.digest("DCIM"))
        assertEquals(32, expected.length)
    }

    @Test
    fun theDigestMovesOnAnAddADeleteARenameAndAnMtimeChange() {
        val view = view()
        val folder = File(root, "DCIM")
        folder.mkdirs()
        val one = File(folder, "one.jpg").also { it.writeText("1") }
        File(folder, "two.jpg").writeText("22")
        val first = view.digest("DCIM")

        File(folder, "three.jpg").writeText("333")
        val added = view.digest("DCIM")
        assertNotEquals(first, added)

        one.delete()
        val deleted = view.digest("DCIM")
        assertNotEquals(added, deleted)

        assertTrue(File(folder, "two.jpg").renameTo(File(folder, "renamed.jpg")))
        val renamed = view.digest("DCIM")
        assertNotEquals(deleted, renamed)

        assertTrue(File(folder, "three.jpg").setLastModified(1_234_000))
        val touched = view.digest("DCIM")
        assertNotEquals(renamed, touched)
        assertEquals(touched, view.digest("DCIM"))
    }

    @Test
    fun theDigestIgnoresTransientEntriesAtAnyDepth() {
        val view = view()
        File(root, "DCIM/Camera").mkdirs()
        File(root, "DCIM/Camera/keep.jpg").writeText("jpg")
        // Depth 2 first: writing these moves Camera's own mtime, which is part
        // of DCIM's digest; after that DCIM's entries must stand still.
        File(root, "DCIM/Camera/.trashed-300").writeText("x")
        File(root, "DCIM/Camera/.pending-400").writeText("x")
        val camera = view.digest("DCIM/Camera")
        val dcim = view.digest("DCIM")
        File(root, "DCIM/.trashed-100").writeText("x")
        File(root, "DCIM/.pending-200").writeText("x")
        assertEquals(dcim, view.digest("DCIM"))
        assertEquals(camera, view.digest("DCIM/Camera"))
        assertEquals(independentlyComputedDigest(File(root, "DCIM")), view.digest("DCIM"))
        assertEquals(independentlyComputedDigest(File(root, "DCIM/Camera")),
                     view.digest("DCIM/Camera"))
    }

    @Test
    fun aDigestOfAFileIsNotFound() {
        val view = view()
        File(root, "a.txt").writeText("x")
        assertEquals("fs_not_found", code { view.digest("a.txt") })
        assertEquals("fs_not_found", code { view.digest("nope") })
    }

    @Test
    fun theLastPageCarriesTheFolderDigest() {
        root = tmp.newFolder("sdcard-digest-pages")
        val view = FsView(FsPaths(root), maxPageItems = 1)
        File(root, "F").mkdirs()
        File(root, "F/a.txt").writeText("a")
        File(root, "F/b.txt").writeText("b")
        val first = view.list("F", null)
        assertEquals("a.txt", first.items.single().name)
        assertNull(first.digest)
        assertNotEquals(null, first.next)
        val last = view.list("F", first.next)
        assertEquals("b.txt", last.items.single().name)
        assertNull(last.next)
        assertEquals(view.digest("F"), last.digest)
    }

    /** The digest as docs/PROTOCOL.md defines it, computed without FsView. */
    private fun independentlyComputedDigest(dir: File): String {
        val names = dir.listFiles()
            ?.filter {
                !it.name.startsWith(".trashed-") && !it.name.startsWith(".pending-") &&
                    !(it.name.startsWith(".contigua-") && it.name.endsWith(".part"))
            }
            ?.sortedWith { a, b -> bytesCompare(a.name, b.name) }
            ?: error("no directory")
        val hash = MessageDigest.getInstance("SHA-256")
        for (child in names) {
            val attrs = Files.readAttributes(child.toPath(), BasicFileAttributes::class.java)
            val ino = Files.getAttribute(child.toPath(), "unix:ino") as Number
            val size = if (attrs.isDirectory) 0L else attrs.size()
            val mtime = attrs.lastModifiedTime().toMillis()
            hash.update(child.name.toByteArray(Charsets.UTF_8))
            hash.update(0.toByte())
            hash.update(ino.toLong().toString().toByteArray(Charsets.US_ASCII))
            hash.update(0.toByte())
            hash.update(size.toString().toByteArray(Charsets.US_ASCII))
            hash.update(0.toByte())
            hash.update(mtime.toString().toByteArray(Charsets.US_ASCII))
            hash.update(10.toByte())
        }
        return Crypto.toHex(hash.digest()).substring(0, 32)
    }

    private fun bytesCompare(a: String, b: String): Int {
        val left = a.toByteArray(Charsets.UTF_8)
        val right = b.toByteArray(Charsets.UTF_8)
        for (index in 0 until minOf(left.size, right.size)) {
            val diff = (left[index].toInt() and 0xFF) - (right[index].toInt() and 0xFF)
            if (diff != 0) return diff
        }
        return left.size - right.size
    }
}
