package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/**
 * WIN-44/WIN-48/WIN-49 on a real session: the listener's events go through the
 * machine and out as `window.task`, `window.closed moved_to_phone` or
 * `window.closed app_exited`, and a refused registration breaks nothing.
 */
class TaskReportSessionTest : SessionFixture() {

    private val chrome = "com.android.chrome"
    private var logs = CopyOnWriteArrayList<String>()

    private fun connectWithEvents(
        events: FakeTaskEvents,
        presence: TaskPresence,
        exitPollMs: Long = 60_000,
    ) {
        logs = CopyOnWriteArrayList()
        connect(taskPresence = presence, taskEvents = events,
                log = { logs.add(it) }, exitPollIntervalMs = exitPollMs)
    }

    private fun openChrome() {
        open(1, chrome)
        val opened = readUntil("window.opened")
        assertEquals(1, opened.intValue("stream"))
    }

    @Test
    fun aFreshTaskIsReportedWithTheTaskPackageAndLabel() {
        val events = FakeTaskEvents()
        connectWithEvents(events, FixedPresence(hasTask = true, taskId = 7, label = "Docs"))
        openChrome()

        events.emit(TaskStackEvent.Created(taskId = 42, pkg = chrome))
        val report = readUntil("window.task")

        assertEquals(1, report.intValue("stream"))
        assertEquals(42, report.intValue("taskId"))
        assertEquals(chrome, report["pkg"])
        assertEquals("Docs", report["label"])
        // R-PRIV-1: a label is phone content — the log carries its length only.
        assertTrue(logs.any { it == "window.task stream=1 task=42 len=4" })
        assertFalse(logs.any { it.contains("Docs") })
    }

    @Test
    fun theStreamsOwnTaskMovingToThePhoneClosesMovedToPhone() {
        val events = FakeTaskEvents()
        connectWithEvents(events, FixedPresence(hasTask = false, taskId = 7))
        openChrome()

        events.emit(TaskStackEvent.DisplayChanged(taskId = 7, displayId = 0))
        val closed = readUntil("window.closed")

        assertEquals("moved_to_phone", closed["reason"])
        assertEquals(1, closed.intValue("stream"))
        assertFalse(logs.any { it.startsWith("window.task") })
    }

    @Test
    fun aRemovedStreamTaskClosesAppExited() {
        val events = FakeTaskEvents()
        connectWithEvents(events, FixedPresence(hasTask = true, taskId = 7))
        openChrome()

        events.emit(TaskStackEvent.Removed(taskId = 7))
        val closed = readUntil("window.closed")

        assertEquals("app_exited", closed["reason"])
    }

    @Test
    fun aRefusedRegistrationLeavesEveryOtherWindowPathWorking() {
        val events = FakeTaskEvents().apply { accept = false }
        connectWithEvents(events, FixedPresence(hasTask = true, taskId = 7))
        // The open still answers and the listener is neither live nor a failure path.
        openChrome()
        assertTrue(events.started >= 1)
        assertTrue(logs.any { it.startsWith("task listener: refused") })
        assertFalse(logs.any { it.startsWith("window.task") })
    }
}
