package dev.pocketdeck.server

import dev.pocketdeck.server.StreamCongestion.Action
import dev.pocketdeck.server.StreamCongestion.Event
import dev.pocketdeck.server.StreamCongestion.State
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Transitions of the stream congestion machine (StreamCongestion.kt). The bug
 * it fixes is one of the transitions: a drop must never request a keyframe, and
 * one episode must never cost more than one repair.
 */
class StreamCongestionTest {

    private fun machine() = StreamCongestion()

    private val repair = listOf(Action.LOWER_BITRATE, Action.REQUEST_KEYFRAME)

    @Test
    fun aDropOnlyStartsAnEpisode() {
        val m = machine()
        assertEquals(emptyList<Action>(), m.onEvent(Event.Drop(1_000)))
        assertEquals(State.DRAINING, m.state)
    }

    @Test
    fun aDrainedQueueTakesOneStepAndOneKeyframe() {
        val m = machine()
        m.onEvent(Event.Drop(1_000))
        assertEquals(repair, m.onEvent(Event.Drained(1_050, stalled = false)))
        assertEquals(State.RECOVERING, m.state)
    }

    @Test
    fun dropsWhileDrainingAreTheSameEpisode() {
        val m = machine()
        m.onEvent(Event.Drop(1_000))
        // The field loop: a drop every ~300 ms. None of them may step or repair.
        assertEquals(emptyList<Action>(), m.onEvent(Event.Drop(1_300)))
        assertEquals(emptyList<Action>(), m.onEvent(Event.Drop(1_600)))
        assertEquals(State.DRAINING, m.state)
        // The episode's drop count is for the log line when it ends.
        assertEquals(3, m.dropsInEpisode)
    }

    @Test
    fun dropsAfterTheRepairWaitForTheInterval() {
        val m = machine()
        m.onEvent(Event.Drop(1_000))
        m.onEvent(Event.Drained(1_050, stalled = false))
        // The keyframe's own backlog overflows: same episode.
        assertEquals(emptyList<Action>(), m.onEvent(Event.Drop(1_300)))
        assertEquals(State.RECOVERING, m.state)
        // A full second after the repair, a drop may open the next cycle.
        assertEquals(emptyList<Action>(), m.onEvent(Event.Drop(2_100)))
        assertEquals(State.DRAINING, m.state)
    }

    @Test
    fun theRepairIsBoundedWhenTheQueueNeverEmpties() {
        val m = machine()
        m.onEvent(Event.Drop(1_000))
        assertEquals(emptyList<Action>(), m.onEvent(Event.Tick(1_500)))
        assertEquals(State.DRAINING, m.state)
        assertEquals(repair, m.onEvent(Event.Tick(2_000)))
    }

    @Test
    fun aQueueThatStaysDrainedReturnsToFlowing() {
        val m = machine()
        m.onEvent(Event.Drop(1_000))
        m.onEvent(Event.Drained(1_050, stalled = false))
        assertEquals(emptyList<Action>(), m.onEvent(Event.Drained(1_500, stalled = false)))
        assertEquals(State.RECOVERING, m.state)
        assertEquals(emptyList<Action>(), m.onEvent(Event.Drained(2_100, stalled = false)))
        assertEquals(State.FLOWING, m.state)
    }

    @Test
    fun aQueueThatStaysLatchedRearmsInsteadOfFreezing() {
        val m = machine()
        m.onEvent(Event.Drop(1_000))
        m.onEvent(Event.Drained(1_050, stalled = false))
        // The reader is still behind: the deltas are held back and the queue is
        // empty, so reporting "flowing" would freeze the picture forever.
        assertEquals(emptyList<Action>(), m.onEvent(Event.Drained(2_100, stalled = true)))
        assertEquals(State.DRAINING, m.state)
        // The next drain takes the next repair.
        assertEquals(repair, m.onEvent(Event.Drained(2_150, stalled = true)))
    }

    @Test
    fun aTickAfterTheIntervalRearmsWhenTheQueueNeverEmpties() {
        val m = machine()
        m.onEvent(Event.Drop(1_000))
        m.onEvent(Event.Drained(1_050, stalled = false))
        assertEquals(emptyList<Action>(), m.onEvent(Event.Tick(1_500)))
        assertEquals(State.RECOVERING, m.state)
        assertEquals(emptyList<Action>(), m.onEvent(Event.Tick(2_100)))
        assertEquals(State.DRAINING, m.state)
    }

    @Test
    fun aHealthyStreamIgnoresTicksAndDrains() {
        val m = machine()
        assertEquals(emptyList<Action>(), m.onEvent(Event.Tick(1_000)))
        assertEquals(emptyList<Action>(), m.onEvent(Event.Drained(1_100, stalled = true)))
        assertEquals(State.FLOWING, m.state)
    }

    @Test
    fun threeSecondsOfAStalledReaderCostAtMostFourRepairs() {
        val m = machine()
        val windowMs = 3_000L
        var steps = 0
        var keys = 0
        var t = 0L
        // Drops every 300 ms (the field shape) plus a 100 ms tick, for 3 s.
        while (t <= windowMs) {
            val actions = m.onEvent(Event.Drop(t))
            // While the machine holds the episode the drop gives nothing back.
            assertTrue(actions.isEmpty())
            t += 300
            for (k in 0 until 3) {
                val tick = m.onEvent(if (k == 0) Event.Drained(t, stalled = true) else Event.Tick(t))
                steps += tick.count { it == Action.LOWER_BITRATE }
                keys += tick.count { it == Action.REQUEST_KEYFRAME }
                t += 100
            }
        }
        assertEquals("one step per repair", keys, steps)
        val maxRepairs = 1 + (windowMs / StreamCongestion.REPAIR_INTERVAL_MS).toInt()
        assertTrue("repairs in ${windowMs}ms: $keys (at most $maxRepairs)", keys <= maxRepairs)
        // The field log had one per drop: ~10 in 3 s.
        assertTrue("a repair per drop would be ~10 in ${windowMs}ms", keys < 10)
    }
}
