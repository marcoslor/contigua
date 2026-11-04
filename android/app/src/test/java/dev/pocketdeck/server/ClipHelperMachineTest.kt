package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Every state/event pair of the helper machine (ISS-27). */
class ClipHelperMachineTest {

    private val ignored = emptyList<ClipHelperAction>()

    private fun assertStep(
        expected: ClipHelperState,
        expectedActions: List<ClipHelperAction>,
        state: ClipHelperState,
        event: ClipHelperEvent,
    ) {
        val step = clipHelperStep(state, event)
        assertEquals(expected, step.state)
        assertEquals(expectedActions, step.actions)
    }

    @Test
    fun offStartsTheFirstAttempt() {
        assertStep(
            ClipHelperState.Starting(1),
            listOf(ClipHelperAction.Spawn(1)),
            ClipHelperState.Off,
            ClipHelperEvent.Start,
        )
    }

    @Test
    fun aReadySignalMovesTheMatchingAttempt() {
        assertStep(
            ClipHelperState.Ready(1),
            ignored,
            ClipHelperState.Starting(1),
            ClipHelperEvent.Started(1),
        )
        assertStep(
            ClipHelperState.Ready(3),
            ignored,
            ClipHelperState.Starting(3),
            ClipHelperEvent.Started(3),
        )
        // A late ready from a replaced process is not this attempt.
        assertStep(
            ClipHelperState.Starting(2),
            ignored,
            ClipHelperState.Starting(2),
            ClipHelperEvent.Started(1),
        )
    }

    @Test
    fun aDeathRetriesWithBackoffUpToThreeTimes() {
        assertStep(
            ClipHelperState.Starting(2),
            listOf(ClipHelperAction.SpawnAfter(2, 500)),
            ClipHelperState.Starting(1),
            ClipHelperEvent.Died("exit 1"),
        )
        assertStep(
            ClipHelperState.Starting(3),
            listOf(ClipHelperAction.SpawnAfter(3, 1_000)),
            ClipHelperState.Starting(2),
            ClipHelperEvent.Died("exit 1"),
        )
        assertStep(
            ClipHelperState.Starting(4),
            listOf(ClipHelperAction.SpawnAfter(4, 2_000)),
            ClipHelperState.Starting(3),
            ClipHelperEvent.Died("exit 1"),
        )
        assertStep(
            ClipHelperState.Failed("exit 1"),
            ignored,
            ClipHelperState.Starting(4),
            ClipHelperEvent.Died("exit 1"),
        )
    }

    @Test
    fun aReadyHelperRestartsTheSameWay() {
        assertStep(
            ClipHelperState.Starting(2),
            listOf(ClipHelperAction.SpawnAfter(2, 500)),
            ClipHelperState.Ready(1),
            ClipHelperEvent.Died("exit 1"),
        )
        assertStep(
            ClipHelperState.Failed("no su"),
            ignored,
            ClipHelperState.Ready(4),
            ClipHelperEvent.Died("no su"),
        )
    }

    @Test
    fun stopKillsFromStartingOrReadyOnly() {
        assertStep(
            ClipHelperState.Off,
            listOf(ClipHelperAction.Kill),
            ClipHelperState.Starting(2),
            ClipHelperEvent.Stop,
        )
        assertStep(
            ClipHelperState.Off,
            listOf(ClipHelperAction.Kill),
            ClipHelperState.Ready(1),
            ClipHelperEvent.Stop,
        )
        assertStep(ClipHelperState.Off, ignored, ClipHelperState.Off, ClipHelperEvent.Stop)
        assertStep(ClipHelperState.Off, ignored, ClipHelperState.Failed("no su"), ClipHelperEvent.Stop)
    }

    @Test
    fun aFailedMachineStartsFreshOnTheNextSession() {
        assertStep(
            ClipHelperState.Starting(1),
            listOf(ClipHelperAction.Spawn(1)),
            ClipHelperState.Failed("no su"),
            ClipHelperEvent.Start,
        )
    }

    @Test
    fun eventsThatMeanNothingInAStateAreIgnored() {
        for (state in listOf(
            ClipHelperState.Off,
            ClipHelperState.Starting(1),
            ClipHelperState.Ready(1),
            ClipHelperState.Failed("no su"),
        )) {
            assertStep(state, ignored, state, ClipHelperEvent.Started(99))
        }
        assertStep(ClipHelperState.Starting(1), ignored, ClipHelperState.Starting(1), ClipHelperEvent.Started(2))
        assertStep(ClipHelperState.Off, ignored, ClipHelperState.Off, ClipHelperEvent.Died("exit 1"))
        assertStep(ClipHelperState.Failed("no su"), ignored, ClipHelperState.Failed("no su"), ClipHelperEvent.Died("exit 1"))
        assertStep(ClipHelperState.Starting(1), ignored, ClipHelperState.Starting(1), ClipHelperEvent.Start)
        assertStep(ClipHelperState.Ready(1), ignored, ClipHelperState.Ready(1), ClipHelperEvent.Start)
        assertStep(ClipHelperState.Ready(1), ignored, ClipHelperState.Ready(1), ClipHelperEvent.Started(1))
    }

    @Test
    fun theBackoffIsCapped() {
        assertEquals(500, clipHelperBackoffMs(2))
        assertEquals(1_000, clipHelperBackoffMs(3))
        assertEquals(2_000, clipHelperBackoffMs(4))
        assertEquals(2_000, clipHelperBackoffMs(8))
    }

    @Test
    fun threeRestartsAreTheBound() {
        assertEquals(4, CLIP_HELPER_MAX_ATTEMPTS)
        assertTrue(CLIP_HELPER_MAX_ATTEMPTS - 1 == 3)
    }
}
