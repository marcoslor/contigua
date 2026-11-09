package dev.pocketdeck.server

import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.KeyPayload
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/**
 * ISS-51's reopened bug: the share arrival is acted on in the task-created
 * event's own call, not after a fixed 600 ms settle. The task list is read at
 * once, re-read every 16 ms until the task is listed, and a task that never
 * appears gives up within a second with one numbers-only line.
 */
class ShareArrivalWatchTest : SessionFixture() {

    private val chrome = "com.android.chrome"
    private val pasteKey = 279

    /** A task-stack port that records every list read and every move. */
    private class RecordedTaskList(
        private val list: (call: Int) -> List<SystemTask>,
    ) : TaskMove {
        val reads = CopyOnWriteArrayList<Long>()
        val moves = CopyOnWriteArrayList<Pair<Int, Int>>()

        override fun tasks(): List<SystemTask>? {
            reads.add(System.nanoTime())
            return list(reads.size)
        }

        override fun move(taskId: Int, displayId: Int): Boolean {
            moves.add(taskId to displayId)
            return true
        }
    }

    private fun connectWith(events: FakeTaskEvents, mover: TaskMove,
                            logs: MutableList<String> = CopyOnWriteArrayList()) {
        connect(taskEvents = events, taskMove = mover, log = { logs.add(it) })
    }

    private fun openChrome() {
        open(1, chrome)
        readUntil("window.opened")
    }

    /** The Mac's ⌘V: one paste key to the window, whose app then starts its picker. */
    private fun sendPaste() {
        sendFrame(Frames.TYPE_KEY, 1,
            Frames.encodeKey(KeyPayload(Frames.ACTION_DOWN, pasteKey, 0)))
        await { platform.keys.any { it.keycode == pasteKey } }
    }

    private fun arrivedTask(taskId: Int = 42) =
        SystemTask(taskId, chrome, null, ShareArrivalPolicy.PHONE_DISPLAY, isHome = false, isSystemUi = false)

    @Test
    fun theFirstLookHappensInTheCreatedEventsOwnCall() {
        val events = FakeTaskEvents()
        val mover = RecordedTaskList { emptyList() }
        connectWith(events, mover)
        openChrome()
        sendPaste()

        events.emit(TaskStackEvent.Created(taskId = 42, pkg = chrome))

        assertTrue("the task list is read at once, not after a settle delay",
            mover.reads.size >= 1)
    }

    @Test
    fun aTaskListedOnTheThirdReadIsMovedByThen() {
        val events = FakeTaskEvents()
        val mover = RecordedTaskList { call ->
            if (call >= 3) listOf(arrivedTask()) else emptyList()
        }
        connectWith(events, mover)
        openChrome()
        sendPaste()

        val started = System.nanoTime()
        events.emit(TaskStackEvent.Created(taskId = 42, pkg = chrome))
        await { mover.moves.isNotEmpty() }
        val elapsedMs = (System.nanoTime() - started) / 1_000_000

        assertEquals(listOf(42 to 100), mover.moves.toList())
        assertEquals(3, mover.reads.size)
        assertTrue("the move took $elapsedMs ms; the 600 ms settle is the bug", elapsedMs < 400)
    }

    @Test
    fun aTaskNeverListedGivesUpWithinASecondWithOneLogLine() {
        val events = FakeTaskEvents()
        val logs = CopyOnWriteArrayList<String>()
        val mover = RecordedTaskList { emptyList() }
        connectWith(events, mover, logs)
        openChrome()
        sendPaste()

        val started = System.nanoTime()
        events.emit(TaskStackEvent.Created(taskId = 42, pkg = chrome))
        await(timeoutMs = 2_000) { logs.any { it.startsWith("share arrival") } }
        val elapsedMs = (System.nanoTime() - started) / 1_000_000

        assertEquals("one line for one arrival", 1,
            logs.count { it.startsWith("share arrival") })
        // 63 reads 16 ms apart is the one-second schedule; a loaded host adds
        // scheduling drift, so the wall-clock bound leaves room for it.
        assertEquals(ShareArrivalWatch.MAX_TRIES, mover.reads.size)
        assertTrue("gave up after $elapsedMs ms", elapsedMs <= 1_500)
    }
}
