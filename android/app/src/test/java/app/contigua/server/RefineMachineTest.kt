package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * T1's refinement machine: idle → refining → done, one per still period, and
 * motion or a suspend cancels at once so motion never waits on a refinement.
 */
class RefineMachineTest {

    private val idle = RefineModel(RefineState.Idle)

    @Test
    fun `a still stream raises the bitrate and asks for one sync frame`() {
        val step = refineStep(idle, RefineEvent.Still, nowMs = 1_000)
        assertEquals(RefineState.Refining, step.model.state)
        assertEquals(1_000, step.model.startedMs)
        assertEquals(
            listOf(RefineAction.RaiseBitrate, RefineAction.RequestSync),
            step.actions,
        )
    }

    @Test
    fun `the refined keyframe ends it and restores the target`() {
        val refining = refineStep(idle, RefineEvent.Still, 1_000).model
        val step = refineStep(refining, RefineEvent.Frame(keyframe = true, changed = true), 1_200)
        assertEquals(RefineState.Done, step.model.state)
        assertEquals(listOf(RefineAction.RestoreBitrate), step.actions)
    }

    @Test
    fun `a repeat frame while refining waits`() {
        val refining = refineStep(idle, RefineEvent.Still, 1_000).model
        val step = refineStep(refining, RefineEvent.Frame(keyframe = false, changed = false), 1_400)
        assertEquals(RefineState.Refining, step.model.state)
        assertEquals(emptyList<RefineAction>(), step.actions)
    }

    @Test
    fun `motion while refining cancels and restores at once`() {
        val refining = refineStep(idle, RefineEvent.Still, 1_000).model
        val step = refineStep(refining, RefineEvent.Frame(keyframe = false, changed = true), 1_100)
        assertEquals(RefineState.Idle, step.model.state)
        assertEquals(listOf(RefineAction.RestoreBitrate), step.actions)
    }

    @Test
    fun `a suspend while refining cancels too`() {
        val refining = refineStep(idle, RefineEvent.Still, 1_000).model
        val step = refineStep(refining, RefineEvent.Suspend, 1_100)
        assertEquals(RefineState.Idle, step.model.state)
        assertEquals(listOf(RefineAction.RestoreBitrate), step.actions)
    }

    @Test
    fun `a sync frame that never arrives times out`() {
        val refining = refineStep(idle, RefineEvent.Still, 1_000).model
        assertEquals(RefineState.Refining,
                     refineStep(refining, RefineEvent.Tick(1_999), 1_999).model.state)
        val step = refineStep(refining, RefineEvent.Tick(2_000), 2_000)
        assertEquals(RefineState.Done, step.model.state)
        assertEquals(listOf(RefineAction.RestoreBitrate), step.actions)
    }

    @Test
    fun `one refinement per still period, and motion re-arms it`() {
        var model = refineStep(idle, RefineEvent.Still, 1_000).model
        model = refineStep(model, RefineEvent.Frame(keyframe = true, changed = true), 1_100).model
        assertEquals(RefineState.Done, model.state)
        // Further stills in the same period do nothing.
        val again = refineStep(model, RefineEvent.Still, 2_000)
        assertEquals(RefineState.Done, again.model.state)
        assertEquals(emptyList<RefineAction>(), again.actions)
        // New picture: back to idle, so the next still can refine.
        val motion = refineStep(model, RefineEvent.Frame(keyframe = false, changed = true), 3_000)
        assertEquals(RefineState.Idle, motion.model.state)
        assertEquals(emptyList<RefineAction>(), motion.actions)
        val next = refineStep(motion.model, RefineEvent.Still, 3_400)
        assertEquals(RefineState.Refining, next.model.state)
    }

    @Test
    fun `idle ignores frames, ticks, suspends and close`() {
        for (event in listOf(
            RefineEvent.Frame(keyframe = true, changed = true),
            RefineEvent.Frame(keyframe = false, changed = false),
            RefineEvent.Tick(9_000),
            RefineEvent.Suspend,
            RefineEvent.Close,
        )) {
            val step = refineStep(idle, event)
            assertEquals(RefineState.Idle, step.model.state)
            assertEquals(emptyList<RefineAction>(), step.actions)
        }
    }

    @Test
    fun `close while refining restores before the encoder goes away`() {
        val refining = refineStep(idle, RefineEvent.Still, 1_000).model
        val step = refineStep(refining, RefineEvent.Close, 1_200)
        assertEquals(RefineState.Idle, step.model.state)
        assertEquals(listOf(RefineAction.RestoreBitrate), step.actions)
    }
}
