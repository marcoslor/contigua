package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The on-demand link stall (ISS-40 round 2): the pure two-state gate, and what
 * a 400 ms pause does to the queue — today's policy drops and asks for a
 * keyframe, while `overflow=suspend` suspends the encoder instead.
 */
class StallGateTest {

    @Test
    fun `an unset stall is off and has no gate`() {
        assertNull(StreamStrategy.DEFAULT.stallGate(stream = 1, startMs = 0))
        val off = StreamStrategy.parse { key -> if (key == "stall_ms") "0" else null }
        assertNull(off.stallGate(stream = 1, startMs = 0))
    }

    @Test
    fun `the pause lasts stall_ms and starts every stall_every_ms`() {
        val gate = StallGate(stream = 1, stallMs = 400, everyMs = 5_000, startMs = 0)
        assertEquals(StallState.Flowing, gate.state)
        assertTrue("before the first period", gate.beforeWrite(4_999).actions.isEmpty())
        val first = gate.beforeWrite(5_000)
        assertEquals(StallState.Stalled, first.state)
        assertEquals(
            listOf(StallAction.LogInjected(1, 400), StallAction.Wait(400)),
            first.actions,
        )
        // Still inside the pause: no second stall starts.
        assertTrue(gate.beforeWrite(5_200).actions.isEmpty())
        assertEquals(StallState.Stalled, gate.state)
        // The pause ends at 400 ms; the next start is a full period from this one.
        assertEquals(StallState.Flowing, gate.beforeWrite(5_400).state)
        assertTrue(gate.beforeWrite(9_999).actions.isEmpty())
        assertEquals(
            listOf(StallAction.LogInjected(1, 400), StallAction.Wait(400)),
            gate.beforeWrite(10_000).actions,
        )
    }

    @Test
    fun `queued deltas overflow today's budget during a 400 ms stall`() {
        val dropped = CopyOnWriteArrayList<Int>()
        val queue = SendQueue(onDeltaDrop = { dropped.add(it) })
        val gate = StallGate(stream = 1, stallMs = 400, everyMs = 5_000, startMs = 0)
        val step = gate.beforeWrite(5_000)
        assertEquals(StallAction.Wait(400), step.actions.filterIsInstance<StallAction.Wait>().single())
        // The writer is asleep for 400 ms; the encoder keeps producing 60 fps.
        for (index in 0 until 25) {
            queue.enqueueDelta(1, index * 16_667L, ByteArray(1_000))
        }
        assertEquals("one keyframe request for the drop episode", listOf(1), dropped)
        val stats = queue.takeDeltaStats(1)
        assertEquals(1, stats.episodes)
        assertTrue("the 250 ms budget was passed: ${stats.dropped}", stats.dropped > 0)
    }

    @Test
    fun `the same stall suspends the encoder under overflow=suspend`() {
        val dropped = CopyOnWriteArrayList<Int>()
        val suspends = CopyOnWriteArrayList<Pair<Int, Boolean>>()
        lateinit var queue: SendQueue
        queue = SendQueue(
            onDeltaDrop = { dropped.add(it) },
            policyFor = {
                QueuePolicy(
                    StreamStrategy.Overflow.Suspend,
                    SendQueue.DEFAULT_MAX_DELTA_BYTES,
                    SendQueue.DEFAULT_MAX_DELTA_DURATION_US,
                )
            },
            onSuspendChanged = { stream -> suspends.add(stream to queue.isSuspended(stream)) },
        )
        val gate = StallGate(stream = 1, stallMs = 400, everyMs = 5_000, startMs = 0)
        gate.beforeWrite(5_000)
        for (index in 0 until 25) {
            queue.enqueueDelta(1, index * 16_667L, ByteArray(1_000))
        }
        assertTrue("the backlog is kept, not dropped", dropped.isEmpty())
        assertEquals(listOf(1 to true), suspends)
        assertEquals(0, queue.takeDeltaStats(1).dropped)
        var held = 0
        while (queue.pollNow() != null) held++
        assertEquals("the queue still holds every delta", 25, held)
    }
}
