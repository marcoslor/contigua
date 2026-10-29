package dev.pocketdeck.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The per-package-group forwarding machine (NOTIFY-20, docs/specs/
 * notifications.md): every state/event pair, including the events a state must
 * ignore, and a child's updates counting as one child. The listener performs
 * the returned actions; nothing here sends.
 */
class NotifyGroupMachineTest {

    private val empty = NotifyGroupState()
    private val one = NotifyGroupState(NotifyGroupPhase.CHILDREN, setOf("c1"))
    private val two = NotifyGroupState(NotifyGroupPhase.CHILDREN, setOf("c1", "c2"))
    private val summary = NotifyGroupState(NotifyGroupPhase.SUMMARY, emptySet(), "s1")

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
            NotifyGroupState(NotifyGroupPhase.CHILDREN, setOf("c1")), listOf(NotifyGroupAction.Forward),
        )
        assertTransition(
            one, NotifyGroupEvent.ChildPosted("c2"),
            NotifyGroupState(NotifyGroupPhase.CHILDREN, setOf("c1", "c2")), listOf(NotifyGroupAction.Forward),
        )
    }

    @Test
    fun `an updated child is still one child and leaves the group when it goes`() {
        // A chat updates its one notification per message: three posts are one
        // child, not three. Its removal must empty the group.
        var state = empty
        repeat(3) {
            val (next, actions) = NotifyGroups.transition(state, NotifyGroupEvent.ChildPosted("c1"))
            assertEquals(listOf(NotifyGroupAction.Forward), actions)
            state = next
        }
        assertEquals(NotifyGroupState(NotifyGroupPhase.CHILDREN, setOf("c1")), state)
        assertTransition(state, NotifyGroupEvent.ChildGone("c1"), NotifyGroupState(), emptyList())
        // The group is empty again, so its next summary forwards.
        assertTransition(
            NotifyGroupState(), NotifyGroupEvent.SummaryPosted("s1"),
            NotifyGroupState(NotifyGroupPhase.SUMMARY, emptySet(), "s1"), listOf(NotifyGroupAction.Forward),
        )
    }

    @Test
    fun `two updated children empty the group only when both are gone`() {
        var state = empty
        repeat(2) {
            listOf("c1", "c2").forEach { id ->
                state = NotifyGroups.transition(state, NotifyGroupEvent.ChildPosted(id)).first
            }
        }
        assertEquals(NotifyGroupState(NotifyGroupPhase.CHILDREN, setOf("c1", "c2")), state)
        val (afterOne, actions) = NotifyGroups.transition(state, NotifyGroupEvent.ChildGone("c1"))
        assertEquals(NotifyGroupState(NotifyGroupPhase.CHILDREN, setOf("c2")), afterOne)
        assertTrue(actions.isEmpty())
        assertTransition(afterOne, NotifyGroupEvent.ChildGone("c2"), NotifyGroupState(), emptyList())
    }

    @Test
    fun `a child the group never saw leaving changes nothing`() {
        assertTransition(one, NotifyGroupEvent.ChildGone("zzz"), one, emptyList())
        assertTransition(empty, NotifyGroupEvent.ChildGone("c1"), empty, emptyList())
        // A child removal must not touch a forwarded summary.
        assertTransition(summary, NotifyGroupEvent.ChildGone("c1"), summary, emptyList())
    }

    @Test
    fun `a summary with no children forwards and an updated summary replaces itself`() {
        assertTransition(
            empty, NotifyGroupEvent.SummaryPosted("s1"),
            NotifyGroupState(NotifyGroupPhase.SUMMARY, emptySet(), "s1"), listOf(NotifyGroupAction.Forward),
        )
        assertTransition(
            summary, NotifyGroupEvent.SummaryPosted("s2"),
            NotifyGroupState(NotifyGroupPhase.SUMMARY, emptySet(), "s2"), listOf(NotifyGroupAction.Forward),
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
            NotifyGroupState(NotifyGroupPhase.CHILDREN, setOf("c1")),
            listOf(NotifyGroupAction.RemoveSummary("s1"), NotifyGroupAction.Forward),
        )
    }

    @Test
    fun `a summary leaving empties the group and a late one is ignored`() {
        assertTransition(summary, NotifyGroupEvent.SummaryGone, NotifyGroupState(), emptyList())
        assertTransition(empty, NotifyGroupEvent.SummaryGone, empty, emptyList())
        assertTransition(two, NotifyGroupEvent.SummaryGone, two, emptyList())
    }
}
