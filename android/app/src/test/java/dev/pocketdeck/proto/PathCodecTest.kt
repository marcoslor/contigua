package dev.pocketdeck.proto

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** docs/design/paths.md §5.3: the golden bytes, the 8 MiB bound, the mirror. */
class PathCodecTest {

    private fun hex(text: String): ByteArray =
        text.split(' ', '\n').filter { it.isNotBlank() }.map { it.toInt(16).toByte() }.toByteArray()

    @Test
    fun ackGoldenBytes() {
        val expected = hex(
            "00 00 00 0d 31 00 00 00 00 00 00 00 00 00 00 00 2a",
        )
        val frame = PathCodec.encodeAck(42)
        assertArrayEquals(expected, frame)
        assertEquals(42L, PathCodec.decodeAck(Frame(PathCodec.TYPE_ACK, 0, frame.copyOfRange(9, frame.size))))
    }

    @Test
    fun reliableGoldenBytes() {
        val json = "{\"t\":\"clip.set\",\"text\":\"hi\"}".toByteArray()
        val expected = hex(
            "00 00 00 2e 30 00 00 00 00 " +
                "00 00 00 00 00 00 00 07 " +
                "01 00 00 00 00",
        ) + json
        val encoded = PathCodec.encodeReliable(7, Frame(Frames.TYPE_JSON, 0, json))
        assertArrayEquals(expected, encoded)
        val decoded = PathCodec.decodeReliable(Frame(PathCodec.TYPE_RELIABLE, 0, encoded.copyOfRange(9, encoded.size)))
        assertEquals(7L, decoded.seq)
        assertEquals(Frames.TYPE_JSON, decoded.inner.type)
        assertEquals(0, decoded.inner.stream)
        assertArrayEquals(json, decoded.inner.payload)
    }

    @Test
    fun theLargestInnerPayloadRoundTrips() {
        val payload = ByteArray(PathCodec.MAX_INNER_PAYLOAD) { 0x5a }
        val encoded = PathCodec.encodeReliable(1, Frame(Frames.TYPE_JSON, 9, payload))
        assertEquals(4 + Frames.MAX_FRAME, encoded.size)
        val decoded = PathCodec.decodeReliable(
            Frame(PathCodec.TYPE_RELIABLE, 9, encoded.copyOfRange(9, encoded.size)),
        )
        assertEquals(PathCodec.MAX_INNER_PAYLOAD, decoded.inner.payload.size)
        assertArrayEquals(payload, decoded.inner.payload)
    }

    @Test
    fun oneBytePastTheLargestInnerPayloadIsRefused() {
        val payload = ByteArray(PathCodec.MAX_INNER_PAYLOAD + 1)
        try {
            PathCodec.encodeReliable(1, Frame(Frames.TYPE_JSON, 0, payload))
            fail("expected a refusal")
        } catch (e: PathException) {
            assertTrue(e.message!!.contains("too large"))
        }
    }

    @Test
    fun theOuterStreamMustMirrorTheInnerStream() {
        val encoded = PathCodec.encodeReliable(3, Frame(Frames.TYPE_TOUCH, 4, ByteArray(10)))
        val wrong = Frame(PathCodec.TYPE_RELIABLE, 5, encoded.copyOfRange(9, encoded.size))
        try {
            PathCodec.decodeReliable(wrong)
            fail("expected a protocol error")
        } catch (e: PathException) {
            assertTrue(e.message!!.contains("outer stream"))
        }
    }

    @Test
    fun onlyTheReliableTypesMayBeWrapped() {
        for (type in listOf(0x01, 0x10, 0x11, 0x12, 0x20, 0x21, 0x22, 0x23, 0x24)) {
            assertTrue(PathCodec.isReliable(type))
            PathCodec.encodeReliable(1, Frame(type, 0, ByteArray(0)))
        }
        for (type in listOf(0x02, 0x03, 0x04, 0x05, 0x13, 0x30, 0x31)) {
            assertFalse(PathCodec.isReliable(type))
            try {
                PathCodec.encodeReliable(1, Frame(type, 0, ByteArray(0)))
                fail("type $type must not be wrapped")
            } catch (_: PathException) {
            }
        }
    }
}
