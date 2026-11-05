package dev.pocketdeck.server

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
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
