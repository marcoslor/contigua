package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The overrun budget's phases: a key frame extends the bytes and the wait; the
 * deltas that arrived behind it keep the credit until they drain.
 */
class QueueBudgetTest {

    @Test
    fun `a queued key frame enters the key frame phase and carries its send time`() {
        val step = budgetStep(BudgetState(), BudgetEvent.KeyQueued(500_000, 30_000_000))
        assertEquals(BudgetPhase.Keyframe, step.state.phase)
        assertEquals(500_000L, step.state.keyBytes)
        // 500 KB at 30 Mbps = 133 ms.
        assertEquals(133_333L, step.state.creditUs)
        assertEquals("key(500000)", step.event)
        assertTrue(step.transition)
    }

    @Test
    fun `a second key frame adds its bytes and keeps the larger credit`() {
        val first = budgetStep(BudgetState(), BudgetEvent.KeyQueued(500_000, 30_000_000)).state
        val second = budgetStep(first, BudgetEvent.KeyQueued(200_000, 30_000_000)).state
        assertEquals(BudgetPhase.Keyframe, second.phase)
        assertEquals(700_000L, second.keyBytes)
        assertEquals(first.creditUs, second.creditUs)
    }

    @Test
    fun `sending the last key frame enters draining and keeps the credit`() {
        val queued = budgetStep(BudgetState(), BudgetEvent.KeyQueued(500_000, 30_000_000)).state
        val sent = budgetStep(queued, BudgetEvent.KeySent(500_000))
        assertEquals(BudgetPhase.Draining, sent.state.phase)
        assertEquals(0L, sent.state.keyBytes)
        assertEquals("its bytes still cover the deltas behind it", 500_000L, sent.state.byteCredit)
        assertEquals(queued.creditUs, sent.state.creditUs)
        assertTrue(sent.transition)
    }

    @Test
    fun `sending one of two key frames stays in the key frame phase`() {
        var state = budgetStep(BudgetState(), BudgetEvent.KeyQueued(500_000, 30_000_000)).state
        state = budgetStep(state, BudgetEvent.KeyQueued(200_000, 30_000_000)).state
        val sent = budgetStep(state, BudgetEvent.KeySent(500_000))
        assertEquals(BudgetPhase.Keyframe, sent.state.phase)
        assertEquals(200_000L, sent.state.keyBytes)
        assertEquals(500_000L, sent.state.byteCredit)
    }

    @Test
    fun `a new key frame keeps the bytes of the one still draining`() {
        var state = budgetStep(BudgetState(), BudgetEvent.KeyQueued(500_000, 30_000_000)).state
        state = budgetStep(state, BudgetEvent.KeySent(500_000)).state
        val again = budgetStep(state, BudgetEvent.KeyQueued(300_000, 30_000_000)).state
        assertEquals(BudgetPhase.Keyframe, again.phase)
        assertEquals(300_000L, again.keyBytes)
        assertEquals("the earlier key's deltas are still draining", 500_000L, again.byteCredit)
    }

    @Test
    fun `draining ends in steady and drops the credit`() {
        var state = budgetStep(BudgetState(), BudgetEvent.KeyQueued(500_000, 30_000_000)).state
        state = budgetStep(state, BudgetEvent.KeySent(500_000)).state
        val drained = budgetStep(state, BudgetEvent.Drained)
        assertEquals(BudgetPhase.Steady, drained.state.phase)
        assertEquals(0L, drained.state.keyBytes)
        assertEquals(0L, drained.state.byteCredit)
        assertEquals(0L, drained.state.creditUs)
        assertTrue(drained.transition)
    }

    @Test
    fun `a drain while a key frame is still queued changes nothing`() {
        val state = budgetStep(BudgetState(), BudgetEvent.KeyQueued(500_000, 30_000_000)).state
        val step = budgetStep(state, BudgetEvent.Drained)
        assertEquals(state, step.state)
        assertFalse(step.transition)
    }

    @Test
    fun `steady ignores a drain and a key frame sent with nothing queued`() {
        assertFalse(budgetStep(BudgetState(), BudgetEvent.Drained).transition)
        assertFalse(budgetStep(BudgetState(), BudgetEvent.KeySent(10)).transition)
    }

    @Test
    fun `a new key frame after draining re-enters the key frame phase`() {
        var state = budgetStep(BudgetState(), BudgetEvent.KeyQueued(500_000, 30_000_000)).state
        state = budgetStep(state, BudgetEvent.KeySent(500_000)).state
        val again = budgetStep(state, BudgetEvent.KeyQueued(300_000, 30_000_000)).state
        assertEquals(BudgetPhase.Keyframe, again.phase)
        assertEquals(300_000L, again.keyBytes)
    }

    @Test
    fun `the send-time credit is capped and a zero rate gives none`() {
        val slow = budgetStep(BudgetState(), BudgetEvent.KeyQueued(1_000_000, 1_000_000)).state
        assertEquals(MAX_BUDGET_CREDIT_US, slow.creditUs)
        val unknown = budgetStep(BudgetState(), BudgetEvent.KeyQueued(500_000, 0)).state
        assertEquals(0L, unknown.creditUs)
    }
}
