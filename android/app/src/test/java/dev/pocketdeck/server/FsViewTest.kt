package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * List/stat and paging (docs/PROTOCOL.md "Phone files"): page size and byte
 * caps, the hidden/Android rules, the etag's metadata sensitivity and the
 * refusal codes. A temporary folder stands in for the shared storage.
 */
class FsViewTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private lateinit var root: File

    private fun view(stats: FsStats = FsStats.Default): FsView {
        root = tmp.newFolder("sdcard")
        return FsView(FsPaths(root, stats))
    }

    private fun code(block: () -> Unit): String = try {
        block()
        fail("expected a failure")
        ""
    } catch (e: FsFailure) {
        e.code
    }

    @Test
    fun listingTheRootHidesAndroidAndDotEntries() {
        val view = view()
        File(root, "DCIM").mkdirs()
        File(root, "notes.txt").writeText("0123456789")
        File(root, "Android/data/x").mkdirs()
        File(root, ".hidden").writeText("h")
        val page = view.list("", null)
        assertEquals(listOf("DCIM", "notes.txt"), page.items.map { it.name })
        assertEquals(listOf(true, false), page.items.map { it.dir })
        assertEquals(10L, page.items[1].size)
        assertNull(page.next)
    }

    @Test
    fun aFolderBelowTheRootKeepsItsDotEntries() {
        val view = view()
        File(root, "DCIM").mkdirs()
        File(root, "DCIM/.nomedia").writeText("")
        File(root, "DCIM/a.jpg").writeText("jpg")
        assertEquals(listOf(".nomedia", "a.jpg"), view.list("DCIM", null).items.map { it.name })
    }

    /**
     * FILES-35: Android's own transient entries (a move in flight, a delete
     * awaiting the Trash) are never phone files a person means, at any depth.
     */
    @Test
    fun transientEntriesAreLeftOutAtEveryDepth() {
        val view = view()
        File(root, "DCIM/Camera").mkdirs()
        File(root, "DCIM/.trashed-100").writeText("x")
        File(root, "DCIM/.pending-200").writeText("x")
        File(root, "DCIM/Camera/.trashed-300").writeText("x")
        File(root, "DCIM/Camera/.pending-400").writeText("x")
        File(root, "DCIM/Camera/keep.jpg").writeText("jpg")
        assertEquals(listOf("Camera"), view.list("DCIM", null).items.map { it.name })
        assertEquals(listOf("keep.jpg"), view.list("DCIM/Camera", null).items.map { it.name })
    }

    /**
     * FILES-35: a transient entry is not an item, so it neither fills a page
     * nor moves the cursor; the real entries still come out one page at a time.
     */
    @Test
    fun transientEntriesDoNotConsumeAPageSlotOrMoveTheCursor() {
        root = tmp.newFolder("sdcard-pages")
        val view = FsView(FsPaths(root), maxPageItems = 2)
        File(root, "F").mkdirs()
        repeat(5) { File(root, "F/f$it.txt").writeText("") }
        repeat(3) { File(root, "F/.trashed-$it").writeText("") }
        repeat(3) { File(root, "F/.pending-$it").writeText("") }

        val seen = mutableListOf<String>()
        var page: String? = null
        var pages = 0
        do {
            val result = view.list("F", page)
            assertTrue(result.items.size <= 2)
            seen += result.items.map { it.name }
            page = result.next
            pages++
            assertTrue("paging did not terminate", pages <= 3)
        } while (page != null)
        assertEquals(3, pages)
        assertEquals(listOf("f0.txt", "f1.txt", "f2.txt", "f3.txt", "f4.txt"), seen)
    }

    @Test
    fun aDirectRequestForADeniedEntryIsRefused() {
        val view = view()
        File(root, "Android/data/x").mkdirs()
        assertEquals("fs_denied", code { view.list("Android", null) })
        assertEquals("fs_denied", code { view.list("Android/data", null) })
        assertEquals("fs_denied", code { view.list(".hidden", null) })
        assertEquals("fs_denied", code { view.stat("Android") })
    }

    @Test
    fun missingFilesAndFilesAsFolders() {
        val view = view()
        File(root, "a.txt").writeText("x")
        assertEquals("fs_not_found", code { view.list("nope", null) })
        assertEquals("fs_not_a_dir", code { view.list("a.txt", null) })
        assertEquals("fs_not_found", code { view.stat("nope") })
        assertTrue(view.stat("a.txt").dir.not())
        assertTrue(view.stat("").dir)
    }

    @Test
    fun pagingCoversEveryNameExactlyOnce() {
        val view = view()
        repeat(2500) { File(root, "f%04d.txt".format(it)).writeText("") }
        val seen = mutableListOf<String>()
        var page: String? = null
        var pages = 0
        do {
            val result = view.list("", page)
            assertTrue(result.items.size <= FsView.MAX_PAGE_ITEMS)
            seen += result.items.map { it.name }
            page = result.next
            pages++
            assertTrue("paging did not terminate", pages <= 5)
        } while (page != null)
        assertEquals(3, pages)
        assertEquals(2500, seen.size)
        assertEquals(2500, seen.toSet().size)
        assertEquals(seen.sorted(), seen)
    }

    @Test
    fun aPageStopsAtTheJsonByteCap() {
        // A tiny cap stands in for 1 MiB: with 200-byte names and 1000 items
        // the item cap would otherwise always win.
        root = tmp.newFolder("sdcard-bytes")
        val view = FsView(FsPaths(root), maxPageBytes = 2_000)
        repeat(80) { File(root, "%03d".format(it) + "n".repeat(20)).writeText("") }
        val first = view.list("", null)
        assertTrue("the byte cap must split before the item cap", first.items.size < 80)
        assertNotEquals(null, first.next)
        val seen = first.items.map { it.name }.toMutableList()
        var result = first
        while (result.next != null) {
            result = view.list("", result.next)
            seen += result.items.map { it.name }
        }
        assertEquals(80, seen.size)
        assertEquals(80, seen.toSet().size)
    }

    @Test
    fun anUnknownPageStartsAtTheFirstItem() {
        val view = view()
        File(root, "a").writeText("")
        File(root, "b").writeText("")
        assertEquals(listOf("a", "b"), view.list("", "garbage").items.map { it.name })
        assertEquals(listOf("a", "b"), view.list("", "99999").items.map { it.name })
    }

    @Test
    fun theEtagFollowsSizeAndMtime() {
        // A mutable metadata source: the same name, a different version.
        var meta = FsMeta(dir = false, size = 10, mtimeMs = 1_000, ino = 3)
        val stats = FsStats { file -> if (file.name == "a.txt") meta else FsStats.Default.stat(file) }
        val view = view(stats)
        val file = File(root, "a.txt")
        file.writeText("x")
        val first = view.stat("a.txt").etag
        meta = meta.copy(size = 11)
        val grown = view.stat("a.txt").etag
        meta = meta.copy(mtimeMs = 2_000)
        val touched = view.stat("a.txt").etag
        meta = meta.copy(size = 10, mtimeMs = 1_000)
        assertEquals(first, view.stat("a.txt").etag)
        assertNotEquals(first, grown)
        assertNotEquals(grown, touched)
        assertNotEquals(first, touched)
    }

    @Test
    fun directoriesReportNoSizeAndTheirOwnFlag() {
        val view = view()
        File(root, "DCIM").mkdirs()
        val item = view.stat("DCIM")
        assertTrue(item.dir)
        assertEquals(0L, item.size)
        assertEquals("DCIM", item.name)
        assertEquals(32, item.etag.length)
    }
}
