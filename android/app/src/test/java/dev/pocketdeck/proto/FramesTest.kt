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

    /**
     * HOVER: the same byte vector as the Swift test (0x13, enter, 0.25, 0.5).
     * Payload: u8 action · f32 nx · f32 ny.
     */
    @Test
    fun hoverFrameBytesMatchTheSwiftSide() {
        val payload = Frames.encodeHover(HoverPayload(Frames.HOVER_ENTER, 0.25f, 0.5f))
        assertArrayEquals(
            byteArrayOf(0x00, 0x3E, 0x80.toByte(), 0, 0, 0x3F, 0, 0, 0),
            payload,
        )
        val frame = roundTrip(Frames.encode(Frames.TYPE_HOVER, 3, payload))
        assertEquals(0x13, frame.type)
        assertEquals(3, frame.stream)
        val decoded = Frames.decodeHover(frame.payload)
        assertEquals(Frames.HOVER_ENTER, decoded.action)
        assertEquals(0.25f, decoded.nx, 0f)
        assertEquals(0.5f, decoded.ny, 0f)
    }

    @Test
    fun hoverMoveAndExitRoundTrip() {
        for (action in listOf(Frames.HOVER_MOVE, Frames.HOVER_EXIT)) {
            val decoded = Frames.decodeHover(
                Frames.encodeHover(HoverPayload(action, 0.75f, 0.125f)),
            )
            assertEquals(action, decoded.action)
            assertEquals(0.75f, decoded.nx, 0f)
            assertEquals(0.125f, decoded.ny, 0f)
        }
    }

    @Test
    fun shortHoverPayloadIsAProtocolError() {
        try {
            Frames.decodeHover(byteArrayOf(0, 0, 0))
            fail("a short hover payload must be rejected")
        } catch (e: ProtocolException) {
            // expected
        }
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
    fun audioConfigRoundTrip() {
        val setup = byteArrayOf(0x12, 0x10)
        val payload = Frames.encodeAudioConfig(AudioConfigPayload(Frames.CODEC_OPUS, 48000, 2, 20, setup))
        val frame = roundTrip(Frames.encode(Frames.TYPE_AUDIO_CONFIG, 0, payload))
        assertEquals(Frames.TYPE_AUDIO_CONFIG, frame.type)
        assertEquals(0, frame.stream)
        val decoded = Frames.decodeAudioConfig(frame.payload)
        assertEquals(Frames.CODEC_OPUS, decoded.codec)
        assertEquals(48000, decoded.sampleRate)
        assertEquals(2, decoded.channels)
        assertEquals(20, decoded.frameMs)
        assertArrayEquals(setup, decoded.setup)
    }

    @Test
    fun audioFrameRoundTrip() {
        val packet = byteArrayOf(0x4F, 0x70, 0x75, 0x73, 0x01, 0x02)
        val payload = Frames.encodeAudioFrame(AudioFramePayload(987654321L, packet))
        val frame = roundTrip(Frames.encode(Frames.TYPE_AUDIO_FRAME, 0, payload))
        assertEquals(Frames.TYPE_AUDIO_FRAME, frame.type)
        val decoded = Frames.decodeAudioFrame(frame.payload)
        assertEquals(987654321L, decoded.ptsUs)
        assertArrayEquals(packet, decoded.data)
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

    /**
     * A socket read can deliver part of a frame and then time out. What it
     * already took is that frame's prefix, not a header: the next call must
     * continue the frame. Reading it as a length prefix is how a full K1 run
     * once failed with "frame length too large" on a stream that was fine.
     */
    @Test
    fun aReadThatTimesOutMidFrameKeepsWhatItTook() {
        val one = Frames.encodeJson(0, """{"t":"a"}""")
        val two = Frames.encodeJson(0, """{"t":"b"}""")
        val stream = StallingStream(one + two, stallAfter = 2)
        val reader = FrameReader(stream)
        try {
            reader.readFrame()
            fail("expected the stalled read to throw")
        } catch (_: java.net.SocketTimeoutException) {
            // the short socket read timing out two bytes into the header
        }
        stream.stall = false
        assertEquals("a", Json.parseObject(String(reader.readFrame()!!.payload))["t"])
        assertEquals("b", Json.parseObject(String(reader.readFrame()!!.payload))["t"])
    }

    /** Delivers [bytes], and times out on every read once [stallAfter] are out. */
    private class StallingStream(private val bytes: ByteArray, private val stallAfter: Int) : java.io.InputStream() {
        @Volatile var stall = true
        private var at = 0

        override fun read(): Int = throw UnsupportedOperationException("block reads only")

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (stall && at >= stallAfter) throw java.net.SocketTimeoutException("read timed out")
            val room = if (stall) minOf(len, stallAfter - at) else len
            val n = minOf(room, bytes.size - at)
            if (n <= 0) return -1
            System.arraycopy(bytes, at, b, off, n)
            at += n
            return n
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
