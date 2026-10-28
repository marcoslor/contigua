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
        assertEquals(0x30, q.pollNow()!![0].toInt() and 0xFF)
    }

    @Test
    fun controlOvertakesDeltas() {
        val q = SendQueue()
        q.enqueueDelta(1, pts(0), bytes(0xD1))
        q.enqueueControl(1, bytes(0xC1))
        q.enqueueDelta(1, pts(1), bytes(0xD2))
        assertEquals(0xC1, q.pollNow()!![0].toInt() and 0xFF)
    }

    @Test
    fun aConfigDropsTheDeltasQueuedBeforeIt() {
        val q = SendQueue()
        q.enqueueDelta(1, pts(0), bytes(0xD1))
        q.enqueueDelta(1, pts(1), bytes(0xD2))
        q.enqueueControl(1, bytes(0xC1)) // new size: the old-size deltas are stale
        q.enqueueDelta(1, pts(2), bytes(0xD3))
        assertEquals(0xC1, q.pollNow()!![0].toInt() and 0xFF)
        assertEquals(0xD3, q.pollNow()!![0].toInt() and 0xFF)
        assertNull(q.pollNow())
    }

    @Test
    fun aConfigLeavesOtherStreamsDeltasAlone() {
        val q = SendQueue()
        q.enqueueDelta(2, pts(0), bytes(0xE1))
        q.enqueueDelta(1, pts(0), bytes(0xD1))
        q.enqueueControl(1, bytes(0xC1))
        assertEquals(0xC1, q.pollNow()!![0].toInt() and 0xFF)
        assertEquals(0xE1, q.pollNow()!![0].toInt() and 0xFF)
        assertNull(q.pollNow())
    }

    @Test
    fun jsonOvertakesControl() {
        val q = SendQueue()
        q.enqueueControl(1, bytes(0xC1))
        q.enqueueJson(bytes(0x30))
        assertEquals(0x30, q.pollNow()!![0].toInt() and 0xFF)
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
        assertEquals(0xC1, q.pollNow()!![0].toInt() and 0xFF)
        q.enqueueDelta(1, pts(3), ByteArray(10))
        assertEquals(10, q.pollNow()!!.size)
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
        assertEquals(10, q.pollNow()!!.size)
    }

    @Test
    fun rotatesBetweenStreams() {
        val q = SendQueue()
        q.enqueueDelta(1, pts(0), bytes(0xA1))
        q.enqueueDelta(2, pts(0), bytes(0xB1))
        q.enqueueDelta(1, pts(1), bytes(0xA2))
        assertArrayEquals(bytes(0xA1), q.pollNow())
        assertArrayEquals(bytes(0xB1), q.pollNow())
        assertArrayEquals(bytes(0xA2), q.pollNow())
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
        assertEquals(0xC1, q.pollNow()!![0].toInt() and 0xFF)
        assertEquals(0xA1, q.pollNow()!![0].toInt() and 0xFF)
        assertEquals(0xA2, q.pollNow()!![0].toInt() and 0xFF)
        assertEquals(0xD1, q.pollNow()!![0].toInt() and 0xFF)
    }

    @Test
    fun audioDropsOldestBeyondBudget() {
        val q = SendQueue(maxAudioBytes = 10)
        q.enqueueAudio(bytes(1, 2, 3, 4, 5, 6))
        q.enqueueAudio(bytes(7, 8, 9, 10, 11, 12))
        // Oldest dropped first; newest survives.
        assertEquals(6, q.pollNow()!!.size)
        assertNull(q.pollNow())
    }

    @Test
    fun queuedBytesCountDeltasAndTheStreamsControlFrames() {
        val q = SendQueue()
        // Control first: a keyframe discards the deltas queued before it.
        q.enqueueControl(1, ByteArray(5))
        q.enqueueControl(2, ByteArray(7))
        q.enqueueJson(bytes(0x30)) // stream 0: not a stream's video
        q.enqueueDelta(1, 0L, ByteArray(10))
        assertEquals(15, q.queuedBytes(1))
        assertEquals(7, q.queuedBytes(2))
        assertEquals(0, q.queuedBytes(3))
        q.pollNow() // the JSON
        q.pollNow() // stream 1's control
        assertEquals(10, q.queuedBytes(1))
        q.pollNow() // stream 2's control
        assertEquals(10, q.queuedBytes(1))
        q.pollNow() // the delta
        assertEquals(0, q.queuedBytes(1))
    }

    @Test
    fun aLatchedStreamSaysSoUntilAKeyframe() {
        val q = SendQueue(maxDeltaBytesPerStream = 10)
        q.enqueueDelta(1, 0L, ByteArray(6))
        q.enqueueDelta(1, 1_000L, ByteArray(6)) // over the cap: the stream is held back
        assertTrue(q.isDropping(1))
        assertTrue(!q.isDropping(2))
        q.enqueueControl(1, bytes(0xC1))
        assertTrue(!q.isDropping(1))
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
        assertEquals(0x30, q.pollNow()!![0].toInt() and 0xFF)
    }
}
