package app.contigua.server

import app.contigua.proto.Frames
import app.contigua.proto.Json
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.security.MessageDigest
import java.util.Collections
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * `fs.thumb` (docs/PROTOCOL.md "Phone files" › "Thumbnails"): the 512 long-side
 * cap, JPEG 80 and the PNG choice, the 256 KiB cap with one q60 re-encode, one
 * worker and FIFO order, cancel, the three-id cap and logs that carry no name.
 *
 * The platform is a fake [ThumbSource]; the bulk lane and the JSON lane are
 * lists the test reads back.
 */
class FsThumbnailerTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private lateinit var paths: FsPaths
    private val bulk = CopyOnWriteArrayList<ByteArray>()
    private val json = Collections.synchronizedList(mutableListOf<Map<String, Any?>>())
    private val log = Collections.synchronizedList(mutableListOf<String>())

    private class Call(val name: String, val video: Boolean, val longSide: Int,
                       val quality: Int, val allowPng: Boolean)

    private class FakeSource : ThumbSource {
        val calls = CopyOnWriteArrayList<Call>()
        @Volatile var renderer: (Call) -> ThumbBytes? = { ThumbBytes(byteArrayOf(1, 2, 3), "image/jpeg") }
        @Volatile var enter: CountDownLatch? = null
        @Volatile var release: CountDownLatch? = null

        override fun kind(name: String): Boolean? = when (name.substringAfterLast('.', "").lowercase()) {
            "jpg", "jpeg", "png", "heic" -> false
            "mp4", "mov" -> true
            else -> null
        }

        override fun render(file: File, video: Boolean, longSide: Int, quality: Int,
                            allowPng: Boolean, cancel: ThumbCancellation): ThumbBytes? {
            val call = Call(file.name, video, longSide, quality, allowPng)
            calls += call
            enter?.countDown()
            release?.let { if (!it.await(10, TimeUnit.SECONDS)) return null }
            if (cancel.isCancelled()) return null
            return renderer(call)
        }
    }

    private fun setup(): FakeSource {
        paths = FsPaths(tmp.newFolder("sdcard"))
        return FakeSource()
    }

    private fun thumbs(source: ThumbSource, send: ((ByteArray) -> Boolean)? = null) = FsThumbnailer(
        paths, source, send ?: { bulk += it; true }, { json += it }, { log += it })

    private fun file(name: String, bytes: ByteArray): File =
        File(paths.rootPath, name).also {
            it.parentFile?.mkdirs()
            it.writeBytes(bytes)
        }

    private fun ask(id: Int, path: String, size: Long = 512, etag: String? = null) =
        mutableMapOf<String, Any?>("t" to "fs.thumb", "id" to id, "path" to path, "size" to size)
            .also { if (etag != null) it["etag"] = etag }

    private fun sha(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun data(id: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        for (frame in bulk) {
            if (frame.size < 9) continue
            val type = frame[4].toInt() and 0xFF
            val stream = ((frame[5].toInt() and 0xFF) shl 24) or ((frame[6].toInt() and 0xFF) shl 16) or
                ((frame[7].toInt() and 0xFF) shl 8) or (frame[8].toInt() and 0xFF)
            if (type == Frames.TYPE_FS_DATA && (stream.toLong() and 0xFFFF_FFFFL) == id.toLong()) {
                out.write(frame, 9, frame.size - 9)
            }
        }
        return out.toByteArray()
    }

    private fun end(id: Int): Map<String, Any?>? {
        for (frame in bulk) {
            if (frame.size < 9 || frame[4].toInt() and 0xFF != Frames.TYPE_JSON) continue
            val obj = Json.parseObject(String(frame, 9, frame.size - 9, Charsets.UTF_8))
            if (obj["t"] == "fs.thumb.end" && (obj["id"] as Number).toLong() == id.toLong()) return obj
        }
        return null
    }

    private fun failure(id: Int): Map<String, Any?>? =
        synchronized(json) { json.lastOrNull { it["t"] == "error" && (it["id"] as? Number)?.toInt() == id } }

    private fun awaitEnd(id: Int): Map<String, Any?> {
        repeat(300) {
            end(id)?.let { return it }
            Thread.sleep(10) // real-time: polling another thread's reply
        }
        throw AssertionError("no fs.thumb.end for id $id; bulk=${bulk.size} json=${json}")
    }

    private fun awaitFailure(id: Int): Map<String, Any?> {
        repeat(300) {
            failure(id)?.let { return it }
            Thread.sleep(10) // real-time: polling another thread's reply
        }
        throw AssertionError("no error for id $id; json=${json}")
    }

    private fun awaitCalls(source: FakeSource, count: Int) {
        repeat(300) {
            if (source.calls.size >= count) return
            Thread.sleep(10) // real-time: polling another thread's reply
        }
        throw AssertionError("only ${source.calls.size} render calls, wanted $count")
    }

    @Test
    fun aJpegIsOneBulkFrameThenTheEnd() {
        val source = setup()
        val bytes = ByteArray(100) { (it % 97).toByte() }
        source.renderer = { ThumbBytes(bytes, "image/jpeg") }
        file("DCIM/Camera/photo.jpg", ByteArray(4))
        val thumbs = thumbs(source)
        thumbs.begin(ask(7, "DCIM/Camera/photo.jpg"))
        val end = awaitEnd(7)
        assertEquals("image/jpeg", end["mime"])
        assertEquals(100L, (end["size"] as Number).toLong())
        assertEquals(sha(bytes), end["sha256"])
        assertArrayEquals(bytes, data(7))
        val frames = bulk.filter { it[4].toInt() and 0xFF == Frames.TYPE_FS_DATA }
        assertEquals(1, frames.size)
    }

    @Test
    fun theLongSideIsTheRequestCappedAt512() {
        val source = setup()
        file("a.jpg", ByteArray(4))
        val thumbs = thumbs(source)
        thumbs.begin(ask(1, "a.jpg", size = 2048))
        awaitEnd(1)
        thumbs.begin(ask(2, "a.jpg", size = 300))
        awaitEnd(2)
        assertEquals(512, source.calls[0].longSide)
        assertEquals(300, source.calls[1].longSide)
        assertFalse(source.calls[0].video)
        assertEquals(80, source.calls[0].quality)
        assertTrue(source.calls[0].allowPng)
    }

    @Test
    fun aVideoNameAsksTheVideoGenerator() {
        val source = setup()
        file("DCIM/Camera/clip.mp4", ByteArray(4))
        val thumbs = thumbs(source)
        thumbs.begin(ask(1, "DCIM/Camera/clip.mp4"))
        awaitEnd(1)
        assertTrue(source.calls.single().video)
    }

    @Test
    fun aVideoNeverAsksForPng() {
        // A video frame is opaque even when the bitmap reports alpha; boot 2's
        // MP4 came back as a 29 KB PNG (FILES-24).
        val source = setup()
        file("DCIM/Camera/clip.mp4", ByteArray(4))
        val thumbs = thumbs(source)
        thumbs.begin(ask(1, "DCIM/Camera/clip.mp4"))
        awaitEnd(1)
        assertFalse(source.calls.single().allowPng)
    }

    @Test
    fun anAlphaPngIsPassedThrough() {
        val source = setup()
        source.renderer = { ThumbBytes(byteArrayOf(2, 3, 4), "image/png") }
        file("a.png", ByteArray(4))
        val thumbs = thumbs(source)
        thumbs.begin(ask(1, "a.png"))
        assertEquals("image/png", awaitEnd(1)["mime"])
        assertTrue(source.calls.single().allowPng)
    }

    @Test
    fun anOversizedAnswerIsReencodedOnceAtSixty() {
        val source = setup()
        val big = ByteArray(300 * 1024) { 1 }
        val small = ByteArray(200 * 1024) { 2 }
        source.renderer = { call ->
            if (call.quality == 80) ThumbBytes(big, "image/jpeg") else ThumbBytes(small, "image/jpeg")
        }
        file("a.jpg", ByteArray(4))
        val thumbs = thumbs(source)
        thumbs.begin(ask(1, "a.jpg"))
        val end = awaitEnd(1)
        assertEquals(2, source.calls.size)
        assertEquals(60, source.calls[1].quality)
        assertFalse(source.calls[1].allowPng)
        assertEquals(200L * 1024, (end["size"] as Number).toLong())
        assertArrayEquals(small, data(1))
    }

    @Test
    fun stillOversizedIsNoThumbAndNoBytes() {
        val source = setup()
        source.renderer = { ThumbBytes(ByteArray(300 * 1024), "image/jpeg") }
        file("a.jpg", ByteArray(4))
        val thumbs = thumbs(source)
        thumbs.begin(ask(1, "a.jpg"))
        assertEquals("fs_no_thumb", awaitFailure(1)["code"])
        assertEquals(2, source.calls.size)
        assertEquals(0, bulk.size)
    }

    @Test
    fun aSizeOutsideOneTo4096IsDenied() {
        val source = setup()
        file("a.jpg", ByteArray(4))
        val thumbs = thumbs(source)
        thumbs.begin(ask(1, "a.jpg", size = 0))
        assertEquals("fs_denied", awaitFailure(1)["code"])
        thumbs.begin(ask(2, "a.jpg", size = 4097))
        assertEquals("fs_denied", awaitFailure(2)["code"])
        assertEquals(0, source.calls.size)
    }

    @Test
    fun missingFilesDirectoriesAndNonMediaAreRefused() {
        val source = setup()
        File(paths.rootPath, "dir").mkdirs()
        file("notes.txt", ByteArray(4))
        val thumbs = thumbs(source)
        thumbs.begin(ask(1, "nope.jpg"))
        assertEquals("fs_not_found", awaitFailure(1)["code"])
        thumbs.begin(ask(2, "dir"))
        assertEquals("fs_not_a_dir", awaitFailure(2)["code"])
        thumbs.begin(ask(3, "notes.txt"))
        assertEquals("fs_no_thumb", awaitFailure(3)["code"])
        thumbs.begin(ask(4, "Android/secret.jpg"))
        assertEquals("fs_denied", awaitFailure(4)["code"])
        assertEquals(0, source.calls.size)
    }

    @Test
    fun aStaleEtagIsRefusedAndACurrentOneAccepted() {
        val source = setup()
        file("a.jpg", ByteArray(4))
        val etag = paths.item(File(paths.rootPath, "a.jpg")).etag
        val thumbs = thumbs(source)
        thumbs.begin(ask(1, "a.jpg", etag = "0".repeat(32)))
        assertEquals("fs_stale", awaitFailure(1)["code"])
        thumbs.begin(ask(2, "a.jpg", etag = etag))
        awaitEnd(2)
    }

    @Test
    fun oneWorkerAndFifoOrder() {
        val source = setup()
        val enter = CountDownLatch(1)
        val release = CountDownLatch(1)
        source.enter = enter
        source.release = release
        file("a.jpg", ByteArray(4))
        file("b.jpg", ByteArray(4))
        file("c.jpg", ByteArray(4))
        val thumbs = thumbs(source)
        thumbs.begin(ask(1, "a.jpg"))
        assertTrue(enter.await(5, TimeUnit.SECONDS))
        thumbs.begin(ask(2, "b.jpg"))
        thumbs.begin(ask(3, "c.jpg"))
        Thread.sleep(100) // real-time: a second step would land in this window
        assertEquals("more than one render ran at once", 1, source.calls.size)
        release.countDown()
        awaitEnd(3)
        assertEquals(listOf("a.jpg", "b.jpg", "c.jpg"), source.calls.map { it.name })
    }

    @Test
    fun aFourthLiveIdIsBusy() {
        val source = setup()
        val enter = CountDownLatch(1)
        val release = CountDownLatch(1)
        source.enter = enter
        source.release = release
        file("a.jpg", ByteArray(4))
        val thumbs = thumbs(source)
        repeat(3) { thumbs.begin(ask(it + 1, "a.jpg")) }
        assertTrue(enter.await(5, TimeUnit.SECONDS))
        thumbs.begin(ask(9, "a.jpg"))
        assertEquals("fs_busy", awaitFailure(9)["code"])
        thumbs.cancel(1L)
        release.countDown()
    }

    @Test
    fun aCancelledQueuedJobNeverRenders() {
        val source = setup()
        val enter = CountDownLatch(1)
        val release = CountDownLatch(1)
        source.enter = enter
        source.release = release
        file("a.jpg", ByteArray(4))
        file("b.jpg", ByteArray(4))
        file("c.jpg", ByteArray(4))
        val thumbs = thumbs(source)
        thumbs.begin(ask(1, "a.jpg"))
        assertTrue(enter.await(5, TimeUnit.SECONDS))
        thumbs.begin(ask(2, "b.jpg"))
        thumbs.begin(ask(3, "c.jpg"))
        thumbs.cancel(3L)
        release.countDown()
        awaitEnd(2)
        Thread.sleep(150) // real-time: a wrong render would land in this window
        assertEquals(listOf("a.jpg", "b.jpg"), source.calls.map { it.name })
        assertNull(end(3))
        assertNull(failure(3))
    }

    @Test
    fun aCancelMidRenderSendsNothing() {
        val source = setup()
        val enter = CountDownLatch(1)
        val release = CountDownLatch(1)
        source.enter = enter
        source.release = release
        file("a.jpg", ByteArray(4))
        val thumbs = thumbs(source)
        thumbs.begin(ask(1, "a.jpg"))
        assertTrue(enter.await(5, TimeUnit.SECONDS))
        thumbs.cancel(1L)
        release.countDown()
        Thread.sleep(200) // real-time: a send or render would land in this window
        assertNull(end(1))
        assertNull(failure(1))
        assertEquals(0, bulk.size)
    }

    @Test
    fun aCancelFiresThePlatformsCancellation() {
        val source = setup()
        val enter = CountDownLatch(1)
        val release = CountDownLatch(1)
        val fired = CountDownLatch(1)
        file("a.jpg", ByteArray(4))
        // The real source registers the signal; emulate that over the seam.
        val seam = object : ThumbSource by source {
            override fun render(file: File, video: Boolean, longSide: Int, quality: Int,
                                allowPng: Boolean, cancel: ThumbCancellation): ThumbBytes? {
                cancel.onCancel { fired.countDown() }
                return source.render(file, video, longSide, quality, allowPng, cancel)
            }
        }
        source.enter = enter
        source.release = release
        val thumbs = thumbs(seam)
        thumbs.begin(ask(1, "a.jpg"))
        assertTrue(enter.await(5, TimeUnit.SECONDS))
        thumbs.cancel(1L)
        assertTrue("the platform was never cancelled", fired.await(2, TimeUnit.SECONDS))
        release.countDown()
    }

    @Test
    fun nothingRunsWithoutARequest() {
        val source = setup()
        val thumbs = thumbs(source)
        Thread.sleep(50) // real-time: a stray worker would start in this window
        assertEquals(0, source.calls.size)
        assertTrue(bulk.isEmpty())
        assertTrue(json.isEmpty())
        thumbs.close()
    }

    @Test
    fun aClosedBulkLaneSendsNoEnd() {
        val source = setup()
        file("a.jpg", ByteArray(4))
        val thumbs = thumbs(source) { false }
        thumbs.begin(ask(1, "a.jpg"))
        Thread.sleep(200) // real-time: a send or render would land in this window
        assertNull(end(1))
        assertEquals(0, bulk.size)
    }

    @Test
    fun sessionEndAbandonsEveryJob() {
        val source = setup()
        val enter = CountDownLatch(1)
        val release = CountDownLatch(1)
        source.enter = enter
        source.release = release
        file("a.jpg", ByteArray(4))
        val thumbs = thumbs(source)
        thumbs.begin(ask(1, "a.jpg"))
        assertTrue(enter.await(5, TimeUnit.SECONDS))
        val closing = Thread { thumbs.close() }
        closing.start()
        Thread.sleep(100) // real-time: a second step would land in this window
        release.countDown()
        closing.join(5_000)
        assertNull(end(1))
        assertNull(failure(1))
    }

    @Test
    fun logsCarryNoName() {
        val source = setup()
        file("DCIM/Camera/photo.jpg", ByteArray(4))
        file("notes.txt", ByteArray(4))
        val thumbs = thumbs(source)
        thumbs.begin(ask(1, "DCIM/Camera/photo.jpg"))
        awaitEnd(1)
        thumbs.begin(ask(2, "notes.txt"))
        awaitFailure(2)
        val lines = synchronized(log) { log.joinToString("\n") }
        assertFalse(lines, lines.contains("photo.jpg"))
        assertFalse(lines, lines.contains("DCIM"))
        assertFalse(lines, lines.contains("notes.txt"))
        assertTrue(lines, lines.contains("thumb"))
    }
}
