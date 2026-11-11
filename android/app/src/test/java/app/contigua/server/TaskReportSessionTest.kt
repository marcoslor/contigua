package app.contigua.server

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
        titles: WindowObserver? = null,
    ) {
        logs = CopyOnWriteArrayList()
        connect(taskPresence = presence, taskEvents = events, titleObserver = titles,
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
    fun aRemovedStreamTaskWithAnEmptyDisplayClosesAppExited() {
        val events = FakeTaskEvents()
        connectWithEvents(events, FixedPresence(hasTask = false, taskId = 7))
        openChrome()

        events.emit(TaskStackEvent.Removed(taskId = 7))
        val closed = readUntil("window.closed")

        assertEquals("app_exited", closed["reason"])
    }

    /**
     * ISS-33: the app's own picker sits on the streamed display above the app's
     * task; when the person backs out of it the picker's task is removed while
     * the app's task is still there. The window stays, and its task is the
     * app's again — removing that task is then the real exit.
     */
    @Test
    fun aClosedSheetLeavesTheWindowAndRepointsToTheAppsTask() {
        val events = FakeTaskEvents()
        val presence = FixedPresence(hasTask = true, taskId = 7)
        // The app's task is 7; its own picker became the display's top task.
        var top = TopTask(chrome, "Share", 42)
        connectWithEvents(events, presence, exitPollMs = 20, titles = { top })
        openChrome()
        readUntilTitle("Share")

        // The person backs out: the picker's task is removed, the app's stays.
        top = TopTask(chrome, "Chrome", 7)
        presence.taskId = 7
        events.emit(TaskStackEvent.Removed(taskId = 42))

        assertFalse("a sheet closing must not close the window",
            logs.any { it.startsWith("closed stream") })

        // The stream is on the app's task again: its removal is the exit.
        presence.hasTask = false
        events.emit(TaskStackEvent.Removed(taskId = 7))
        val closed = readUntil("window.closed")
        assertEquals("app_exited", closed["reason"])
    }

    /** Reads until the title poll names [label]; it also proves the re-point. */
    private fun readUntilTitle(label: String) {
        repeat(40) {
            val m = readJson()
            if (m["t"] == "window.title" && m["title"] == label) return
        }
        error("never received the '$label' title")
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
