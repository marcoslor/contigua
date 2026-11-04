package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Every state/event pair of the helper machine (ISS-27), including the two
 * spawn forms: the first start tries them in order, and the form that reaches
 * ready is the one every later restart uses.
 */
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
    fun offStartsTheFirstAttemptWithTheFirstForm() {
        assertStep(
            ClipHelperState.Starting(1, 1),
            listOf(ClipHelperAction.Spawn(1, 1)),
            ClipHelperState.Off,
            ClipHelperEvent.Start,
        )
    }

    /** The real builder: the root manager's `-c` form first, AOSP's `sh -c` second. */
    @Test
    fun theTwoSpawnFormsAreTriedInOrder() {
        val cmd = "CLASSPATH=/apk exec app_process /system/bin dev.pocketdeck.server.ClipHelperMain"
        assertEquals(
            listOf(
                listOf("su", "2000", "-c", cmd),
                listOf("su", "2000", "sh", "-c", cmd),
            ),
            clipHelperSpawnForms(cmd),
        )
        assertEquals("a form was added without a transition", 2, CLIP_HELPER_SPAWN_FORMS)
        assertEquals(CLIP_HELPER_SPAWN_FORMS, clipHelperSpawnForms(cmd).size)
    }

    @Test
    fun aReadySignalMovesTheMatchingProcess() {
        assertStep(
            ClipHelperState.Ready(1, 1),
            ignored,
            ClipHelperState.Starting(1, 1),
            ClipHelperEvent.Started(1, 1),
        )
        assertStep(
            ClipHelperState.Ready(1, 2),
            ignored,
            ClipHelperState.Starting(1, 2),
            ClipHelperEvent.Started(1, 2),
        )
        assertStep(
            ClipHelperState.Ready(2, 1),
            ignored,
            ClipHelperState.Restarting(2, 1),
            ClipHelperEvent.Started(2, 1),
        )
        // A late ready from a replaced process is not this one: another form or
        // another attempt.
        assertStep(
            ClipHelperState.Starting(1, 2),
            ignored,
            ClipHelperState.Starting(1, 2),
            ClipHelperEvent.Started(1, 1),
        )
        assertStep(
            ClipHelperState.Starting(1, 2),
            ignored,
            ClipHelperState.Starting(1, 2),
            ClipHelperEvent.Started(2, 2),
        )
        assertStep(
            ClipHelperState.Restarting(2, 1),
            ignored,
            ClipHelperState.Restarting(2, 1),
            ClipHelperEvent.Started(1, 1),
        )
    }

    /** Form 1 reaches ready: one spawn, and every later restart keeps form 1. */
    @Test
    fun formOneWorkingIsKeptForEveryRestart() {
        assertStep(
            ClipHelperState.Restarting(2, 1),
            listOf(ClipHelperAction.SpawnAfter(2, 1, 500)),
            ClipHelperState.Ready(1, 1),
            ClipHelperEvent.Died(1, 1, "exit 1"),
        )
        assertStep(
            ClipHelperState.Restarting(3, 1),
            listOf(ClipHelperAction.SpawnAfter(3, 1, 1_000)),
            ClipHelperState.Restarting(2, 1),
            ClipHelperEvent.Died(2, 1, "exit 1"),
        )
        assertStep(
            ClipHelperState.Restarting(4, 1),
            listOf(ClipHelperAction.SpawnAfter(4, 1, 2_000)),
            ClipHelperState.Restarting(3, 1),
            ClipHelperEvent.Died(3, 1, "exit 1"),
        )
        assertStep(
            ClipHelperState.Failed("exit 1"),
            ignored,
            ClipHelperState.Restarting(4, 1),
            ClipHelperEvent.Died(4, 1, "exit 1"),
        )
    }

    /**
     * Form 1 dies before ready: form 2 starts at once, spending no restart, and
     * is kept when it reaches ready.
     */
    @Test
    fun formOneDyingBeforeReadyTriesFormTwoAtOnce() {
        assertStep(
            ClipHelperState.Starting(1, 2),
            listOf(ClipHelperAction.Spawn(1, 2)),
            ClipHelperState.Starting(1, 1),
            ClipHelperEvent.Died(1, 1, "exit 1"),
        )
        assertStep(
            ClipHelperState.Ready(1, 2),
            ignored,
            ClipHelperState.Starting(1, 2),
            ClipHelperEvent.Started(1, 2),
        )
        assertStep(
            ClipHelperState.Restarting(2, 2),
            listOf(ClipHelperAction.SpawnAfter(2, 2, 500)),
            ClipHelperState.Ready(1, 2),
            ClipHelperEvent.Died(1, 2, "exit 1"),
        )
    }

    /** Every form died before ready: no more spawns, one closed reason. */
    @Test
    fun everyFormDyingBeforeReadyFailsWithNoSuForm() {
        assertStep(
            ClipHelperState.Failed("no su form"),
            ignored,
            ClipHelperState.Starting(1, 2),
            ClipHelperEvent.Died(1, 2, "exit 1"),
        )
        assertStep(
            ClipHelperState.Failed("no su form"),
            ignored,
            ClipHelperState.Failed("no su form"),
            ClipHelperEvent.Died(1, 2, "exit 1"),
        )
        // A new session starts over with the first form.
        assertStep(
            ClipHelperState.Starting(1, 1),
            listOf(ClipHelperAction.Spawn(1, 1)),
            ClipHelperState.Failed("no su form"),
            ClipHelperEvent.Start,
        )
    }

    /** A death or ready from another form or attempt changes nothing. */
    @Test
    fun aStaleEventFromAnotherFormOrAttemptIsIgnored() {
        assertStep(
            ClipHelperState.Starting(1, 2),
            ignored,
            ClipHelperState.Starting(1, 2),
            ClipHelperEvent.Died(1, 1, "exit 1"),
        )
        assertStep(
            ClipHelperState.Starting(1, 2),
            ignored,
            ClipHelperState.Starting(1, 2),
            ClipHelperEvent.Died(2, 2, "exit 1"),
        )
        assertStep(
            ClipHelperState.Ready(1, 2),
            ignored,
            ClipHelperState.Ready(1, 2),
            ClipHelperEvent.Died(1, 1, "exit 1"),
        )
        assertStep(
            ClipHelperState.Restarting(2, 2),
            ignored,
            ClipHelperState.Restarting(2, 2),
            ClipHelperEvent.Died(2, 1, "exit 1"),
        )
    }

    @Test
    fun stopKillsFromEveryRunningState() {
        for (state in listOf(
            ClipHelperState.Starting(1, 2),
            ClipHelperState.Restarting(2, 1),
            ClipHelperState.Ready(1, 2),
        )) {
            assertStep(ClipHelperState.Off, listOf(ClipHelperAction.Kill), state, ClipHelperEvent.Stop)
        }
        assertStep(ClipHelperState.Off, ignored, ClipHelperState.Off, ClipHelperEvent.Stop)
        assertStep(ClipHelperState.Off, ignored, ClipHelperState.Failed("no su form"), ClipHelperEvent.Stop)
    }

    @Test
    fun startIsIgnoredWhileRunning() {
        for (state in listOf(
            ClipHelperState.Starting(1, 1),
            ClipHelperState.Starting(1, 2),
            ClipHelperState.Restarting(2, 1),
            ClipHelperState.Ready(1, 1),
        )) {
            assertStep(state, ignored, state, ClipHelperEvent.Start)
        }
    }

    @Test
    fun eventsThatMeanNothingInAStateAreIgnored() {
        assertStep(ClipHelperState.Off, ignored, ClipHelperState.Off, ClipHelperEvent.Started(1, 1))
        assertStep(ClipHelperState.Off, ignored, ClipHelperState.Off, ClipHelperEvent.Died(1, 1, "exit 1"))
        assertStep(
            ClipHelperState.Failed("no su form"),
            ignored,
            ClipHelperState.Failed("no su form"),
            ClipHelperEvent.Started(1, 1),
        )
        assertStep(
            ClipHelperState.Ready(1, 1),
            ignored,
            ClipHelperState.Ready(1, 1),
            ClipHelperEvent.Started(1, 1),
        )
    }

    /** Each transition line names the form, and nothing a command line carries. */
    @Test
    fun everyLabelNamesTheForm() {
        assertEquals("off", ClipHelperState.Off.label())
        assertEquals("starting(1, form 2)", ClipHelperState.Starting(1, 2).label())
        assertEquals("restarting(2, form 1)", ClipHelperState.Restarting(2, 1).label())
        assertEquals("ready(1, form 2)", ClipHelperState.Ready(1, 2).label())
        assertEquals("failed(no su form)", ClipHelperState.Failed("no su form").label())
        assertEquals("start", ClipHelperEvent.Start.label())
        assertEquals("started(1, form 2)", ClipHelperEvent.Started(1, 2).label())
        assertEquals("died(exit 1, form 1)", ClipHelperEvent.Died(1, 1, "exit 1").label())
        assertEquals("stop", ClipHelperEvent.Stop.label())
    }

    @Test
    fun theBackoffIsCapped() {        assertEquals(500, clipHelperBackoffMs(2))
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
