package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Test

/** Q1: the overflow machine's states, its ignored events and its actions. */
class OverflowMachineTest {

    @Test
    fun `a full queue suspends the encoder and lowers the bitrate`() {
        val step = overflowStep(OverflowState.Flowing, OverflowEvent.Pressure(hardCeiling = false))
        assertEquals(OverflowState.Suspended, step.state)
        assertEquals(
            listOf(OverflowAction.SuspendEncoder, OverflowAction.LowerBitrate),
            step.actions,
        )
    }

    @Test
    fun `a queue past four times the budget falls back to today's drop`() {
        val step = overflowStep(OverflowState.Flowing, OverflowEvent.Pressure(hardCeiling = true))
        assertEquals(OverflowState.FallbackDropped, step.state)
        assertEquals(listOf(OverflowAction.DropAndKeyframe), step.actions)
    }

    @Test
    fun `a suspended stream accepts more pressure without another action`() {
        val step = overflowStep(OverflowState.Suspended, OverflowEvent.Pressure(hardCeiling = false))
        assertEquals(OverflowState.Suspended, step.state)
        assertEquals(emptyList<OverflowAction>(), step.actions)
    }

    @Test
    fun `a suspended stream resumes when drained below half`() {
        val step = overflowStep(OverflowState.Suspended, OverflowEvent.Drained)
        assertEquals(OverflowState.Flowing, step.state)
        assertEquals(listOf(OverflowAction.ResumeEncoder), step.actions)
    }

    @Test
    fun `a control frame resumes a suspended stream`() {
        val step = overflowStep(OverflowState.Suspended, OverflowEvent.Control)
        assertEquals(OverflowState.Flowing, step.state)
        assertEquals(listOf(OverflowAction.ResumeEncoder), step.actions)
    }

    @Test
    fun `the hard ceiling while suspended resumes then drops`() {
        val step = overflowStep(OverflowState.Suspended, OverflowEvent.Pressure(hardCeiling = true))
        assertEquals(OverflowState.FallbackDropped, step.state)
        assertEquals(
            listOf(OverflowAction.ResumeEncoder, OverflowAction.DropAndKeyframe),
            step.actions,
        )
    }

    @Test
    fun `a tick brings a suspended stream back once its backlog is under half`() {
        val step = overflowStep(
            OverflowState.Suspended,
            OverflowEvent.Tick(nowMs = 500, suspendedSinceMs = 0, backlogUnderHalf = true),
        )
        assertEquals(OverflowState.Flowing, step.state)
        assertEquals(listOf(OverflowAction.ResumeEncoder), step.actions)
        assertEquals("tick", step.event)
    }

    @Test
    fun `a tick one second after the suspend began resumes it whatever the backlog`() {
        val step = overflowStep(
            OverflowState.Suspended,
            OverflowEvent.Tick(nowMs = 1_001, suspendedSinceMs = 0, backlogUnderHalf = false),
        )
        assertEquals(OverflowState.Flowing, step.state)
        assertEquals(listOf(OverflowAction.ResumeEncoder), step.actions)
        assertEquals("timeout", step.event)
    }

    @Test
    fun `a tick before the timeout with a full backlog changes nothing`() {
        val step = overflowStep(
            OverflowState.Suspended,
            OverflowEvent.Tick(nowMs = 1_000, suspendedSinceMs = 0, backlogUnderHalf = false),
        )
        assertEquals(OverflowState.Suspended, step.state)
        assertEquals(emptyList<OverflowAction>(), step.actions)
        assertEquals("tick", step.event)
    }

    @Test
    fun `a dropped stream waits for its keyframe, ignoring pressure and draining`() {
        for (event in listOf(
            OverflowEvent.Pressure(hardCeiling = false),
            OverflowEvent.Pressure(hardCeiling = true),
            OverflowEvent.Drained,
            OverflowEvent.Tick(nowMs = 10_000, suspendedSinceMs = 0, backlogUnderHalf = true),
        )) {
            val step = overflowStep(OverflowState.FallbackDropped, event)
            assertEquals(OverflowState.FallbackDropped, step.state)
            assertEquals(emptyList<OverflowAction>(), step.actions)
        }
        val keyframe = overflowStep(OverflowState.FallbackDropped, OverflowEvent.Control)
        assertEquals(OverflowState.Flowing, keyframe.state)
        assertEquals(emptyList<OverflowAction>(), keyframe.actions)
    }

    @Test
    fun `a flowing stream ignores a drain, a control or a tick`() {
        for (event in listOf(
            OverflowEvent.Drained,
            OverflowEvent.Control,
            OverflowEvent.Tick(nowMs = 10_000, suspendedSinceMs = 0, backlogUnderHalf = true),
        )) {
            assertEquals(emptyList<OverflowAction>(),
                overflowStep(OverflowState.Flowing, event).actions)
        }
    }
}
