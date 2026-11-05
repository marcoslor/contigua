package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Q1's safety net: a suspend never outlives its cause. The session's existing
 * ticker feeds `Tick`; one 1000 ms after the suspend began resumes whatever the
 * backlog says, and a flowing or fallback-dropped stream ignores it.
 */
class SendQueueTickTest {

    private val applied = CopyOnWriteArrayList<Boolean>()
    private val lines = CopyOnWriteArrayList<String>()
    private lateinit var queue: SendQueue

    private fun queue(maxBytes: Int = 100) = SendQueue(
        maxDeltaBytesPerStream = maxBytes,
        policyFor = {
            QueuePolicy(StreamStrategy.Overflow.Suspend, maxBytes, 10_000_000)
        },
        onSuspendChanged = { stream -> applied.add(queue.isSuspended(stream)) },
        log = { lines.add(it) },
    ).also { queue = it }

    private fun suspend(queue: SendQueue) {
        queue.enqueueDelta(1, 0, ByteArray(60))
        queue.enqueueDelta(1, 16_667, ByteArray(60))
        assertEquals(listOf(true), applied)
        assertTrue(queue.isSuspended(1))
    }

    @Test
    fun `a tick before the timeout leaves a full suspended queue suspended`() {
        val q = queue()
        suspend(q)
        q.tick(500)
        assertTrue(q.isSuspended(1))
        assertEquals(listOf(true), applied)
        assertTrue(lines.none { it.contains("suspend timeout") })
    }

    @Test
    fun `a tick one second after the suspend began resumes it whatever the backlog`() {
        val q = queue()
        suspend(q)
        q.tick(1_001)
        assertFalse(q.isSuspended(1))
        assertEquals(listOf(true, false), applied)
        assertTrue(lines.contains("stream 1 overflow: suspend timeout"))
        assertTrue(lines.contains("stream 1 overflow: suspended --timeout--> flowing"))
    }

    @Test
    fun `ticks are ignored while flowing and after a fallback drop`() {
        val flowing = queue()
        flowing.enqueueDelta(1, 0, ByteArray(10))
        flowing.tick(5_000)
        assertFalse(flowing.isSuspended(1))
        assertTrue(applied.isEmpty())

        applied.clear()
        lines.clear()
        val dropped = queue()
        for (index in 0 until 7) dropped.enqueueDelta(1, index * 16_667L, ByteArray(60))
        assertFalse(dropped.isSuspended(1))
        val before = applied.toList()
        dropped.tick(10_000)
        assertEquals(before, applied)
        assertTrue(lines.none { it.contains("suspend timeout") })
    }
}
