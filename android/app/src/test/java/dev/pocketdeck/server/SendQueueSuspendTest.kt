package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Q1 in the send queue: with `overflow=suspend` a full queue keeps its deltas,
 * asks for no keyframe, suspends the encoder, resumes below half the budget and
 * only drops at the hard byte ceiling.
 */
class SendQueueSuspendTest {

    private val dropped = CopyOnWriteArrayList<Int>()
    private val overflows = CopyOnWriteArrayList<Int>()
    private val suspends = CopyOnWriteArrayList<Pair<Int, Boolean>>()

    private fun queue(
        maxBytes: Int,
        overflow: StreamStrategy.Overflow = StreamStrategy.Overflow.Suspend,
        maxDurationUs: Long = 250_000L,
    ) = SendQueue(
        maxDeltaBytesPerStream = maxBytes,
        onDeltaDrop = { dropped.add(it) },
        policyFor = { QueuePolicy(overflow, maxBytes, maxDurationUs) },
        onOverflow = { overflows.add(it) },
        onSuspend = { stream, on -> suspends.add(stream to on) },
    )

    private fun bytes(size: Int): ByteArray = ByteArray(size) { it.toByte() }

    private fun pts(i: Int): Long = i * 16_667L

    @Test
    fun `a full queue suspends and keeps every delta below the ceiling`() {
        val q = queue(maxBytes = 100)
        q.enqueueDelta(1, pts(0), bytes(60))
        q.enqueueDelta(1, pts(1), bytes(60))
        assertTrue("no drop below the ceiling", dropped.isEmpty())
        assertEquals(listOf(1), overflows)
        assertEquals(listOf(1 to true), suspends)
        assertEquals(0, q.takeDeltaStats(1).first)
        // Both frames are still there, in order.
        assertEquals(60, q.pollNow()!!.bytes.size)
        assertEquals(60, q.pollNow()!!.bytes.size)
    }

    @Test
    fun `it resumes once the queue is below half the budget`() {
        val q = queue(maxBytes = 100)
        q.enqueueDelta(1, pts(0), bytes(60))
        q.enqueueDelta(1, pts(1), bytes(60))
        q.pollNow() // 60 left: still above half
        assertEquals(listOf(1 to true), suspends)
        q.pollNow() // 0 left
        assertEquals(listOf(1 to true, 1 to false), suspends)
    }

    @Test
    fun `a new control frame resumes a suspended stream`() {
        val q = queue(maxBytes = 100)
        q.enqueueDelta(1, pts(0), bytes(60))
        q.enqueueDelta(1, pts(1), bytes(60))
        q.enqueueControl(1, bytes(4))
        assertEquals(listOf(1 to true, 1 to false), suspends)
        assertEquals(4, q.pollNow()!!.bytes.size)
    }

    @Test
    fun `four times the budget falls back to today's drop and keyframe`() {
        val q = queue(maxBytes = 100)
        for (index in 0 until 7) q.enqueueDelta(1, pts(index), bytes(60))
        // The seventh frame would reach 420 bytes (hard ceiling 400).
        assertEquals(listOf(1), dropped)
        assertEquals(listOf(1 to true, 1 to false), suspends)
        assertEquals(7 to 1, q.takeDeltaStats(1))
        assertTrue("the backlog was discarded", q.pollNow() == null)
    }

    @Test
    fun `the drop policy still drops and requests a keyframe today`() {
        val q = queue(maxBytes = 100, overflow = StreamStrategy.Overflow.Drop)
        q.enqueueDelta(1, pts(0), bytes(60))
        q.enqueueDelta(1, pts(1), bytes(60))
        assertEquals(listOf(1), dropped)
        assertTrue(overflows.isEmpty())
        assertTrue(suspends.isEmpty())
        // The backlog is gone and the stream waits for its keyframe.
        assertTrue(q.pollNow() == null)
        q.enqueueDelta(1, pts(2), bytes(10))
        assertEquals(3 to 1, q.takeDeltaStats(1))
    }

    @Test
    fun `the byte rule scales with queue_ms`() {
        val strategy = StreamStrategy.parse { key ->
            if (key == "queue_ms") "100" else null
        }
        val policy = QueuePolicy.of(strategy, baseBytes = 1000, baseDurationUs = 250_000)
        assertEquals(400, policy.maxBytes)
        assertEquals(100_000L, policy.maxDurationUs)
        assertEquals(1600, policy.hardBytes)
    }

    @Test
    fun `the duration rule uses queue_ms too`() {
        val q = queue(maxBytes = 1_000_000, overflow = StreamStrategy.Overflow.Drop,
                      maxDurationUs = 100_000L)
        // 60 fps: the seventh frame is 100.0 ms after the first.
        for (index in 0 until 6) q.enqueueDelta(1, pts(index), bytes(10))
        assertTrue(dropped.isEmpty())
        q.enqueueDelta(1, pts(6), bytes(10))
        assertEquals(listOf(1), dropped)
        assertEquals(7 to 1, q.takeDeltaStats(1))
    }
}
