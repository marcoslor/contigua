package dev.pocketdeck.server

import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.Json
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.security.MessageDigest
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit

/**
 * `fs.read` (docs/PROTOCOL.md "Phone files"): ranges at EOF, zero length,
 * partial reads, the etag check, cancel and the eight-read cap. The sender is
 * a fake bulk lane; frames are decoded back into JSON and chunks.
 */
class FsReaderTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private lateinit var paths: FsPaths
    private val bulk = CopyOnWriteArrayList<ByteArray>()
    private val json = Collections.synchronizedList(mutableListOf<Map<String, Any?>>())

    private fun setup(): FsPaths {
        paths = FsPaths(tmp.newFolder("sdcard"))
        return paths
    }

    private fun reader(
        maxReads: Int = FsReader.MAX_READS,
        send: ((ByteArray) -> Boolean)? = null,
    ) = FsReader(paths, send ?: { bulk += it; true }, { json += it }, maxReads = maxReads)

    private fun sha(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun file(name: String, bytes: ByteArray): File =
        File(paths.rootPath, name).also { it.writeBytes(bytes) }

    private fun read(
        id: Int,
        path: String,
        offset: Long = 0,
        length: Long = -1,
        etag: String? = null,
    ): Map<String, Any?> = mutableMapOf(
        "t" to "fs.read", "id" to id, "path" to path,
        "offset" to offset, "length" to length,
    ).also { if (etag != null) it["etag"] = etag }

    /** The bulk lane contents for one id: concatenated FS_DATA payloads, in order. */
    private fun data(id: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        for (frame in bulk) {
            if (frame.size < 9) continue
            val type = frame[4].toInt() and 0xFF
            val stream = ((frame[5].toInt() and 0xFF) shl 24) or ((frame[6].toInt() and 0xFF) shl 16) or
                ((frame[7].toInt() and 0xFF) shl 8) or (frame[8].toInt() and 0xFF)
            if (type == Frames.TYPE_FS_DATA && stream == id) out.write(frame, 9, frame.size - 9)
        }
        return out.toByteArray()
    }

    /** The fs.read.end of one id, or null. */
    private fun end(id: Int): Map<String, Any?>? {
        for (frame in bulk) {
            if (frame.size < 9 || frame[4].toInt() and 0xFF != Frames.TYPE_JSON) continue
            val obj = Json.parseObject(String(frame, 9, frame.size - 9, Charsets.UTF_8))
            if (obj["t"] == "fs.read.end" && (obj["id"] as Number).toInt() == id) return obj
        }
        return null
    }

    private fun failure(id: Int): Map<String, Any?>? =
        synchronized(json) { json.lastOrNull { it["t"] == "error" && (it["id"] as? Number)?.toInt() == id } }

    private fun awaitEnd(id: Int): Map<String, Any?> {
        repeat(200) {
            end(id)?.let { return it }
            Thread.sleep(10)
        }
        throw AssertionError("no fs.read.end for id $id; bulk=${bulk.size} json=${json}")
    }

    private fun awaitFailure(id: Int): Map<String, Any?> {
        repeat(200) {
            failure(id)?.let { return it }
            Thread.sleep(10)
        }
        throw AssertionError("no error for id $id")
    }

    @Test
    fun aRangeAtEofReadsTheLastBytes() {
        setup()
        val bytes = ByteArray(10) { it.toByte() }
        file("a.bin", bytes)
        val reader = reader()
        reader.begin(read(7, "a.bin", offset = 8, length = 2))
        val end = awaitEnd(7)
        assertEquals(2L, (end["size"] as Number).toLong())
        assertEquals(sha(bytes.copyOfRange(8, 10)), end["sha256"])
        assertArrayEquals(bytes.copyOfRange(8, 10), data(7))
    }

    @Test
    fun aZeroLengthReadEndsImmediatelyWithTheEmptyHash() {
        setup()
        file("a.bin", ByteArray(4))
        val reader = reader()
        reader.begin(read(3, "a.bin", offset = 4, length = 0))
        val end = awaitEnd(3)
        assertEquals(0L, (end["size"] as Number).toLong())
        assertEquals(sha(ByteArray(0)), end["sha256"])
        assertEquals(0, data(3).size)
    }

    @Test
    fun aPartialReadLeavesTheRestAlone() {
        setup()
        val bytes = ByteArray(1000) { (it % 251).toByte() }
        file("a.bin", bytes)
        val reader = reader()
        reader.begin(read(4, "a.bin", offset = 100, length = 300))
        awaitEnd(4)
        assertArrayEquals(bytes.copyOfRange(100, 400), data(4))
    }

    @Test
    fun chunksAreAtMostTheChunkSizeAndCoverTheFile() {
        setup()
        val bytes = ByteArray(8 * 1024 * 1024) { (it % 253).toByte() }
        file("big.bin", bytes)
        val reader = reader()
        reader.begin(read(5, "big.bin", length = bytes.size.toLong()))
        awaitEnd(5)
        val frames = bulk.filter { it[4].toInt() and 0xFF == Frames.TYPE_FS_DATA }
        assertEquals(bytes.size / FsReader.CHUNK_BYTES, frames.size)
        assertTrue(frames.all { it.size - 9 <= FsReader.CHUNK_BYTES })
        assertArrayEquals(bytes, data(5))
    }

    @Test
    fun aStaleEtagIsRefusedWithoutData() {
        setup()
        file("a.bin", ByteArray(16))
        val reader = reader()
        reader.begin(read(6, "a.bin", length = 16, etag = "0".repeat(32)))
        assertEquals("fs_stale", awaitFailure(6)["code"])
        assertEquals(0, bulk.size)
    }

    @Test
    fun aCurrentEtagIsAccepted() {
        setup()
        val bytes = ByteArray(16) { it.toByte() }
        file("a.bin", bytes)
        val etag = paths.item(File(paths.rootPath, "a.bin")).etag
        val reader = reader()
        reader.begin(read(6, "a.bin", length = 16, etag = etag))
        awaitEnd(6)
        assertArrayEquals(bytes, data(6))
    }

    @Test
    fun aRangeOutsideTheFileIsRefused() {
        setup()
        file("a.bin", ByteArray(10))
        val reader = reader()
        reader.begin(read(1, "a.bin", offset = 8, length = 3))
        assertEquals("fs_denied", awaitFailure(1)["code"])
        reader.begin(read(2, "a.bin", offset = 11, length = 0))
        assertEquals("fs_denied", awaitFailure(2)["code"])
        assertEquals(0, bulk.size)
    }

    @Test
    fun missingFilesAndDirectoriesAreRefused() {
        setup()
        File(paths.rootPath, "dir").mkdirs()
        val reader = reader()
        reader.begin(read(1, "nope", length = 1))
        assertEquals("fs_not_found", awaitFailure(1)["code"])
        reader.begin(read(2, "dir", length = 1))
        assertEquals("fs_not_a_dir", awaitFailure(2)["code"])
        reader.begin(read(3, "Android/x", length = 1))
        assertEquals("fs_denied", awaitFailure(3)["code"])
    }

    @Test
    fun cancelMidStreamStopsTheProducerAndSendsNoEnd() {
        setup()
        val bytes = ByteArray(6 * FsReader.CHUNK_BYTES) { (it % 251).toByte() }
        file("big.bin", bytes)
        val firstChunk = CountDownLatch(1)
        val release = CountDownLatch(1)
        val chunks = CopyOnWriteArrayList<Int>()
        val reader = reader { frame ->
            if (frame[4].toInt() and 0xFF == Frames.TYPE_FS_DATA) {
                chunks += frame.size
                if (chunks.size == 1) {
                    firstChunk.countDown()
                    assertTrue(release.await(5, TimeUnit.SECONDS))
                }
            }
            bulk += frame
            true
        }
        reader.begin(read(9, "big.bin", length = bytes.size.toLong()))
        assertTrue("the producer never sent the first chunk", firstChunk.await(5, TimeUnit.SECONDS))
        // The producer is parked inside the sender: no second chunk can exist.
        assertEquals(1, chunks.size)
        reader.cancel(9)
        release.countDown()
        Thread.sleep(300)
        assertEquals("cancelled read produced more chunks", 1, chunks.size)
        assertEquals(null, end(9))
    }

    @Test
    fun aNinthConcurrentReadIsBusy() {
        setup()
        file("big.bin", ByteArray(16 * FsReader.CHUNK_BYTES))
        val parked = CountDownLatch(8)
        val release = CountDownLatch(1)
        val reader = reader { frame ->
            if (frame[4].toInt() and 0xFF == Frames.TYPE_FS_DATA) {
                parked.countDown()
                assertTrue(release.await(10, TimeUnit.SECONDS))
            }
            true
        }
        repeat(8) { reader.begin(read(it + 1, "big.bin", length = 16L * FsReader.CHUNK_BYTES)) }
        assertTrue(parked.await(5, TimeUnit.SECONDS))
        reader.begin(read(99, "big.bin", length = 1))
        assertEquals("fs_busy", awaitFailure(99)["code"])
        repeat(8) { reader.cancel(it + 1) }
        release.countDown()
        reader.close()
    }

    @Test
    fun sessionEndAbandonsEveryRead() {
        setup()
        val bytes = ByteArray(4 * FsReader.CHUNK_BYTES)
        file("big.bin", bytes)
        val firstChunk = CountDownLatch(1)
        val release = CountDownLatch(1)
        val reader = reader { frame ->
            if (frame[4].toInt() and 0xFF == Frames.TYPE_FS_DATA) {
                firstChunk.countDown()
                assertTrue(release.await(5, TimeUnit.SECONDS))
            }
            bulk += frame
            true
        }
        reader.begin(read(11, "big.bin", length = bytes.size.toLong()))
        assertTrue(firstChunk.await(5, TimeUnit.SECONDS))
        val closing = Thread { reader.close() }
        closing.start()
        Thread.sleep(100)
        release.countDown()
        closing.join(5_000)
        assertEquals(null, end(11))
    }

    @Test
    fun aClosedBulkLaneAbandonsTheRead() {
        setup()
        val bytes = ByteArray(2 * FsReader.CHUNK_BYTES)
        file("big.bin", bytes)
        val reader = reader { false }
        reader.begin(read(12, "big.bin", length = bytes.size.toLong()))
        Thread.sleep(200)
        assertEquals(null, end(12))
    }
}
