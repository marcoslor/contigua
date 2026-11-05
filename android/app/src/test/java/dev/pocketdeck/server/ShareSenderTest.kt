package dev.pocketdeck.server

import dev.pocketdeck.proto.Crypto
import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest

class ShareSenderTest {

    private val textJson = mutableListOf<Map<String, Any?>>()
    private val frames = mutableListOf<ByteArray>()

    /** JSON frames of the bulk lane, in order. */
    private val json get() = textJson + frames.filter { it[4].toInt() == Frames.TYPE_JSON }
        .map { Json.parseObject(String(it, 9, it.size - 9)) }
    private val bulk get() = frames.filter { it[4].toInt() == Frames.TYPE_SHARE_DATA }

    private fun sender(open: Boolean = true, max: Long = ShareSender.MAX_FILE_BYTES) =
        ShareSender({ textJson += it }, { frames += it; open }, maxFileBytes = max, chunkBytes = 4)

    @Test
    fun textGoesOutAsShareText() {
        assertEquals(ShareStatus.OK, sender().text("hello"))
        assertEquals(mapOf("t" to "share.text", "text" to "hello"), json.single())
        assertEquals(ShareStatus.FAILED, sender().text(""))
        assertEquals(ShareStatus.TOO_LARGE, sender().text("x".repeat(ShareSender.MAX_TEXT_BYTES + 1)))
    }

    @Test
    fun fileIsChunkedAndEndsWithSizeAndHash() {
        val data = ByteArray(10) { it.toByte() }
        assertEquals(ShareStatus.OK, sender().file("a.png", "image/png", ByteArrayInputStream(data)))
        assertEquals(mapOf("t" to "share.file", "id" to 1L, "name" to "a.png", "mime" to "image/png"), json.first())
        assertEquals(3, bulk.size)
        val payloads = bulk.map { frame ->
            assertEquals(Frames.TYPE_SHARE_DATA, frame[4].toInt())
            frame.copyOfRange(9, frame.size)
        }
        assertTrue(data.contentEquals(payloads.reduce { a, b -> a + b }))
        val end = json.last()
        assertEquals("share.end", end["t"])
        assertEquals(10L, end["size"])
        assertEquals(Crypto.toHex(MessageDigest.getInstance("SHA-256").digest(data)), end["sha256"])
    }

    @Test
    fun overTheCapAborts() {
        assertEquals(ShareStatus.TOO_LARGE, sender(max = 6).file("a.png", "image/png", ByteArrayInputStream(ByteArray(7))))
        assertEquals("share.abort", json.last()["t"])
        assertFalse(json.any { it["t"] == "share.end" })
    }

    @Test
    fun exactlyTheCapIsSent() {
        assertEquals(ShareStatus.OK, sender(max = 8).file("a.png", "image/png", ByteArrayInputStream(ByteArray(8))))
        assertEquals("share.end", json.last()["t"])
    }

    @Test
    fun readErrorAborts() {
        val broken = object : InputStream() {
            override fun read(): Int = throw IOException("gone")
            override fun read(b: ByteArray, off: Int, len: Int): Int = throw IOException("gone")
        }
        assertEquals(ShareStatus.FAILED, sender().file("a.png", "image/png", broken))
        assertEquals("share.abort", json.last()["t"])
    }

    @Test
    fun closedSessionStopsTheFile() {
        assertEquals(ShareStatus.NO_SESSION, sender(open = false).file("a.png", "image/png", ByteArrayInputStream(ByteArray(10))))
        assertEquals(1, frames.size)
    }

    @Test
    fun idsIncrease() {
        val s = sender()
        s.file("a", "image/png", ByteArrayInputStream(ByteArray(1)))
        s.file("b", "image/png", ByteArrayInputStream(ByteArray(1)))
        assertEquals(listOf(1L, 2L), json.filter { it["t"] == "share.file" }.map { it["id"] })
    }

    @Test
    fun bulkLaneIsLastAndBlocksWhenFull() {
        val q = SendQueue(maxBulkBytes = 4)
        assertTrue(q.enqueueBulk(ByteArray(3)))
        q.enqueueJson(byteArrayOf(9))
        val blocked = Thread { q.enqueueBulk(ByteArray(3)) }
        blocked.start()
        Thread.sleep(100)
        assertTrue(blocked.isAlive)
        assertEquals(1, q.pollNow()!!.bytes.size)
        assertEquals(3, q.pollNow()!!.bytes.size)
        blocked.join(1_000)
        assertFalse(blocked.isAlive)
        q.close()
        assertFalse(q.enqueueBulk(ByteArray(1)))
    }
}
