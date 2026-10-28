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
 * one episode must never cost more than one repair per drained queue.
 *
 * Round 3 added two transitions the reviewer measured (a reader at half the
 * source rate): a repair that has not yet drained may not take the next repair
 * just because an interval passed, and a reader that is still slower than the
 * bitrate floor takes frame-rate steps instead of more bitrate steps.
 */
class StreamCongestionTest {

    private fun machine(step: () -> CongestionStep = { CongestionStep.BITRATE }) = StreamCongestion(available = step)

    private val repair = listOf(Action.LOWER_BITRATE, Action.REQUEST_KEYFRAME)

    private val frameRateRepair = listOf(Action.LOWER_FRAME_RATE, Action.REQUEST_KEYFRAME)

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
    fun theNextRepairWaitsForTheQueuesDrainNotForAnInterval() {
        val m = machine()
        m.onEvent(Event.Drop(1_000))
        m.onEvent(Event.Drained(1_050, stalled = false))
        // The repair keyframe is still going out: the queue refills and stays
        // full. The old machine took the next repair as soon as the interval
        // passed, straight into the backlog its own keyframe created — that is
        // the loop the reviewer measured at a somewhat slow reader.
        assertEquals(emptyList<Action>(), m.onEvent(Event.Drop(1_300)))
        assertEquals(emptyList<Action>(), m.onEvent(Event.Tick(2_100)))
        assertEquals(emptyList<Action>(), m.onEvent(Event.Tick(3_500)))
        assertEquals(State.RECOVERING, m.state)
        // The reader takes the backlog: the queue drains, the deltas are held
        // for a keyframe, and only now may the next step and repair go out.
        assertEquals(repair, m.onEvent(Event.Drained(3_800, stalled = true)))
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
    fun aQueueThatStaysLatchedTakesTheNextStepAfterTheInterval() {
        val m = machine()
        m.onEvent(Event.Drop(1_000))
        m.onEvent(Event.Drained(1_050, stalled = false))
        // The reader is still behind: the deltas are held back and the queue is
        // empty, so reporting "flowing" would freeze the picture forever. The
        // next repair still waits for the interval, and for this drain.
        assertEquals(emptyList<Action>(), m.onEvent(Event.Drained(1_200, stalled = true)))
        assertEquals(State.RECOVERING, m.state)
        assertEquals(repair, m.onEvent(Event.Drained(2_100, stalled = true)))
        assertEquals(State.RECOVERING, m.state)
    }

    @Test
    fun aTickNeverRearmsAfterARepair() {
        val m = machine()
        m.onEvent(Event.Drop(1_000))
        m.onEvent(Event.Drained(1_050, stalled = false))
        // A tick says the queue is still full; that is the repair's own
        // backlog, not a reason to repair again.
        assertEquals(emptyList<Action>(), m.onEvent(Event.Tick(1_500)))
        assertEquals(emptyList<Action>(), m.onEvent(Event.Tick(2_100)))
        assertEquals(emptyList<Action>(), m.onEvent(Event.Tick(9_000)))
        assertEquals(State.RECOVERING, m.state)
    }

    @Test
    fun aHealthyStreamIgnoresTicksAndDrains() {
        val m = machine()
        assertEquals(emptyList<Action>(), m.onEvent(Event.Tick(1_000)))
        assertEquals(emptyList<Action>(), m.onEvent(Event.Drained(1_100, stalled = true)))
        assertEquals(State.FLOWING, m.state)
    }

    @Test
    fun aReaderBelowTheFloorTakesFrameRateStepsInsteadOfBitrateSteps() {
        var step = CongestionStep.BITRATE
        val m = machine { step }
        m.onEvent(Event.Drop(1_000))
        assertEquals(repair, m.onEvent(Event.Drained(1_100, stalled = false)))
        // The bitrate reached its floor and the reader is still behind: the
        // next repair halves the frame rate, so fewer deltas have to fit.
        step = CongestionStep.FRAME_RATE
        assertEquals(frameRateRepair, m.onEvent(Event.Drained(1_900, stalled = true)))
        // The encoder is at its lowest frame rate too: repair the picture, step
        // nothing (nothing is left to give up).
        step = CongestionStep.NONE
        assertEquals(listOf(Action.REQUEST_KEYFRAME), m.onEvent(Event.Drained(3_000, stalled = true)))
    }

    @Test
    fun aRecoveredStreamGivesTheFrameRateBack() {
        var step = CongestionStep.FRAME_RATE
        val m = machine { step }
        m.onEvent(Event.Drop(1_000))
        assertEquals(frameRateRepair, m.onEvent(Event.Drained(1_100, stalled = false)))
        // The reader keeps up: the healthy clock starts at the first drained
        // queue and ends the episode 750 ms later.
        assertEquals(emptyList<Action>(), m.onEvent(Event.Drained(1_200, stalled = false)))
        assertEquals(listOf(Action.RESTORE_FRAME_RATE), m.onEvent(Event.Drained(1_950, stalled = false)))
        assertEquals(State.FLOWING, m.state)
    }

    @Test
    fun aRecoveryThatTookNoFrameRateStepRestoresNothing() {
        val m = machine()
        m.onEvent(Event.Drop(1_000))
        m.onEvent(Event.Drained(1_050, stalled = false))
        m.onEvent(Event.Drained(1_100, stalled = false))
        assertEquals(emptyList<Action>(), m.onEvent(Event.Drained(1_850, stalled = false)))
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
