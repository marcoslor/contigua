package app.contigua.proto

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** docs/design/paths.md §8, PATH-4/10/15. */
class ReplayBufferTest {

    private fun frame(seq: Long, bytes: Int, type: Int = Frames.TYPE_JSON): ByteArray =
        PathCodec.encodeReliable(seq, Frame(type, 0, ByteArray(bytes) { (seq and 0xff).toByte() }))

    @Test
    fun ackReleasesEverythingBelowIt() {
        val buffer = ReplayBuffer()
        for (seq in 1L..5L) buffer.append(seq, frame(seq, 10), bulk = false)
        assertEquals(5, buffer.count)
        assertEquals(2, buffer.ack(3))
        // Each encoded frame is 22 bytes of wrapper/header plus its 10-byte payload.
        assertEquals(3 * 32, buffer.heldBytes)
        assertEquals(listOf(3L, 4L, 5L), buffer.unacked().map { it.seq })
        assertEquals(0, buffer.ack(2))
        assertEquals(0, buffer.ack(3))
    }

    @Test
    fun replayFromTheLastAckAfterASwitch() {
        val buffer = ReplayBuffer()
        for (seq in 1L..4L) buffer.append(seq, frame(seq, 4), bulk = false)
        buffer.ack(2)
        assertEquals(listOf(2L, 3L, 4L), buffer.unacked().map { it.seq })
        assertArrayEquals(frame(2, 4), buffer.unacked()[0].frame)
    }

    @Test
    fun aDuplicateSeqIsNotAppended() {
        val buffer = ReplayBuffer()
        buffer.append(1, frame(1, 4), bulk = false)
        try {
            buffer.append(1, frame(1, 4), bulk = false)
            fail("expected a refusal")
        } catch (_: PathException) {
        }
        assertEquals(1, buffer.count)
    }

    @Test
    fun anEightMiBFrameFits() {
        val buffer = ReplayBuffer()
        val bytes = frame(1, PathCodec.MAX_INNER_PAYLOAD)
        assertEquals(Frames.MAX_FRAME + 4, bytes.size)
        assertTrue(buffer.canAdmit(bytes.size, bulk = false))
        buffer.append(1, bytes, bulk = false)
        assertEquals(Frames.MAX_FRAME + 4, buffer.heldBytes)
    }

    @Test
    fun aFramePastTheCapIsNeverAdmitted() {
        val buffer = ReplayBuffer()
        assertFalse(buffer.canAdmit(Frames.MAX_FRAME + 5, bulk = false))
        assertFalse(buffer.canAdmit(17 shl 20, bulk = false))
    }

    @Test
    fun bulkStopsAtTwelveMiBAndLeavesFourForControl() {
        val buffer = ReplayBuffer()
        var seq = 1L
        while (buffer.canAdmit((1 shl 20) + 64, bulk = true)) {
            buffer.append(seq, frame(seq, 1 shl 20, Frames.TYPE_DROP_DATA), bulk = true)
            seq++
        }
        assertTrue(buffer.bulkBytes <= ReplayBuffer.BULK_CAPACITY)
        assertTrue(ReplayBuffer.BULK_CAPACITY - buffer.bulkBytes < (1 shl 20))
        assertTrue(ReplayBuffer.CAPACITY - buffer.heldBytes >= (4 shl 20))
        val key = frame(seq, 16, Frames.TYPE_KEY)
        assertTrue(buffer.canAdmit(key.size, bulk = false))
        buffer.append(seq, key, bulk = false)
    }

    @Test
    fun controlMayUseTheWholeBufferWithoutBulk() {
        val buffer = ReplayBuffer()
        var seq = 1L
        while (buffer.canAdmit((1 shl 20) + 64, bulk = false)) {
            buffer.append(seq, frame(seq, 1 shl 20), bulk = false)
            seq++
        }
        assertTrue(buffer.heldBytes > ReplayBuffer.BULK_CAPACITY)
        assertTrue(buffer.heldBytes <= ReplayBuffer.CAPACITY)
    }

    @Test
    fun anAckAboveWhatWasSentIsAProtocolError() {
        val buffer = ReplayBuffer()
        buffer.append(1, frame(1, 4), bulk = false)
        assertFalse(buffer.ackAboveSent(2))
        assertTrue(buffer.ackAboveSent(3))
    }

    private fun assertArrayEquals(expected: ByteArray, actual: ByteArray) =
        org.junit.Assert.assertArrayEquals(expected, actual)
}
