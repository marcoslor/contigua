package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * K1 for the first-frame machine (WIN-66, ISS-10).
 *
 * The 2026-11-05 report: one window in 18 got no picture for its whole 22 s
 * life, and the phone's log of that minute had rotated out. The stream's only
 * "waiting" signal was a boolean inside `RedrawGuard`, so nothing named the
 * state or recorded it. Here the state is explicit and every pair is pinned.
 */
class FirstFrameWatchTest {

    private val limit = NO_FRAME_AFTER_MS

    private fun model(
        state: FirstFrameState,
        createdAt: Long = 0L,
        due: Long = limit,
        episode: Int = 7,
    ) = FirstFrameModel(
        state = state,
        episode = episode,
        createdAtMs = createdAt,
        dueMs = due,
        recordedAtMs = if (state == FirstFrameState.NoFrame) limit else 0L,
    )

    private fun step(state: FirstFrameState, event: FirstFrameEvent) =
        firstFrameTransition(model(state), event)

    // Every state × event, including the ignored pairs.
    @Test
    fun everyStateAndEventHasOnePinnedTransition() {
        val cases = listOf(
            Triple(FirstFrameState.Opened, FirstFrameEvent.DisplayCreated(100L), FirstFrameState.Waiting),
            Triple(FirstFrameState.Opened, FirstFrameEvent.Frame(100L), FirstFrameState.Opened),
            Triple(FirstFrameState.Opened, FirstFrameEvent.Deadline(100L), FirstFrameState.Opened),
            Triple(FirstFrameState.Opened, FirstFrameEvent.Close(100L), FirstFrameState.Closed),
            Triple(FirstFrameState.Waiting, FirstFrameEvent.DisplayCreated(100L), FirstFrameState.Waiting),
            Triple(FirstFrameState.Waiting, FirstFrameEvent.Frame(100L), FirstFrameState.Flowing),
            Triple(FirstFrameState.Waiting, FirstFrameEvent.Deadline(limit), FirstFrameState.NoFrame),
            Triple(FirstFrameState.Waiting, FirstFrameEvent.Deadline(limit - 1), FirstFrameState.Waiting),
            Triple(FirstFrameState.Waiting, FirstFrameEvent.Close(100L), FirstFrameState.Closed),
            Triple(FirstFrameState.Flowing, FirstFrameEvent.DisplayCreated(100L), FirstFrameState.Flowing),
            Triple(FirstFrameState.Flowing, FirstFrameEvent.Frame(100L), FirstFrameState.Flowing),
            Triple(FirstFrameState.Flowing, FirstFrameEvent.Deadline(100_000L), FirstFrameState.Flowing),
            Triple(FirstFrameState.Flowing, FirstFrameEvent.Close(100L), FirstFrameState.Closed),
            Triple(FirstFrameState.NoFrame, FirstFrameEvent.DisplayCreated(100L), FirstFrameState.NoFrame),
            Triple(FirstFrameState.NoFrame, FirstFrameEvent.Frame(2_000L), FirstFrameState.Flowing),
            Triple(FirstFrameState.NoFrame, FirstFrameEvent.Deadline(100_000L), FirstFrameState.NoFrame),
            Triple(FirstFrameState.NoFrame, FirstFrameEvent.Close(22_000L), FirstFrameState.Closed),
            Triple(FirstFrameState.Closed, FirstFrameEvent.DisplayCreated(100L), FirstFrameState.Closed),
            Triple(FirstFrameState.Closed, FirstFrameEvent.Frame(100L), FirstFrameState.Closed),
            Triple(FirstFrameState.Closed, FirstFrameEvent.Deadline(100L), FirstFrameState.Closed),
            Triple(FirstFrameState.Closed, FirstFrameEvent.Close(100L), FirstFrameState.Closed),
        )
        for ((from, event, to) in cases) {
            assertEquals("$from --$event-->", to, step(from, event).state.state)
        }
    }

    @Test
    fun theDisplayStartsTheClockAtTheLimit() {
        val opened = FirstFrameModel(episode = 7).let { firstFrameTransition(it, FirstFrameEvent.DisplayCreated(1_000L)) }
        assertEquals(FirstFrameState.Waiting, opened.state.state)
        assertEquals(1_000L, opened.state.createdAtMs)
        assertEquals(1_000L + limit, opened.state.dueMs)
        assertTrue(opened.actions.isEmpty())
    }

    @Test
    fun oneRecordAtTheLimitAndNeverASecond() {
        val first = firstFrameTransition(model(FirstFrameState.Waiting), FirstFrameEvent.Deadline(limit + 40))
        assertEquals(FirstFrameState.NoFrame, first.state.state)
        assertEquals(listOf(FirstFrameAction.RecordNoFrame(7, limit + 40)), first.actions)
        val again = firstFrameTransition(first.state, FirstFrameEvent.Deadline(limit + 5_000))
        assertTrue(again.actions.isEmpty())
        assertEquals(FirstFrameState.NoFrame, again.state.state)
    }

    @Test
    fun aFrameAfterTheRecordEndsItLate() {
        val step = firstFrameTransition(model(FirstFrameState.NoFrame), FirstFrameEvent.Frame(2_000L))
        assertEquals(FirstFrameState.Flowing, step.state.state)
        assertEquals(listOf(FirstFrameAction.EndNoFrame(7, NoFrameOutcome.Late, 2_000L)), step.actions)
    }

    @Test
    fun closingAfterTheRecordEndsItClosed() {
        val step = firstFrameTransition(model(FirstFrameState.NoFrame), FirstFrameEvent.Close(22_000L))
        assertEquals(FirstFrameState.Closed, step.state.state)
        assertEquals(listOf(FirstFrameAction.EndNoFrame(7, NoFrameOutcome.Closed, 22_000L)), step.actions)
    }

    @Test
    fun aCloseBeforeTheLimitRecordsNothing() {
        val step = firstFrameTransition(model(FirstFrameState.Waiting), FirstFrameEvent.Close(900L))
        assertEquals(FirstFrameState.Closed, step.state.state)
        assertTrue(step.actions.isEmpty())
    }

    @Test
    fun aFrameBeforeTheLimitFlowsAndNeverRecords() {
        val waiting = firstFrameTransition(FirstFrameModel(episode = 7), FirstFrameEvent.DisplayCreated(0L))
        val flowing = firstFrameTransition(waiting.state, FirstFrameEvent.Frame(133L))
        assertEquals(FirstFrameState.Flowing, flowing.state.state)
        assertTrue(flowing.actions.isEmpty())
        val late = firstFrameTransition(flowing.state, FirstFrameEvent.Deadline(100_000L))
        assertTrue(late.actions.isEmpty())
    }

    @Test
    fun theHolderLogsEveryPhaseChangeWithItsToken() {
        val lines = ArrayList<String>()
        val watch = FirstFrameWatch(stream = 3, episode = 7, log = { lines.add(it) })
        watch.dispatch(FirstFrameEvent.DisplayCreated(0L))
        watch.dispatch(FirstFrameEvent.Deadline(limit))
        watch.dispatch(FirstFrameEvent.Frame(limit + 500))
        assertEquals(
            listOf(
                "stream 3 firstframe: opened --display--> waiting-first-frame",
                "stream 3 firstframe: waiting-first-frame --deadline--> no-frame",
                "stream 3 firstframe: no-frame --frame--> flowing",
            ),
            lines,
        )
    }
}
