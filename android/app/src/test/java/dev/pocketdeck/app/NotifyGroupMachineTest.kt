package dev.pocketdeck.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The per-package-group forwarding machine (NOTIFY-20, docs/specs/
 * notifications.md): every state/event pair, including the events a state must
 * ignore. The listener performs the returned actions; nothing here sends.
 */
class NotifyGroupMachineTest {

    private val empty = NotifyGroupState()
    private val one = NotifyGroupState(NotifyGroupPhase.CHILDREN, 1)
    private val two = NotifyGroupState(NotifyGroupPhase.CHILDREN, 2)
    private val summary = NotifyGroupState(NotifyGroupPhase.SUMMARY, 0, "s1")

    private fun assertTransition(
        state: NotifyGroupState,
        event: NotifyGroupEvent,
        next: NotifyGroupState,
        actions: List<NotifyGroupAction>,
    ) {
        val (actualNext, actualActions) = NotifyGroups.transition(state, event)
        assertEquals(next, actualNext)
        assertEquals(actions, actualActions)
    }

    @Test
    fun `a lone child forwards and a second child joins it`() {
        assertTransition(
            empty, NotifyGroupEvent.ChildPosted("c1"),
            NotifyGroupState(NotifyGroupPhase.CHILDREN, 1), listOf(NotifyGroupAction.Forward),
        )
        assertTransition(
            one, NotifyGroupEvent.ChildPosted("c2"),
            NotifyGroupState(NotifyGroupPhase.CHILDREN, 2), listOf(NotifyGroupAction.Forward),
        )
    }

    @Test
    fun `a summary with no children forwards and an updated summary replaces itself`() {
        assertTransition(
            empty, NotifyGroupEvent.SummaryPosted("s1"),
            NotifyGroupState(NotifyGroupPhase.SUMMARY, 0, "s1"), listOf(NotifyGroupAction.Forward),
        )
        assertTransition(
            summary, NotifyGroupEvent.SummaryPosted("s2"),
            NotifyGroupState(NotifyGroupPhase.SUMMARY, 0, "s2"), listOf(NotifyGroupAction.Forward),
        )
    }

    @Test
    fun `a summary while children are forwarded is skipped`() {
        assertTransition(two, NotifyGroupEvent.SummaryPosted("s1"), two, listOf(NotifyGroupAction.Skip))
    }

    @Test
    fun `a child after a summary takes the summary away first`() {
        assertTransition(
            summary, NotifyGroupEvent.ChildPosted("c1"),
            NotifyGroupState(NotifyGroupPhase.CHILDREN, 1),
            listOf(NotifyGroupAction.RemoveSummary("s1"), NotifyGroupAction.Forward),
        )
    }

    @Test
    fun `the last child leaving empties the group and a removal with no children is ignored`() {
        assertTransition(
            two, NotifyGroupEvent.ChildGone,
            NotifyGroupState(NotifyGroupPhase.CHILDREN, 1), emptyList(),
        )
        assertTransition(one, NotifyGroupEvent.ChildGone, NotifyGroupState(), emptyList())
        assertTransition(empty, NotifyGroupEvent.ChildGone, empty, emptyList())
        // A child removal must not touch a forwarded summary.
        assertTransition(summary, NotifyGroupEvent.ChildGone, summary, emptyList())
    }

    @Test
    fun `a summary leaving empties the group and a late one is ignored`() {
        assertTransition(summary, NotifyGroupEvent.SummaryGone, NotifyGroupState(), emptyList())
        assertTransition(empty, NotifyGroupEvent.SummaryGone, empty, emptyList())
        assertTransition(two, NotifyGroupEvent.SummaryGone, two, emptyList())
    }

    @Test
    fun `an empty group has a stable state`() {
        val (next, actions) = NotifyGroups.transition(NotifyGroupState(), NotifyGroupEvent.SummaryGone)
        assertEquals(NotifyGroupPhase.EMPTY, next.phase)
        assertTrue(actions.isEmpty())
    }
}
