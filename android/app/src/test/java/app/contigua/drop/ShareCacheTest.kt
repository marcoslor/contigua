package app.contigua.drop

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.RandomAccessFile

/** The share cache's copy and its two eviction rules (docs/design/dragdrop.md). */
class ShareCacheTest {

    @get:Rule
    val tmp = TemporaryFolder()

    /** Stands in for files/shared (what shell stages) and cache/shared (what is served). */
    private val stage: File by lazy { tmp.newFolder("stage") }
    private val cache: File by lazy { tmp.newFolder("cache") }

    private fun staged(name: String, bytes: Int = 8): File {
        val file = File(stage, name)
        file.writeBytes(ByteArray(bytes) { 1 })
        return file
    }

    private fun cached(name: String, ageMs: Long = 0): File {
        val file = File(cache, name)
        file.writeBytes(ByteArray(8) { 1 })
        if (ageMs > 0) file.setLastModified(System.currentTimeMillis() - ageMs)
        return file
    }

    @Test
    fun theCopyIsTheSharedFile() {
        val source = staged("report.pdf")
        val copy = ShareCache.put(cache, source)
        assertEquals(source.name, copy?.name)
        assertTrue(copy!!.readBytes().contentEquals(source.readBytes()))
        assertTrue(source.exists())
    }

    @Test
    fun theOldestFilesGoFirst() {
        cached("a.pdf", ageMs = 4_000)
        cached("b.pdf", ageMs = 3_000)
        cached("c.pdf", ageMs = 2_000)
        cached("d.pdf", ageMs = 1_000)
        cached("e.pdf", ageMs = 500)
        cached("f.pdf", ageMs = 100)
        val copy = ShareCache.put(cache, staged("new.pdf"))!!
        val names = cache.listFiles().orEmpty().map { it.name }.toSet()
        assertEquals(ShareCache.MAX_FILES, names.size)
        assertEquals(setOf("c.pdf", "d.pdf", "e.pdf", "f.pdf", "new.pdf"), names)
        assertTrue(copy.exists())
    }

    /** A sparse file of a logical size worth evicting, without the disk cost. */
    private fun sparse(name: String, bytes: Long, ageMs: Long): File {
        val file = File(cache, name)
        RandomAccessFile(file, "rw").use { it.setLength(bytes) }
        file.setLastModified(System.currentTimeMillis() - ageMs)
        return file
    }

    @Test
    fun theByteCapGoesFirstWhenItBites() {
        sparse("a.bin", 200L * 1024 * 1024, ageMs = 3_000)
        sparse("b.bin", 200L * 1024 * 1024, ageMs = 2_000)
        sparse("c.bin", 200L * 1024 * 1024, ageMs = 1_000)
        val copy = ShareCache.put(cache, staged("small.txt"))!!
        val names = cache.listFiles().orEmpty().map { it.name }.toSet()
        // 600 MB of old copies: the byte cap, not MAX_FILES, decides.
        assertEquals(setOf("b.bin", "c.bin", "small.txt"), names)
        assertTrue(copy.exists())
    }
}
