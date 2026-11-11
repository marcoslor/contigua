package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * A session's teardown (docs/specs/pairing.md PAIR-20): a drop cuts the
 * transport at once, a refusal lets the last frame drain, and every later event
 * is ignored. The events that must be ignored are the point: a second drop must
 * not run the close twice.
 */
class SessionTeardownTest {

    private fun step(state: SessionTeardown.State, event: SessionTeardown.Event) =
        SessionTeardown.transition(state, event)

    @Test
    fun aDropCutsTheTransportAtOnce() {
        val step = step(SessionTeardown.State.LIVE, SessionTeardown.Event.Drop)
        assertEquals(SessionTeardown.State.DROPPED, step.to)
        assertEquals(listOf(SessionTeardown.Action.ABORT), step.actions)
    }

    @Test
    fun aRefusalStopsReadingAndLetsTheWriterDrain() {
        val step = step(SessionTeardown.State.LIVE, SessionTeardown.Event.Stop)
        assertEquals(SessionTeardown.State.ENDING, step.to)
        assertEquals(emptyList<SessionTeardown.Action>(), step.actions)
    }

    @Test
    fun aSecondRefusalIsNotASecondDecision() {
        val step = step(SessionTeardown.State.ENDING, SessionTeardown.Event.Stop)
        assertEquals(SessionTeardown.State.ENDING, step.to)
        assertEquals(emptyList<SessionTeardown.Action>(), step.actions)
    }

    @Test
    fun aDropWhileEndingStillCutsTheTransport() {
        val step = step(SessionTeardown.State.ENDING, SessionTeardown.Event.Drop)
        assertEquals(SessionTeardown.State.DROPPED, step.to)
        assertEquals(listOf(SessionTeardown.Action.ABORT), step.actions)
    }

    @Test
    fun aSecondDropRunsNoAction() {
        val step = step(SessionTeardown.State.DROPPED, SessionTeardown.Event.Drop)
        assertEquals(SessionTeardown.State.DROPPED, step.to)
        assertEquals(emptyList<SessionTeardown.Action>(), step.actions)
    }

    @Test
    fun aRefusalAfterADropIsIgnored() {
        val step = step(SessionTeardown.State.DROPPED, SessionTeardown.Event.Stop)
        assertEquals(SessionTeardown.State.DROPPED, step.to)
        assertEquals(emptyList<SessionTeardown.Action>(), step.actions)
    }

    @Test
    fun theReaderEndingFinishesFromEveryState() {
        for (state in listOf(
            SessionTeardown.State.LIVE,
            SessionTeardown.State.ENDING,
            SessionTeardown.State.DROPPED,
        )) {
            val step = step(state, SessionTeardown.Event.Ended)
            assertEquals("$state --ended-->", SessionTeardown.State.FINISHED, step.to)
            assertEquals(emptyList<SessionTeardown.Action>(), step.actions)
        }
    }

    @Test
    fun aFinishedSessionIgnoresEveryEvent() {
        for (event in listOf(
            SessionTeardown.Event.Drop,
            SessionTeardown.Event.Stop,
            SessionTeardown.Event.Ended,
        )) {
            val step = step(SessionTeardown.State.FINISHED, event)
            assertEquals(SessionTeardown.State.FINISHED, step.to)
            assertEquals(emptyList<SessionTeardown.Action>(), step.actions)
        }
    }

    @Test
    fun everyStateAndEventIsCovered() {
        // No `else` arm in the transition: this walks the whole product, so a
        // new state or event without a case is a test failure, not a silent skip.
        for (state in SessionTeardown.State.entries) {
            for (event in listOf(
                SessionTeardown.Event.Drop,
                SessionTeardown.Event.Stop,
                SessionTeardown.Event.Ended,
            )) {
                assertEquals(state, SessionTeardown.transition(state, event).from)
            }
        }
    }

    @Test
    fun statesAndEventsHaveLogNames() {
        assertEquals("dropped", SessionTeardown.describe(SessionTeardown.State.DROPPED))
        assertEquals("drop", SessionTeardown.describe(SessionTeardown.Event.Drop))
    }
}
