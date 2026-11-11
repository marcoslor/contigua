package app.contigua.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The image cap math (docs/design/notify.md, "Part 2b design"): a fake bitmap
 * source stands in for Android's, so the scaling/format/byte rules are tested
 * without a device. No real picture bytes exist here.
 */
class NotifyImageTest {

    /** A source whose encoder returns `bytesPerPixel * w * h` bytes. */
    private class FakeSource(
        override val width: Int,
        override val height: Int,
        override val hasAlpha: Boolean = false,
        private val bytesPerPixel: Double = 0.25,
        private val constantSize: Int? = null,
        private val encoderFails: Boolean = false,
        private val shared: Record = Record(),
    ) : BitmapSource {
        class Record {
            val scaledTo = ArrayList<Pair<Int, Int>>()
            val encodedMimes = ArrayList<String>()
            var encodeCalls = 0
        }

        val record: Record get() = shared

        override fun scaledTo(width: Int, height: Int): BitmapSource {
            shared.scaledTo += width to height
            return FakeSource(width, height, hasAlpha, bytesPerPixel, constantSize, encoderFails, shared)
        }

        override fun encode(mime: String, quality: Int): ByteArray? {
            shared.encodeCalls += 1
            shared.encodedMimes += mime
            if (encoderFails) return null
            val size = constantSize ?: ((width.toDouble() * height * bytesPerPixel).toInt())
            return ByteArray(size)
        }
    }

    @Test
    fun `the long side is capped and the aspect kept`() {
        assertEquals(512 to 384, NotifyImageRules.targetSize(1024, 768, 512))
        assertEquals(171 to 512, NotifyImageRules.targetSize(300, 900, 512))
        assertEquals(512 to 512, NotifyImageRules.targetSize(2000, 2000, 512))
    }

    @Test
    fun `a small picture is never enlarged`() {
        assertEquals(200 to 120, NotifyImageRules.targetSize(200, 120, 512))
        val source = FakeSource(200, 120)
        val image = NotifyImageRules.encode(source)!!
        assertEquals(200, image.width)
        assertEquals(120, image.height)
        assertEquals(0, source.record.scaledTo.size)
    }

    @Test
    fun `alpha goes out as png, everything else as jpeg`() {
        assertEquals("image/png", NotifyImageRules.mime(hasAlpha = true))
        assertEquals("image/jpeg", NotifyImageRules.mime(hasAlpha = false))
        val alpha = NotifyImageRules.encode(FakeSource(64, 64, hasAlpha = true))!!
        assertEquals("image/png", alpha.mime)
        val opaque = NotifyImageRules.encode(FakeSource(64, 64))!!
        assertEquals("image/jpeg", opaque.mime)
    }

    @Test
    fun `too large is halved until it fits`() {
        // 4096² at 1.5 bytes/px: 512² is 393 KiB (over 200), 256² is 98 KiB.
        val source = FakeSource(4096, 4096, bytesPerPixel = 1.5)
        val image = NotifyImageRules.encode(source)!!
        assertEquals(256, image.width)
        assertEquals(256, image.height)
        assertEquals(2, source.record.encodedMimes.size) // 512, then 256
        assertEquals("image/jpeg", source.record.encodedMimes.last())
    }

    @Test
    fun `a picture that never fits is skipped`() {
        // Every encode returns 300 KiB regardless of size.
        val source = FakeSource(1024, 1024, constantSize = NotifyImageRules.MAX_BYTES + 1)
        assertNull(NotifyImageRules.encode(source))
        // 512, 256, 128, 64, 32
        assertEquals(5, source.record.encodeCalls)
    }

    @Test
    fun `the wire carries id, mime, size and base64 data only`() {
        val image = NotifyImage("image/jpeg", 512, 384, ByteArray(10) { 1 })
        val wire = image.wire("pd-1") { bytes -> "b64:${bytes.size}" }
        assertEquals(
            mapOf(
                "t" to "notify.image", "id" to "pd-1", "mime" to "image/jpeg",
                "w" to 512, "h" to 384, "data" to "b64:10",
            ),
            wire,
        )
    }

    @Test
    fun `a broken source or encoder produces no image`() {
        assertNull(NotifyImageRules.encode(null))
        assertNull(NotifyImageRules.encode(FakeSource(10, 10, encoderFails = true)))
        val empty = object : BitmapSource {
            override val width = 0
            override val height = 0
            override val hasAlpha = false
            override fun scaledTo(width: Int, height: Int): BitmapSource = this
            override fun encode(mime: String, quality: Int): ByteArray = ByteArray(1)
        }
        assertNull(NotifyImageRules.encode(empty))
    }

    @Test
    fun `an empty encode is skipped`() {
        assertNull(NotifyImageRules.encode(FakeSource(64, 64, constantSize = 0)))
    }

    @Test
    fun `encodeAt reports the size it scaled to`() {
        val image = NotifyImageRules.encodeAt(FakeSource(1200, 600), 512)!!
        assertEquals(512, image.width)
        assertEquals(256, image.height)
        assertNotNull(image.data)
    }
}
