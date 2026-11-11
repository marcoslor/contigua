package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The phone's task-arrival machine (WIN-44, WIN-48, WIN-49). Every case is one
 * transition over the closed state set; the actions are values, so nothing here
 * touches Android.
 */
class TaskArrivalTest {

    private val chrome = "com.android.chrome"
    private val settings = "com.android.settings"

    /** A machine with one streamed Chrome task (stream 1, display 100, task 7). */
    private fun watching(stream: Int = 1, displayId: Int = 100, pkg: String = chrome, taskId: Int = 7): TaskArrival =
        TaskArrival().apply {
            on(TaskArrivalEvent.StreamOpened(stream, displayId, pkg, taskId))
        }

    @Test
    fun aFreshTaskOfAStreamedAppIsReportedOnce() {
        val machine = watching()
        val step = machine.on(TaskArrivalEvent.Created(taskId = 42, pkg = chrome, nowMs = 1_000))
        assertEquals(listOf(TaskArrivalAction.Report(stream = 1, taskId = 42, pkg = chrome)), step)
        assertEquals(
            emptyList<TaskArrivalAction>(),
            machine.on(TaskArrivalEvent.Created(taskId = 42, pkg = chrome, nowMs = 1_050)),
        )
    }

    @Test
    fun aCreatedWithNoPackageYetWaitsForThePackageAndThenReports() {
        val machine = watching()
        assertEquals(emptyList<TaskArrivalAction>(), machine.on(TaskArrivalEvent.Created(42, null, 1_000)))
        assertEquals(
            listOf(TaskArrivalAction.Report(1, 42, chrome)),
            machine.on(TaskArrivalEvent.Created(42, chrome, 1_001)),
        )
    }

    @Test
    fun thePhonesOwnLaunchIsNeverReported() {
        val machine = watching().apply { on(TaskArrivalEvent.OwnLaunchStarted(chrome)) }
        assertEquals(emptyList<TaskArrivalAction>(), machine.on(TaskArrivalEvent.Created(42, chrome, 1_000)))
        assertEquals(emptyList<TaskArrivalAction>(), machine.on(TaskArrivalEvent.Created(42, chrome, 1_001)))
        // The launch finishing late still marks the id its own, not a report.
        machine.on(TaskArrivalEvent.OwnLaunchFinished(chrome, 43))
        assertEquals(emptyList<TaskArrivalAction>(), machine.on(TaskArrivalEvent.Created(43, chrome, 1_002)))
    }

    @Test
    fun aTaskThePhoneMovedIsNeverReported() {
        val machine = watching().apply { on(TaskArrivalEvent.OwnMove(42)) }
        assertEquals(emptyList<TaskArrivalAction>(), machine.on(TaskArrivalEvent.Created(42, chrome, 1_000)))
    }

    @Test
    fun aTaskOfAPackageWithNoStreamIsNotReported() {
        val machine = watching()
        assertEquals(emptyList<TaskArrivalAction>(), machine.on(TaskArrivalEvent.Created(42, settings, 1_000)))
    }

    @Test
    fun theReportIsAtMostOnceASecondPerPackage() {
        val machine = watching()
        assertEquals(listOf(TaskArrivalAction.Report(1, 42, chrome)),
            machine.on(TaskArrivalEvent.Created(42, chrome, 1_000)))
        assertEquals(emptyList<TaskArrivalAction>(), machine.on(TaskArrivalEvent.Created(43, chrome, 1_400)))
        assertEquals(listOf(TaskArrivalAction.Report(1, 44, chrome)),
            machine.on(TaskArrivalEvent.Created(44, chrome, 2_000)))
        // A suppressed task is still "seen": a later duplicate cannot report it.
        assertEquals(emptyList<TaskArrivalAction>(), machine.on(TaskArrivalEvent.Created(43, chrome, 2_100)))
    }

    @Test
    fun whileIdleEveryArrivalIsIgnored() {
        val machine = TaskArrival()
        assertEquals(emptyList<TaskArrivalAction>(), machine.on(TaskArrivalEvent.Created(42, chrome, 1_000)))
        assertEquals(emptyList<TaskArrivalAction>(), machine.on(TaskArrivalEvent.DisplayChanged(7, 0, 1_000)))
        assertEquals(emptyList<TaskArrivalAction>(), machine.on(TaskArrivalEvent.Removed(7)))
    }

    @Test
    fun theStreamsOwnTaskChangingDisplayToThePhoneAsksAndThenClosesMovedToPhone() {
        val machine = watching()
        val actions = machine.on(TaskArrivalEvent.DisplayChanged(taskId = 7, displayId = 0, nowMs = 1_000))
        assertEquals(listOf(TaskArrivalAction.ProbeDisplay(stream = 1, displayId = 100)), actions)
        val after = machine.on(TaskArrivalEvent.MoveCheck(stream = 1, displayStillHasTask = false))
        assertEquals(listOf(TaskArrivalAction.CloseMovedToPhone(stream = 1)), after)
    }

    @Test
    fun aDisplayChangeThatLeavesAnotherTaskDoesNothing() {
        val machine = watching()
        machine.on(TaskArrivalEvent.DisplayChanged(7, 0, 1_000))
        assertEquals(
            emptyList<TaskArrivalAction>(),
            machine.on(TaskArrivalEvent.MoveCheck(stream = 1, displayStillHasTask = true)),
        )
    }

    @Test
    fun aDisplayChangeToAnotherDisplayIsNotThePhone() {
        val machine = watching()
        assertEquals(emptyList<TaskArrivalAction>(), machine.on(TaskArrivalEvent.DisplayChanged(7, 3, 1_000)))
    }

    @Test
    fun aDisplayChangeOfAnotherTaskIsIgnored() {
        val machine = watching()
        assertEquals(emptyList<TaskArrivalAction>(), machine.on(TaskArrivalEvent.DisplayChanged(42, 0, 1_000)))
    }

    @Test
    fun aRemovedTaskAsksWhetherItsDisplayIsEmptyBeforeClosing() {
        val machine = watching()
        assertEquals(listOf(TaskArrivalAction.ProbeDisplay(stream = 1, displayId = 100)),
            machine.on(TaskArrivalEvent.Removed(taskId = 7)))
        assertEquals(listOf(TaskArrivalAction.CloseAppExited(stream = 1)),
            machine.on(TaskArrivalEvent.DisplayEmpty(stream = 1)))
    }

    @Test
    fun anEmptyDisplayWithoutAMoveIsARealExit() {
        val machine = watching()
        assertEquals(listOf(TaskArrivalAction.CloseAppExited(stream = 1)),
            machine.on(TaskArrivalEvent.DisplayEmpty(stream = 1)))
    }

    @Test
    fun anEmptyDisplayWhileAMoveIsProbedClosesMovedToPhone() {
        val machine = watching()
        machine.on(TaskArrivalEvent.DisplayChanged(7, 0, 1_000))
        assertEquals(listOf(TaskArrivalAction.CloseMovedToPhone(stream = 1)),
            machine.on(TaskArrivalEvent.DisplayEmpty(stream = 1)))
    }

    @Test
    fun aSheetClosingOverTheAppsTaskRepointsInsteadOfClosing() {
        val machine = watching()
        // The system's own picker became the display's top task: the report
        // path learned that id exactly as the title poll does.
        machine.on(TaskArrivalEvent.StreamTask(stream = 1, taskId = 42))
        assertEquals(listOf(TaskArrivalAction.ProbeDisplay(stream = 1, displayId = 100)),
            machine.on(TaskArrivalEvent.Removed(taskId = 42)))
        // The display still has the app's task: the stream follows it again.
        assertEquals(emptyList<TaskArrivalAction>(),
            machine.on(TaskArrivalEvent.StreamTask(stream = 1, taskId = 7)))
        assertEquals(7, machine.streamTask(1))
    }

    @Test
    fun aSheetClosedBeforeTheAppItselfExitsStillCloses() {
        val machine = watching()
        machine.on(TaskArrivalEvent.StreamTask(stream = 1, taskId = 42))
        machine.on(TaskArrivalEvent.Removed(taskId = 42))
        machine.on(TaskArrivalEvent.StreamTask(stream = 1, taskId = 7))
        assertEquals(listOf(TaskArrivalAction.ProbeDisplay(stream = 1, displayId = 100)),
            machine.on(TaskArrivalEvent.Removed(taskId = 7)))
        assertEquals(listOf(TaskArrivalAction.CloseAppExited(stream = 1)),
            machine.on(TaskArrivalEvent.DisplayEmpty(stream = 1)))
    }

    @Test
    fun aTaskBackOnTheDisplayResolvesAMoveProbe() {
        val machine = watching()
        machine.on(TaskArrivalEvent.DisplayChanged(7, 0, 1_000))
        // Another task is on the streamed display: the move probe is answered
        // by the report path itself, and a later empty display is an exit.
        machine.on(TaskArrivalEvent.StreamTask(stream = 1, taskId = 42))
        assertEquals(listOf(TaskArrivalAction.CloseAppExited(stream = 1)),
            machine.on(TaskArrivalEvent.DisplayEmpty(stream = 1)))
    }

    @Test
    fun theLastStreamClosingReturnsToIdleAndForgetsTheFacts() {
        val machine = watching()
        machine.on(TaskArrivalEvent.Created(42, chrome, 1_000))
        machine.on(TaskArrivalEvent.StreamClosed(stream = 1))
        assertEquals(TaskArrivalPhase.IDLE, machine.phase)
        assertEquals(emptyList<TaskArrivalAction>(), machine.on(TaskArrivalEvent.Created(43, chrome, 1_100)))
        machine.on(TaskArrivalEvent.StreamOpened(2, 101, chrome, 8))
        assertEquals(TaskArrivalPhase.WATCHING, machine.phase)
        assertEquals(listOf(TaskArrivalAction.Report(2, 44, chrome)),
            machine.on(TaskArrivalEvent.Created(44, chrome, 2_000)))
    }

    @Test
    fun aSecondStreamOfTheSameAppReportsAgainstTheFirstOne() {
        val machine = watching()
        machine.on(TaskArrivalEvent.StreamOpened(2, 101, chrome, 8))
        assertEquals(listOf(TaskArrivalAction.Report(1, 42, chrome)),
            machine.on(TaskArrivalEvent.Created(42, chrome, 1_000)))
        assertTrue(machine.streamTask(2) == 8)
    }

    @Test
    fun theStreamsTaskLearnedLaterBecomesItsOwn() {
        val machine = TaskArrival().apply { on(TaskArrivalEvent.StreamOpened(1, 100, chrome, 0)) }
        machine.on(TaskArrivalEvent.StreamTask(stream = 1, taskId = 7))
        assertEquals(emptyList<TaskArrivalAction>(), machine.on(TaskArrivalEvent.Created(7, chrome, 1_000)))
        assertEquals(listOf(TaskArrivalAction.Report(1, 42, chrome)),
            machine.on(TaskArrivalEvent.Created(42, chrome, 2_000)))
    }

    @Test
    fun anUnresolvedTaskIsDroppedWhenItNeverNamesAPackage() {
        val machine = watching()
        assertEquals(emptyList<TaskArrivalAction>(), machine.on(TaskArrivalEvent.Created(42, null, 1_000)))
        assertEquals(emptyList<TaskArrivalAction>(), machine.on(TaskArrivalEvent.Created(43, null, 1_100)))
        assertEquals(emptyList<TaskArrivalAction>(), machine.on(TaskArrivalEvent.Removed(42)))
    }
}
