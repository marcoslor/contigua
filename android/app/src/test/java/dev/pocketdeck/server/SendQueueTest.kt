package dev.pocketdeck.server

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

class SendQueueTest {

    private fun bytes(vararg v: Int): ByteArray = ByteArray(v.size) { v[it].toByte() }

    @Test
    fun jsonOvertakesQueuedDeltas() {
        val q = SendQueue()
        q.enqueueDelta(1, bytes(0xD1, 1))
        q.enqueueDelta(1, bytes(0xD2, 2))
        q.enqueueJson(bytes(0x30, 3))
        assertEquals(0x30, q.pollNow()!![0].toInt() and 0xFF)
    }

    @Test
    fun controlOvertakesDeltas() {
        val q = SendQueue()
        q.enqueueDelta(1, bytes(0xD1))
        q.enqueueControl(1, bytes(0xC1))
        q.enqueueDelta(1, bytes(0xD2))
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
        q.enqueueDelta(1, ByteArray(60))
        q.enqueueDelta(1, ByteArray(60)) // would exceed the cap -> drop the backlog
        assertEquals(listOf(1), dropped.toList())
        assertNull(q.pollNow()) // the backlog was dropped, nothing pending
        q.enqueueDelta(1, ByteArray(10)) // still dropping -> discarded
        assertNull(q.pollNow())
        q.enqueueControl(1, bytes(0xC1)) // keyframe/config clears the drop state
        assertEquals(0xC1, q.pollNow()!![0].toInt() and 0xFF)
        q.enqueueDelta(1, ByteArray(10))
        assertEquals(10, q.pollNow()!!.size)
    }

    @Test
    fun rotatesBetweenStreams() {
        val q = SendQueue()
        q.enqueueDelta(1, bytes(0xA1))
        q.enqueueDelta(2, bytes(0xB1))
        q.enqueueDelta(1, bytes(0xA2))
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
