package app.contigua.proto

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.MessageDigest

/** Credit, never a drop (docs/design/paths.md §8, PATH-10/15). */
class CreditTest {
    private val chunk = 1 shl 20
    private val total = 200 shl 20

    @Test
    fun aBulkProducerStopsAtTwelveMiBAndResumesOnTheAck() {
        val buffer = ReplayBuffer()
        var offset = 0
        var seq = 1L
        var waits = 0
        var maxBulk = 0
        while (offset < 40 shl 20) {
            if (!buffer.canAdmit(chunk + 64, bulk = true)) {
                waits++
                assertTrue(buffer.bulkBytes <= ReplayBuffer.BULK_CAPACITY)
                buffer.ack(buffer.lastSeq - 3)
                continue
            }
            val payload = ByteArray(chunk) { ((offset + it) * 31 + 7).toByte() }
            buffer.append(seq, PathCodec.encodeReliable(seq, Frame(Frames.TYPE_DROP_DATA, 1, payload)), true)
            offset += chunk
            seq++
            maxBulk = maxOf(maxBulk, buffer.bulkBytes)
        }
        assertTrue("the producer waited", waits > 0)
        assertTrue(maxBulk <= ReplayBuffer.BULK_CAPACITY)
    }

    @Test
    fun aControlFrameGoesOutWhenBulkHoldsItsWholeBudget() {
        val buffer = ReplayBuffer()
        var seq = 1L
        while (buffer.canAdmit(chunk + 64, bulk = true)) {
            buffer.append(
                seq,
                PathCodec.encodeReliable(seq, Frame(Frames.TYPE_SHARE_DATA, 1, ByteArray(chunk))),
                true,
            )
            seq++
        }
        val key = PathCodec.encodeReliable(seq, Frame(Frames.TYPE_KEY, 0, ByteArray(9)))
        assertTrue(buffer.canAdmit(key.size, bulk = false))
        buffer.append(seq, key, bulk = false)
        assertTrue(buffer.bulkBytes > 0)
    }

    @Test
    fun aTwoHundredMiBTransferAcrossAnOrphanIsByteExact() {
        val buffer = ReplayBuffer()
        val source = MessageDigest.getInstance("SHA-256")
        val delivered = MessageDigest.getInstance("SHA-256")
        var offset = 0
        var seq = 1L
        var deliveredBytes = 0
        var maxHeld = 0
        var silentPolls = 0
        var orphanRounds = 0
        var sawSilence = false
        var outageDone = false
        var outage = false

        while (deliveredBytes < total) {
            if (buffer.canAdmit(chunk + 64, bulk = true)) {
                val payload = ByteArray(minOf(chunk, total - offset)) { ((offset + it) * 31 + 7).toByte() }
                offset += payload.size
                source.update(payload)
                val encoded = PathCodec.encodeReliable(seq, Frame(Frames.TYPE_DROP_DATA, 1, payload))
                buffer.append(seq, encoded, true)
                seq++
                maxHeld = maxOf(maxHeld, buffer.heldBytes)
                // Mid-transfer the radio goes silent for ten ack rounds.
                if (!outageDone && deliveredBytes >= (20 shl 20) && !outage) {
                    outage = true
                    sawSilence = true
                }
                if (!outage) {
                    buffer.ack(buffer.lastSeq + 1)
                    delivered.update(payload)
                    deliveredBytes += payload.size
                }
            } else if (!buffer.isEmpty) {
                outage = true
                sawSilence = true
                silentPolls++
                if (silentPolls > 10) {
                    silentPolls = 0
                    orphanRounds++
                    outageDone = true
                    outage = false
                    for (entry in buffer.unacked()) {
                        val inner = PathCodec.decodeReliable(
                            Frame(
                                PathCodec.TYPE_RELIABLE,
                                PathCodec.readInt(entry.frame, 5),
                                entry.frame.copyOfRange(9, entry.frame.size),
                            ),
                        )
                        delivered.update(inner.inner.payload)
                        deliveredBytes += inner.inner.payload.size
                    }
                    buffer.ack(buffer.lastSeq + 1)
                }
            } else {
                break
            }
        }
        assertTrue(sawSilence)
        assertTrue(orphanRounds > 0)
        assertEquals(total, deliveredBytes)
        assertTrue(source.digest().contentEquals(delivered.digest()))
        assertTrue(maxHeld <= ReplayBuffer.CAPACITY)
        assertTrue(maxHeld > ReplayBuffer.BULK_CAPACITY - (2 shl 20))
    }
}
