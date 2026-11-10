package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The relight's one transition (SM-P-3): every stage/event pair, including the
 * events a stage must ignore. A press only matters while the panel-off's
 * re-applies run; there it hands the panel back once (ISS-24).
 */
class PanelRelightTest {

    private fun state(stage: RelightStage?, sinceMs: Long = 1_000L) =
        RelightState(stage = stage, sinceMs = sinceMs)

    private fun step(state: RelightState, event: RelightEvent) = relightStep(state, event)

    private fun assertIgnored(state: RelightState, event: RelightEvent) {
        val result = step(state, event)
        assertEquals("$event must not change the state", state, result.state)
        assertTrue("$event must return no action", result.actions.isEmpty())
    }

    @Test
    fun `start begins a relight in every stage`() {
        for (stage in listOf(null, RelightStage.WAKE_ISSUED, RelightStage.WAKE_RETURNED, RelightStage.PANEL_OFF)) {
            val result = step(
                state(stage, sinceMs = 1_000L).copy(pressAtMs = 2_000L, stoppedAtMs = 3_000L),
                RelightEvent.Start(nowMs = 5_000L),
            )
            assertEquals(RelightStage.WAKE_ISSUED, result.state.stage)
            assertEquals(5_000L, result.state.sinceMs)
            assertNull("a new relight clears a press from the last one", result.state.pressAtMs)
            assertNull("a new relight clears a stop from the last one", result.state.stoppedAtMs)
            assertTrue(result.actions.isEmpty())
        }
    }

    @Test
    fun `wakeReturned names the wake's return only after it was issued`() {
        val result = step(state(RelightStage.WAKE_ISSUED), RelightEvent.WakeReturned(nowMs = 2_000L))
        assertEquals(RelightStage.WAKE_RETURNED, result.state.stage)
        assertEquals(2_000L, result.state.sinceMs)
        assertTrue(result.actions.isEmpty())
    }

    @Test
    fun `wakeReturned is ignored in every other stage`() {
        for (stage in listOf(null, RelightStage.WAKE_RETURNED, RelightStage.PANEL_OFF)) {
            assertIgnored(state(stage), RelightEvent.WakeReturned(nowMs = 2_000L))
        }
    }

    @Test
    fun `panelOffStarted runs the panel-off after the wake`() {
        for (stage in listOf(RelightStage.WAKE_ISSUED, RelightStage.WAKE_RETURNED)) {
            val result = step(state(stage), RelightEvent.PanelOffStarted(nowMs = 2_000L))
            assertEquals(RelightStage.PANEL_OFF, result.state.stage)
            assertEquals(2_000L, result.state.sinceMs)
            assertTrue(result.actions.isEmpty())
        }
    }

    @Test
    fun `panelOffStarted is ignored in every other stage`() {
        for (stage in listOf(null, RelightStage.PANEL_OFF)) {
            assertIgnored(state(stage), RelightEvent.PanelOffStarted(nowMs = 2_000L))
        }
    }

    @Test
    fun `a press during the panel-off hands the panel back once`() {
        val result = step(state(RelightStage.PANEL_OFF), RelightEvent.Press(nowMs = 2_500L))
        assertEquals(RelightStage.PANEL_OFF, result.state.stage)
        assertEquals(2_500L, result.state.pressAtMs)
        assertEquals(
            "the press is the person's: hand back and stop the re-applies (ISS-24)",
            listOf(RelightAction.HandBack, RelightAction.StopReapplies),
            result.actions,
        )
    }

    @Test
    fun `a second press during the same panel-off hands back nothing`() {
        val first = step(state(RelightStage.PANEL_OFF), RelightEvent.Press(nowMs = 2_500L))
        assertIgnored(first.state, RelightEvent.Press(nowMs = 2_600L))
    }

    @Test
    fun `a press 2 s into the panel-off hands back while its re-applies run`() {
        // The runtime sequence in the field: the lock press opened the relight,
        // its wake returned, the panel-off's re-applies are running, and the
        // person presses power 2 s in. One hand back, and the loop must stop.
        val relight = PanelRelight()
        relight.start(1_000L)
        relight.wakeReturned(1_003L)
        relight.panelOffStarted(1_003L)
        assertEquals(
            listOf(RelightAction.HandBack, RelightAction.StopReapplies),
            relight.press(3_000L),
        )
        assertEquals("one press, one hand back", emptyList<RelightAction>(), relight.press(3_050L))
    }

    @Test
    fun `a press before the panel-off is ignored`() {
        for (stage in listOf(null, RelightStage.WAKE_ISSUED, RelightStage.WAKE_RETURNED)) {
            assertIgnored(state(stage), RelightEvent.Press(nowMs = 2_500L))
        }
    }

    @Test
    fun `a stop during every relight stage ends it`() {
        for (stage in RelightStage.entries) {
            val result = step(state(stage), RelightEvent.StreamsStopped(nowMs = 2_500L))
            assertNull(result.state.stage)
            assertEquals(2_500L, result.state.stoppedAtMs)
            assertEquals(listOf(RelightAction.StopReapplies), result.actions)
        }
    }

    @Test
    fun `a stop with no relight changes nothing`() {
        assertIgnored(state(null), RelightEvent.StreamsStopped(nowMs = 2_500L))
    }

    @Test
    fun `done returns the machine to idle from every stage`() {
        for (stage in RelightStage.entries) {
            val result = step(state(stage).copy(pressAtMs = 2_500L, stoppedAtMs = 3_000L), RelightEvent.Done(nowMs = 4_000L))
            assertEquals(RelightState(), result.state)
            assertTrue(result.actions.isEmpty())
        }
    }

    @Test
    fun `done with no relight changes nothing`() {
        assertIgnored(state(null), RelightEvent.Done(nowMs = 4_000L))
    }

    @Test
    fun `the sampler hands back on a falling edge inside the panel-off`() {
        val relight = PanelRelight()
        relight.start(1_000L)
        relight.wakeReturned(1_003L)
        relight.panelOffStarted(1_003L)
        assertEquals("the wake has not landed yet", emptyList<RelightAction>(), relight.sample(1_100L, interactive = false))
        assertEquals("the wake landing is not a press", emptyList<RelightAction>(), relight.sample(1_200L, interactive = true))
        assertEquals("a steady on is not a press", emptyList<RelightAction>(), relight.sample(2_900L, interactive = true))
        assertEquals(
            listOf(RelightAction.HandBack, RelightAction.StopReapplies),
            relight.sample(3_000L, interactive = false),
        )
        assertEquals("one press, one hand back", emptyList<RelightAction>(), relight.sample(3_020L, interactive = false))
        assertEquals("a later wake is not another press", emptyList<RelightAction>(), relight.sample(3_100L, interactive = true))
    }

    @Test
    fun `the sampler samples a press before the panel-off not as a press`() {
        val relight = PanelRelight()
        relight.start(1_000L)
        relight.sample(1_200L, interactive = true)
        assertEquals(
            "the wake's own off edge belongs to the start",
            emptyList<RelightAction>(),
            relight.sample(1_250L, interactive = false),
        )
    }

    @Test
    fun `the holder logs the relight path`() {
        val lines = mutableListOf<String>()
        val relight = PanelRelight { lines.add(it) }
        relight.start(1_000L)
        relight.wakeReturned(1_003L)
        relight.panelOffStarted(1_003L)
        relight.done(3_500L)
        assertEquals(
            listOf(
                "relight: idle --start--> wakeIssued",
                "relight: wakeIssued --wakeReturned--> wakeReturned",
                "relight: wakeReturned --panelOffStarted--> panelOff",
                "relight: panelOff --done--> idle",
            ),
            lines,
        )
    }

    @Test
    fun `the holder drops a late done after a stop`() {
        val relight = PanelRelight()
        relight.start(1_000L)
        relight.panelOffStarted(1_100L)
        assertEquals(listOf(RelightAction.StopReapplies), relight.streamsStopped(1_500L))
        relight.done(1_600L)
        assertNull(relight.stage)
    }
}
