package dev.pocketdeck.server

import dev.pocketdeck.proto.Frames
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class SendQueueTest {

    private fun bytes(vararg v: Int): ByteArray = ByteArray(v.size) { v[it].toByte() }

    /** A normal 60 fps stream: 16.7 ms between frames. */
    private fun pts(i: Int): Long = i * 16_667L

    @Test
    fun jsonOvertakesQueuedDeltas() {
        val q = SendQueue()
        q.enqueueDelta(1, pts(0), bytes(0xD1, 1))
        q.enqueueDelta(1, pts(1), bytes(0xD2, 2))
        q.enqueueJson(bytes(0x30, 3))
        assertEquals(0x30, q.pollNow()!!.bytes[0].toInt() and 0xFF)
    }

    @Test
    fun controlOvertakesDeltas() {
        val q = SendQueue()
        q.enqueueDelta(1, pts(0), bytes(0xD1))
        q.enqueueControl(1, bytes(0xC1))
        q.enqueueDelta(1, pts(1), bytes(0xD2))
        assertEquals(0xC1, q.pollNow()!!.bytes[0].toInt() and 0xFF)
    }

    @Test
    fun aConfigDropsTheDeltasQueuedBeforeIt() {
        val q = SendQueue()
        q.enqueueDelta(1, pts(0), bytes(0xD1))
        q.enqueueDelta(1, pts(1), bytes(0xD2))
        q.enqueueControl(1, bytes(0xC1)) // new size: the old-size deltas are stale
        q.enqueueDelta(1, pts(2), bytes(0xD3))
        assertEquals(0xC1, q.pollNow()!!.bytes[0].toInt() and 0xFF)
        assertEquals(0xD3, q.pollNow()!!.bytes[0].toInt() and 0xFF)
        assertNull(q.pollNow())
    }

    @Test
    fun aConfigLeavesOtherStreamsDeltasAlone() {
        val q = SendQueue()
        q.enqueueDelta(2, pts(0), bytes(0xE1))
        q.enqueueDelta(1, pts(0), bytes(0xD1))
        q.enqueueControl(1, bytes(0xC1))
        assertEquals(0xC1, q.pollNow()!!.bytes[0].toInt() and 0xFF)
        assertEquals(0xE1, q.pollNow()!!.bytes[0].toInt() and 0xFF)
        assertNull(q.pollNow())
    }

    @Test
    fun jsonOvertakesControl() {
        val q = SendQueue()
        q.enqueueControl(1, bytes(0xC1))
        q.enqueueJson(bytes(0x30))
        assertEquals(0x30, q.pollNow()!!.bytes[0].toInt() and 0xFF)
    }

    @Test
    fun dropsDeltasUnderBackpressureUntilKeyframe() {
        val dropped = CopyOnWriteArrayList<Int>()
        val q = SendQueue(maxDeltaBytesPerStream = 100, onDeltaDrop = { dropped.add(it) })
        q.enqueueDelta(1, pts(0), ByteArray(60))
        q.enqueueDelta(1, pts(1), ByteArray(60)) // would exceed the cap -> drop the backlog
        assertEquals(listOf(1), dropped.toList())
        assertNull(q.pollNow()) // the backlog was dropped, nothing pending
        q.enqueueDelta(1, pts(2), ByteArray(10)) // still dropping -> discarded
        assertNull(q.pollNow())
        q.enqueueControl(1, bytes(0xC1)) // keyframe/config clears the drop state
        assertEquals(0xC1, q.pollNow()!!.bytes[0].toInt() and 0xFF)
        q.enqueueDelta(1, pts(3), ByteArray(10))
        assertEquals(10, q.pollNow()!!.bytes.size)
    }

    @Test
    fun deltaDropsAndEpisodesAreCountedAcrossTheWholeDrop() {
        val q = SendQueue(maxDeltaBytesPerStream = 10)
        q.enqueueDelta(1, pts(0), ByteArray(6))
        q.enqueueDelta(1, pts(1), ByteArray(6)) // backlog (1) + this one = 2 drops, 1 episode
        assertEquals(DeltaStats(2, 1, 0), q.takeDeltaStats(1))
        q.enqueueDelta(1, pts(2), ByteArray(6)) // still dropping: counted, no new episode
        assertEquals(DeltaStats(1, 0, 0), q.takeDeltaStats(1))
        assertEquals(DeltaStats(0, 0, 0), q.takeDeltaStats(1))
    }

    /**
     * ISS-40's drop gap: the pts span from the last frame sent before the first
     * discarded delta to the first frame sent after the episode (the keyframe),
     * less one 60 fps interval. It is read from the writer's send order, so a
     * keyframe that is queued but not yet written does not count yet.
     */
    @Test
    fun oneDropEpisodeMeasuresThePtsGapToTheFirstFrameSentAfterIt() {
        val q = SendQueue(maxDeltaBytesPerStream = 10)
        q.enqueueDelta(1, 0L, ByteArray(6))
        assertEquals(6, q.pollNow()!!.bytes.size) // sent at pts 0
        q.enqueueDelta(1, 16_667L, ByteArray(6)) // queued
        q.enqueueDelta(1, 33_334L, ByteArray(6)) // over the byte cap: the episode starts
        q.enqueueControl(1, bytes(0xC1), 500_000L) // the keyframe that ends it
        assertEquals(0xC1, q.pollNow()!!.bytes[0].toInt() and 0xFF)
        // 500_000 - 0 - 16_667 µs = 483 ms; the queued frame and the trigger were discarded.
        assertEquals(DeltaStats(2, 1, 483), q.takeDeltaStats(1))
    }

    @Test
    fun twoDropEpisodesAddTheirGaps() {
        val q = SendQueue(maxDeltaBytesPerStream = 10)
        q.enqueueDelta(1, 0L, ByteArray(6))
        q.pollNow()
        q.enqueueDelta(1, 16_667L, ByteArray(6))
        q.enqueueDelta(1, 33_334L, ByteArray(6)) // episode 1
        q.enqueueControl(1, bytes(0xC1), 500_000L)
        q.pollNow() // 483 ms
        q.enqueueDelta(1, 520_000L, ByteArray(6))
        q.pollNow()
        q.enqueueDelta(1, 536_667L, ByteArray(6))
        q.enqueueDelta(1, 553_334L, ByteArray(6)) // episode 2
        q.enqueueControl(1, bytes(0xC2), 1_000_000L)
        q.pollNow() // 1_000_000 - 520_000 - 16_667 = 463 ms
        assertEquals(DeltaStats(4, 2, 946), q.takeDeltaStats(1))
    }

    @Test
    fun anEpisodeStillOpenAtASnapshotIsCountedOnceWhenItCloses() {
        val q = SendQueue(maxDeltaBytesPerStream = 10)
        q.enqueueDelta(1, 0L, ByteArray(6))
        q.pollNow()
        q.enqueueDelta(1, 16_667L, ByteArray(6))
        q.enqueueDelta(1, 33_334L, ByteArray(6)) // the episode is open
        assertEquals(DeltaStats(2, 1, 0), q.takeDeltaStats(1))
        // It closes later: the gap lands in the next snapshot, exactly once.
        q.enqueueControl(1, bytes(0xC1), 500_000L)
        q.pollNow()
        assertEquals(DeltaStats(0, 0, 483), q.takeDeltaStats(1))
        assertEquals(DeltaStats(0, 0, 0), q.takeDeltaStats(1))
    }

    @Test
    fun deltasCarryTheirEnqueueClockAndStream() {
        val q = SendQueue(nowUs = { 1_234_567L })
        q.enqueueDelta(7, pts(0), ByteArray(4))
        val entry = q.pollNow()!!
        assertEquals(7, entry.stream)
        assertEquals(1_234_567L, entry.enqueuedUs)
    }

    @Test
    fun dropsWhenTheQueuedVideoIsOlderThanTheBudget() {
        val dropped = CopyOnWriteArrayList<Int>()
        val q = SendQueue(onDeltaDrop = { dropped.add(it) })
        q.enqueueDelta(1, 0L, ByteArray(10))
        q.enqueueDelta(1, 100_000L, ByteArray(10)) // 100 ms queued: fine
        assertEquals(0, dropped.size)
        q.enqueueDelta(1, 400_000L, ByteArray(10)) // 400 ms of queued video: drop
        assertEquals(listOf(1), dropped.toList())
        assertNull(q.pollNow())
    }

    @Test
    fun aDrainedQueueRestartsTheDurationClock() {
        val q = SendQueue()
        q.enqueueDelta(1, 0L, ByteArray(10))
        q.pollNow()
        // The old frame is gone: a late frame must not inherit its pts.
        q.enqueueDelta(1, 10_000_000L, ByteArray(10))
        assertEquals(10, q.pollNow()!!.bytes.size)
    }

    @Test
    fun rotatesBetweenStreams() {
        val q = SendQueue()
        q.enqueueDelta(1, pts(0), bytes(0xA1))
        q.enqueueDelta(2, pts(0), bytes(0xB1))
        q.enqueueDelta(1, pts(1), bytes(0xA2))
        assertArrayEquals(bytes(0xA1), q.pollNow()!!.bytes)
        assertArrayEquals(bytes(0xB1), q.pollNow()!!.bytes)
        assertArrayEquals(bytes(0xA2), q.pollNow()!!.bytes)
        assertNull(q.pollNow())
    }

    // --- R5/R7: VIDEO_CHUNK fragment order in the delta lane ---------------

    /** A framed VIDEO_FRAME the queue splits into VIDEO_CHUNKs. */
    private fun chunkedFrame(stream: Int, ptsUs: Long, dataBytes: Int): ByteArray {
        val payload = ByteBuffer.allocate(9 + dataBytes).order(ByteOrder.BIG_ENDIAN)
        payload.putLong(ptsUs)
        payload.put(0.toByte())
        payload.put(ByteArray(dataBytes) { (it * 31 % 251).toByte() })
        return Frames.encode(Frames.TYPE_VIDEO_FRAME, stream, payload.array())
    }

    /** A framed AUDIO_FRAME, as the session hands it to the queue. */
    private fun audioFrame(ptsUs: Long): ByteArray {
        val payload = ByteBuffer.allocate(8 + 200).order(ByteOrder.BIG_ENDIAN)
        payload.putLong(ptsUs)
        payload.put(ByteArray(200) { 7 })
        return Frames.encode(Frames.TYPE_AUDIO_FRAME, 0, payload.array())
    }

    private data class WireChunk(val stream: Int, val ptsUs: Long, val index: Int, val count: Int)

    private fun wireChunk(entry: SendQueue.Entry): WireChunk {
        val bytes = entry.bytes
        assertEquals("expected a VIDEO_CHUNK", Frames.TYPE_VIDEO_CHUNK, bytes[4].toInt() and 0xFF)
        val bb = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
        return WireChunk(bb.getInt(5), bb.getLong(9),
                         bb.getShort(18).toInt() and 0xFFFF,
                         bb.getShort(20).toInt() and 0xFFFF)
    }

    /**
     * R5: with a backlog of three deltas, a partly sent frame keeps the head
     * of its lane. The wire is D1 c0..cN, D2 c0.., D3 c0.., never D1 c0, D2,
     * D3, D1 c1; audio still goes between two fragments.
     */
    @Test
    fun aPartlySentChunkedDeltaKeepsTheHeadOfItsLane() {
        val q = SendQueue().also { it.videoChunks = true }
        q.enqueueDelta(1, 0L, chunkedFrame(1, 0L, 40 * 1024))
        q.enqueueDelta(1, 20_000L, chunkedFrame(1, 20_000L, 40 * 1024))
        q.enqueueDelta(1, 40_000L, chunkedFrame(1, 40_000L, 40 * 1024))
        val wire = ArrayList<WireChunk>()
        // One audio packet every 20 ms: the writer drains it before the next
        // video entry, so it lands between two fragments of the frame in flight.
        repeat(9) { tick ->
            q.enqueueAudio(audioFrame(tick * 20_000L), tick * 20_000L)
            assertEquals(Frames.TYPE_AUDIO_FRAME, q.pollNow()!!.bytes[4].toInt() and 0xFF)
            wire.add(wireChunk(q.pollNow()!!))
        }
        assertEquals(listOf(0L, 0L, 0L, 20_000L, 20_000L, 20_000L, 40_000L, 40_000L, 40_000L),
                     wire.map { it.ptsUs })
        assertEquals(listOf(0, 1, 2, 0, 1, 2, 0, 1, 2), wire.map { it.index })
        assertTrue(wire.all { it.stream == 1 && it.count == 3 })
        assertNull(q.pollNow())
    }

    /**
     * R5: the keyframe lane holds at most one keyframe per stream, so its
     * rotation may interleave the two streams' fragments but never one
     * stream's own c1 before its c0.
     */
    @Test
    fun twoStreamsKeyframesRotateAcrossStreamsAndStayInOrderPerStream() {
        val q = SendQueue().also { it.videoChunks = true }
        q.enqueueControl(1, chunkedFrame(1, 0L, 100 * 1024), ptsUs = 0L)
        q.enqueueControl(2, chunkedFrame(2, 0L, 100 * 1024), ptsUs = 0L)
        val wire = ArrayList<WireChunk>()
        while (true) {
            val entry = q.pollNow() ?: break
            wire.add(wireChunk(entry))
        }
        assertEquals(14, wire.size)
        wire.groupBy { it.stream }.forEach { (stream, chunks) ->
            assertEquals("stream $stream fragment order",
                         (0 until 7).toList(), chunks.map { it.index })
        }
        assertEquals(List(7) { listOf(1, 2) }.flatten(), wire.map { it.stream })
    }

    /**
     * R7: a new control frame drops the stream's queued deltas, and a keyframe
     * remainder that was partly sent is one of them: only c0 of the old frame
     * is on the wire, then the new keyframe's fragments in order.
     */
    @Test
    fun aNewControlFrameReplacesTheOlderKeyframesRemainder() {
        val q = SendQueue().also { it.videoChunks = true }
        q.enqueueControl(1, chunkedFrame(1, 0L, 100 * 1024), ptsUs = 0L)
        assertEquals(0, wireChunk(q.pollNow()!!).index)
        q.enqueueControl(1, chunkedFrame(1, 1_000_000L, 50 * 1024), ptsUs = 1_000_000L)
        val wire = ArrayList<WireChunk>()
        while (true) {
            val entry = q.pollNow() ?: break
            wire.add(wireChunk(entry))
        }
        assertTrue("no fragment of the replaced keyframe", wire.all { it.ptsUs == 1_000_000L })
        assertEquals((0 until 4).toList(), wire.map { it.index })
        assertNull(q.pollNow())
    }

    /**
     * R7: a drop episode discards every delta, including the remaining
     * fragments of a frame that is already partly on the wire, and the lane
     * stays closed until the keyframe.
     */
    @Test
    fun aDropEpisodeDiscardsThePartlySentDeltaAndEveryLaterOne() {
        val q = SendQueue().also { it.videoChunks = true }
        q.enqueueDelta(1, 0L, chunkedFrame(1, 0L, 120 * 1024))
        q.enqueueDelta(1, 20_000L, chunkedFrame(1, 20_000L, 100 * 1024))
        assertEquals(0, wireChunk(q.pollNow()!!).index)
        // The third frame is over the 256 KiB budget: the episode starts.
        q.enqueueDelta(1, 40_000L, chunkedFrame(1, 40_000L, 100 * 1024))
        assertEquals(DeltaStats(3, 1, 0), q.takeDeltaStats(1))
        assertNull(q.pollNow())
        // Still dropping: every later delta waits for the keyframe.
        q.enqueueDelta(1, 60_000L, chunkedFrame(1, 60_000L, 20 * 1024))
        assertNull(q.pollNow())
        q.enqueueControl(1, chunkedFrame(1, 80_000L, 40 * 1024), ptsUs = 80_000L)
        val key = ArrayList<WireChunk>()
        while (true) {
            val entry = q.pollNow() ?: break
            key.add(wireChunk(entry))
        }
        assertTrue("only the keyframe's fragments", key.all { it.ptsUs == 80_000L })
        assertEquals((0 until 3).toList(), key.map { it.index })
        q.enqueueDelta(1, 100_000L, chunkedFrame(1, 100_000L, 40 * 1024))
        val next = ArrayList<WireChunk>()
        while (true) {
            val entry = q.pollNow() ?: break
            next.add(wireChunk(entry))
        }
        assertTrue("the stream flows again", next.all { it.ptsUs == 100_000L })
        assertEquals((0 until 3).toList(), next.map { it.index })
    }

    @Test
    fun closeUnblocksPollWithNull() {
        val q = SendQueue()
        q.close()
        assertNull(q.poll())
    }

    @Test
    fun audioOvertakesDeltasButNotControl() {
        val q = SendQueue()
        q.enqueueDelta(2, pts(0), bytes(0xD1))
        q.enqueueAudio(bytes(0xA1))
        q.enqueueControl(1, bytes(0xC1))
        q.enqueueAudio(bytes(0xA2))
        assertEquals(0xC1, q.pollNow()!!.bytes[0].toInt() and 0xFF)
        assertEquals(0xA1, q.pollNow()!!.bytes[0].toInt() and 0xFF)
        assertEquals(0xA2, q.pollNow()!!.bytes[0].toInt() and 0xFF)
        assertEquals(0xD1, q.pollNow()!!.bytes[0].toInt() and 0xFF)
    }

    @Test
    fun audioDropsOldestBeyondBudget() {
        val q = SendQueue(maxAudioBytes = 10)
        q.enqueueAudio(bytes(1, 2, 3, 4, 5, 6))
        q.enqueueAudio(bytes(7, 8, 9, 10, 11, 12))
        // Oldest dropped first; newest survives.
        assertEquals(6, q.pollNow()!!.bytes.size)
        assertNull(q.pollNow())
    }

    /**
     * B2: the drop callback reaches the display (a keyframe request, a
     * backpressure note), and a display busy with another window's open can
     * take seconds. It must never run with the queue's lock held: while it is
     * blocked, the queue must still take work from the writer and the other
     * producers (JSON first, then frames).
     */
    @Test
    fun theDropCallbackRunsWithoutTheQueueLock() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val q = SendQueue(maxDeltaBytesPerStream = 10, onDeltaDrop = {
            entered.countDown()
            release.await(10, TimeUnit.SECONDS)
        })
        q.enqueueDelta(1, 0L, ByteArray(6))
        val dropper = Thread { q.enqueueDelta(1, 1_000L, ByteArray(6)) } // over the cap
        dropper.isDaemon = true
        dropper.start()
        assertTrue("the drop callback ran", entered.await(2, TimeUnit.SECONDS))

        var enqueued = false
        val json = Thread { q.enqueueJson(bytes(0x30, 1)); enqueued = true }
        json.isDaemon = true
        json.start()
        json.join(500)
        val freeWhileDropping = enqueued
        release.countDown()
        runCatching { dropper.join(2_000) }
        runCatching { json.join(2_000) }
        assertTrue("enqueueJson waited for the drop callback: the queue lock was held",
                   freeWhileDropping)
        assertEquals(0x30, q.pollNow()!!.bytes[0].toInt() and 0xFF)
    }
}
