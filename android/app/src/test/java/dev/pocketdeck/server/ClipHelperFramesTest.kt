package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

/** The helper's length-prefixed frames, text and binary images (ISS-27). */
class ClipHelperFramesTest {

    private fun roundTrip(type: Int, id: Int, payload: ByteArray): ClipHelperFrame? {
        val bytes = ByteArrayOutputStream()
        ClipHelperFrames.write(bytes, type, id, payload)
        return ClipHelperFrames.read(ByteArrayInputStream(bytes.toByteArray()))
    }

    @Test
    fun aTextReplyKeepsItsFlagsAndUtf8() {
        val text = "synthetic-\u00e9\u4e2d-" + "g".repeat(4)
        val parsed = parseClipTextReply(clipTextPayload(ClipText(text, sensitive = true)))
        assertEquals(text, parsed?.text)
        assertEquals(true, parsed?.sensitive)
        assertNull(parseClipTextReply(clipTextPayload(null)))
    }

    @Test
    fun anImageReplyIsBinarySafe() {
        val bytes = ByteArray(256) { it.toByte() }
        val parsed = parseClipImageReply(clipImagePayload(ClipImage(bytes, "image/png")))
        assertEquals("image/png", parsed?.mime)
        assertTrue(bytes.contentEquals(parsed!!.bytes))
        assertNull(parseClipImageReply(clipImagePayload(null)))
    }

    @Test
    fun anOverCapImageIsNeverSent() {
        val bytes = ByteArray(ClipImagePolicy.MAX_BYTES + 1)
        val payload = clipImagePayload(ClipImage(bytes, "image/png"))
        assertEquals(1, payload.size)
        assertEquals(0, payload[0].toInt())
        assertNull(parseClipImageReply(payload))
    }

    @Test
    fun aFrameCarriesItsTypeIdAndPayloadVerbatim() {
        val payload = ByteArray(300) { (it * 37).toByte() }
        val frame = roundTrip(ClipHelperFrames.IMAGE, 12, payload)
        assertEquals(ClipHelperFrames.IMAGE, frame?.type)
        assertEquals(12, frame?.id)
        assertTrue(payload.contentEquals(frame!!.payload))
    }

    @Test
    fun aTruncatedOrOversizedFrameIsADeadHelper() {
        val bytes = ByteArrayOutputStream()
        ClipHelperFrames.write(bytes, ClipHelperFrames.TEXT, 1)
        val full = bytes.toByteArray()
        assertNull(ClipHelperFrames.read(ByteArrayInputStream(full.copyOf(full.size - 1))))

        val tooBig = ByteArrayOutputStream()
        tooBig.write(
            byteArrayOf(
                ((ClipHelperFrames.MAX_FRAME_BYTES + 1) ushr 24).toByte(),
                ((ClipHelperFrames.MAX_FRAME_BYTES + 1) ushr 16).toByte(),
                ((ClipHelperFrames.MAX_FRAME_BYTES + 1) ushr 8).toByte(),
                (ClipHelperFrames.MAX_FRAME_BYTES + 1).toByte(),
            ),
        )
        assertNull(ClipHelperFrames.read(ByteArrayInputStream(tooBig.toByteArray())))
    }

    @Test
    fun anImageReplyWithABadMimeLengthIsRefused() {
        val payload = byteArrayOf(1, 0, 9, 'a'.code.toByte())
        assertNull(parseClipImageReply(payload))
        assertNull(parseClipImageReply(byteArrayOf(1, 0, 0)))
        assertNull(parseClipImageReply(byteArrayOf(0)))
    }
}
