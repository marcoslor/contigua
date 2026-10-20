package dev.pocketdeck.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The artwork cap math of "Media part 2" (docs/design/notify.md): a fake bitmap
 * source stands in for Android's, so the scale/format/byte/dedupe rules are
 * tested without a device and without any real picture.
 */
class MediaArtTest {

    /** A source whose encoder returns `bytesPerPixel * w * h` bytes. */
    private class FakeSource(
        override val width: Int,
        override val height: Int,
        override val hasAlpha: Boolean = false,
        private val bytesPerPixel: Double = 0.25,
        private val encoderFails: Boolean = false,
        private val record: Record = Record(),
    ) : BitmapSource {
        class Record {
            val scaledTo = ArrayList<Pair<Int, Int>>()
            val mimes = ArrayList<String>()
            val qualities = ArrayList<Int>()
        }

        override fun scaledTo(width: Int, height: Int): BitmapSource {
            record.scaledTo += width to height
            return FakeSource(width, height, hasAlpha, bytesPerPixel, encoderFails, record)
        }

        override fun encode(mime: String, quality: Int): ByteArray? {
            record.mimes += mime
            record.qualities += quality
            if (encoderFails) return null
            return ByteArray((width.toDouble() * height * bytesPerPixel).toInt())
        }
    }

    @Test
    fun `the long side is capped at 512 and the aspect kept`() {
        assertEquals(512 to 384, MediaArtRules.targetSize(1024, 768, 512))
        assertEquals(171 to 512, MediaArtRules.targetSize(300, 900, 512))
        assertEquals(512 to 512, MediaArtRules.targetSize(2000, 2000, 512))
    }

    @Test
    fun `a small picture is never enlarged`() {
        val record = FakeSource.Record()
        val art = MediaArtRules.encode(FakeSource(200, 120, record = record))!!
        assertEquals(200, art.width)
        assertEquals(120, art.height)
        assertEquals(0, record.scaledTo.size)
    }

    @Test
    fun `artwork is always jpeg quality 80`() {
        val record = FakeSource.Record()
        val art = MediaArtRules.encode(FakeSource(600, 600, hasAlpha = true, record = record))!!
        assertEquals("image/jpeg", art.mime)
        assertEquals(listOf("image/jpeg"), record.mimes)
        assertEquals(listOf(MediaArtRules.JPEG_QUALITY), record.qualities)
    }

    @Test
    fun `a picture over the byte cap is halved until it fits`() {
        // 512x512 at 1.2 bytes/px is 314 KB: over the 256 KiB cap; 256x256 fits.
        val art = MediaArtRules.encode(FakeSource(512, 512, bytesPerPixel = 1.2))!!
        assertEquals(256, art.width)
        assertEquals(256, art.height)
    }

    @Test
    fun `nothing at all when no size fits`() {
        assertNull(MediaArtRules.encode(FakeSource(512, 512, bytesPerPixel = 400.0)))
        assertNull(MediaArtRules.encode(null))
        assertNull(MediaArtRules.encode(FakeSource(512, 512, encoderFails = true)))
    }

    @Test
    fun `the hash is short, stable and changes with the bytes`() {
        val a = MediaArtRules.hash(ByteArray(100) { 1 })
        val b = MediaArtRules.hash(ByteArray(100) { 1 })
        val c = MediaArtRules.hash(ByteArray(100) { 2 })
        assertEquals(a, b)
        assertNotEquals(a, c)
        assertEquals(16, a.length)
        assertEquals(a.lowercase(), a)
    }

    @Test
    fun `the wire carries the key, the dimensions and base64 only`() {
        val art = MediaArt("image/jpeg", 40, 30, ByteArray(3))
        val wire = art.wire("s2") { "AAA=" }
        assertEquals("media.art", wire["t"])
        assertEquals("s2", wire["key"])
        assertEquals("image/jpeg", wire["mime"])
        assertEquals(40, wire["w"])
        assertEquals(30, wire["h"])
        assertEquals("AAA=", wire["data"])
        assertNotNull(wire)
    }
}
