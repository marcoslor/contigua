package dev.pocketdeck.server

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

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
}
