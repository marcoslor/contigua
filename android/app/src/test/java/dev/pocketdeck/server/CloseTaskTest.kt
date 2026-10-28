package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/**
 * WIN-31: `window.close` ends that window's task and nothing else. The display's
 * `FLAG_DESTROY_CONTENT_ON_REMOVAL` usually takes the task with it; a task that
 * survives is removed by id, never by stopping the app (its other windows and
 * the session keep running).
 */
class CloseTaskTest : SessionFixture() {

    private class RecordingMove(
        var listed: List<SystemTask>?,
        private val removeResult: Boolean = true,
    ) : TaskMove {
        val removed = CopyOnWriteArrayList<Int>()

        override fun tasks(): List<SystemTask>? = listed

        override fun move(taskId: Int, displayId: Int): Boolean = false

        override fun remove(taskId: Int): Boolean {
            removed.add(taskId)
            listed = listed?.filter { it.taskId != taskId }
            return removeResult
        }
    }

    /** Each display opened, in order, shows the next of [ids]. */
    private fun presence(vararg ids: Int) = object : TaskPresence {
        private val byDisplay = HashMap<Int, Int>()
        private var next = 0

        override fun hasTask(displayId: Int) = true

        override fun taskId(displayId: Int): Int? = synchronized(byDisplay) {
            byDisplay[displayId] ?: ids.getOrNull(next++)?.also { byDisplay[displayId] = it }
        }
    }

    private fun task(id: Int) = SystemTask(id, "com.a", null, 0, isHome = false, isSystemUi = false)

    @Test
    fun `the mirror has no task to end`() {
        assertEquals(
            CloseTask.Action.NONE,
            CloseTask.decide(CloseTask.Facts(counted = false, taskId = 11, otherTasks = emptySet(), tasksNow = setOf(11))),
        )
    }

    @Test
    fun `a task the display already took is left alone`() {
        assertEquals(
            CloseTask.Action.NONE,
            CloseTask.decide(CloseTask.Facts(counted = true, taskId = 11, otherTasks = emptySet(), tasksNow = setOf(22))),
        )
    }

    @Test
    fun `a task that outlived its display is removed`() {
        assertEquals(
            CloseTask.Action.REMOVE_TASK,
            CloseTask.decide(CloseTask.Facts(counted = true, taskId = 11, otherTasks = setOf(22), tasksNow = setOf(11, 22))),
        )
    }

    @Test
    fun `a task another window shows is never removed`() {
        assertEquals(
            "two windows of one task: ending it would end both",
            CloseTask.Action.NONE,
            CloseTask.decide(CloseTask.Facts(counted = true, taskId = 11, otherTasks = setOf(11), tasksNow = setOf(11))),
        )
    }

    @Test
    fun `an unknown task id or an unreadable task list changes nothing`() {
        assertEquals(CloseTask.Action.NONE, CloseTask.decide(CloseTask.Facts(true, 0, emptySet(), setOf(11))))
        assertEquals(CloseTask.Action.NONE, CloseTask.decide(CloseTask.Facts(true, 11, emptySet(), tasksNow = null)))
    }

    @Test
    fun `closing one window removes only its own task`() {
        val move = RecordingMove(listOf(task(11), task(22)))
        connect(taskPresence = presence(11, 22), taskMove = move)
        open(1, "com.a")
        readUntil("window.opened")
        open(2, "com.a", newInstance = true)
        readUntil("window.opened")

        send(mapOf("t" to "window.close", "stream" to 1))
        readUntil("window.closed")
        assertEquals("only the closed window's task", listOf(11), move.removed)

        // The other window and the session are untouched.
        send(mapOf("t" to "ping", "ts" to 5))
        assertEquals(5L, readUntil("pong")["ts"])
        send(mapOf("t" to "window.resize", "stream" to 2, "w" to 600, "h" to 400, "dpi" to 160))
        assertEquals(2L, readUntil("window.resize.ack")["stream"])
        assertEquals(listOf(1), platform.closes)
    }

    @Test
    fun `a task the display took with it is not removed twice`() {
        val move = RecordingMove(emptyList())
        connect(taskPresence = presence(11), taskMove = move)
        open(1, "com.a")
        readUntil("window.opened")
        send(mapOf("t" to "window.close", "stream" to 1))
        readUntil("window.closed")
        assertTrue("the display's own removal did it", move.removed.isEmpty())
    }

    @Test
    fun `closing the phone mirror ends no task`() {
        val move = RecordingMove(listOf(task(11)))
        connect(taskPresence = presence(11), taskMove = move)
        open(1, "com.a", phone = true)
        readUntil("window.opened")
        send(mapOf("t" to "window.close", "stream" to 1))
        readUntil("window.closed")
        assertTrue(move.removed.isEmpty())
    }

    @Test
    fun `two windows of one task never end each other`() {
        val move = RecordingMove(listOf(task(11)))
        connect(taskPresence = presence(11, 11), taskMove = move)
        open(1, "com.a")
        readUntil("window.opened")
        open(2, "com.a", newInstance = true)
        readUntil("window.opened")
        send(mapOf("t" to "window.close", "stream" to 1))
        readUntil("window.closed")
        assertTrue("the task a live window still shows is not removed", move.removed.isEmpty())
    }
}
