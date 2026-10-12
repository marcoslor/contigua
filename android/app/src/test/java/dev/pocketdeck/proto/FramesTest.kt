package dev.pocketdeck.proto

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream

class FramesTest {

    private fun roundTrip(bytes: ByteArray): Frame {
        val reader = FrameReader(ByteArrayInputStream(bytes))
        return reader.readFrame()!!
    }

    @Test
    fun jsonRoundTrip() {
        val payload = """{"t":"ping","ts":7}""".toByteArray()
        val frame = roundTrip(Frames.encode(Frames.TYPE_JSON, 0, payload))
        assertEquals(Frames.TYPE_JSON, frame.type)
        assertEquals(0, frame.stream)
        assertEquals(7L, Json.parseObject(String(frame.payload))["ts"])
    }

    @Test
    fun touchRoundTripAndBigEndianFloat() {
        val payload = Frames.encodeTouch(TouchPayload(Frames.TOUCH_MOVE, 3, 0.25f, -1.0f))
        // nx = 0.25f -> 0x3E800000 big-endian at payload offset 2.
        assertArrayEquals(byteArrayOf(0x3E, 0x80.toByte(), 0, 0), payload.copyOfRange(2, 6))
        val frame = roundTrip(Frames.encode(Frames.TYPE_TOUCH, 9, payload))
        assertEquals(9, frame.stream)
        val decoded = Frames.decodeTouch(frame.payload)
        assertEquals(Frames.TOUCH_MOVE, decoded.action)
        assertEquals(3, decoded.pointerId)
        assertEquals(0.25f, decoded.nx, 0f)
        assertEquals(-1.0f, decoded.ny, 0f)
    }

    @Test
    fun scrollRoundTrip() {
        val payload = Frames.encodeScroll(ScrollPayload(0.5f, 0.5f, -3.0f, 6.0f))
        val decoded = Frames.decodeScroll(roundTrip(Frames.encode(Frames.TYPE_SCROLL, 2, payload)).payload)
        assertEquals(0.5f, decoded.nx, 0f)
        assertEquals(-3.0f, decoded.hscroll, 0f)
        assertEquals(6.0f, decoded.vscroll, 0f)
    }

    @Test
    fun keyRoundTrip() {
        val payload = Frames.encodeKey(KeyPayload(Frames.ACTION_DOWN, 4, 0x1000))
        val decoded = Frames.decodeKey(roundTrip(Frames.encode(Frames.TYPE_KEY, 1, payload)).payload)
        assertEquals(Frames.ACTION_DOWN, decoded.action)
        assertEquals(4, decoded.keycode)
        assertEquals(0x1000, decoded.metaState)
    }

    @Test
    fun videoConfigRoundTrip() {
        val csd = byteArrayOf(0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0xCE.toByte())
        val payload = Frames.encodeVideoConfig(VideoConfigPayload(Frames.CODEC_H264, 992, 688, csd))
        val decoded = Frames.decodeVideoConfig(roundTrip(Frames.encode(Frames.TYPE_VIDEO_CONFIG, 4, payload)).payload)
        assertEquals(Frames.CODEC_H264, decoded.codec)
        assertEquals(992, decoded.width)
        assertEquals(688, decoded.height)
        assertArrayEquals(csd, decoded.csd)
    }

    @Test
    fun videoFrameRoundTrip() {
        val au = byteArrayOf(0, 0, 0, 1, 0x65, 0x11, 0x22)
        val payload = Frames.encodeVideoFrame(VideoFramePayload(123456789L, true, au))
        val frame = roundTrip(Frames.encode(Frames.TYPE_VIDEO_FRAME, 4, payload))
        assertEquals(Frames.TYPE_VIDEO_FRAME, frame.type)
        val decoded = Frames.decodeVideoFrame(frame.payload)
        assertEquals(123456789L, decoded.ptsUs)
        assertTrue(decoded.key)
        assertArrayEquals(au, decoded.data)
    }

    @Test
    fun oversizeFrameRejected() {
        val header = byteArrayOf(
            0x00, 0x80.toByte(), 0x00, 0x01, // len = 8 MiB + 1
            0x01, // type
            0, 0, 0, 0, // stream
        )
        val reader = FrameReader(ByteArrayInputStream(header))
        try {
            reader.readFrame()
            fail("expected ProtocolException")
        } catch (e: ProtocolException) {
            assertTrue(e.message!!.contains("too large"))
        }
    }

    @Test
    fun undersizeFrameRejected() {
        val header = byteArrayOf(0, 0, 0, 4, 0x01, 0, 0, 0)
        try {
            FrameReader(ByteArrayInputStream(header)).readFrame()
            fail("expected ProtocolException")
        } catch (e: ProtocolException) {
            assertTrue(e.message!!.contains("too small"))
        }
    }

    @Test
    fun eofReturnsNull() {
        assertNull(FrameReader(ByteArrayInputStream(ByteArray(0))).readFrame())
    }

    @Test
    fun maxFrameBoundaryAccepted() {
        val payload = ByteArray(Frames.MAX_FRAME - 5)
        val bytes = Frames.encode(Frames.TYPE_JSON, 0, payload)
        assertFalse(FrameReader(ByteArrayInputStream(bytes)).readFrame() == null)
    }
}
