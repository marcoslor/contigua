package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WIN-46 on a real session: `window.adopt` opens another display, moves the
 * named task there and answers `started: "moved"`; a refusal closes that display
 * and answers `cannot_adopt` without touching the first stream.
 */
class TaskAdoptSessionTest : SessionFixture() {

    private val chrome = "com.android.chrome"

    private fun openFirst(mover: FakeTaskMove): Int {
        connect(taskMove = mover, taskPresence = FixedPresence(hasTask = true, taskId = 7))
        open(1, chrome)
        readUntil("window.opened")
        return platform.opens.single().displayId
    }

    private fun adopt(stream: Int = 2, taskId: Int = 42) {
        send(mapOf("t" to "window.adopt", "stream" to stream, "taskId" to taskId,
                   "pkg" to chrome, "w" to 640, "h" to 480, "dpi" to 160))
    }

    @Test
    fun adoptMovesTheTaskAndAnswersWithTheAdoptedId() {
        val mover = FakeTaskMove()
        openFirst(mover)

        adopt()
        val opened = readUntil("window.opened")

        assertEquals(2, opened.intValue("stream"))
        assertEquals(42, opened.intValue("taskId"))
        assertEquals("moved", opened["started"])
        assertEquals(1, mover.adoptCalls.size)
        assertEquals(42, mover.adoptCalls[0].first)
        assertEquals(platform.opens.last().displayId, mover.adoptCalls[0].second)
        assertEquals(640, opened.intValue("w"))
        assertEquals(480, opened.intValue("h"))
    }

    @Test
    fun aRefusedAdoptClosesItsDisplayAndLeavesTheTask() {
        val mover = FakeTaskMove().apply { adoptResult = false }
        openFirst(mover)
        val launchesBefore = platform.launches.size

        adopt()
        val error = readUntil("error")

        assertEquals("cannot_adopt", error["code"])
        assertEquals(2, error.intValue("stream"))
        assertTrue(platform.closes.contains(2))
        // The task was left alone: no remove, no relaunch.
        assertTrue(mover.removes.isEmpty())
        assertEquals("the adopt never relaunches", launchesBefore, platform.launches.size)
    }

    @Test
    fun theFirstStreamIsUntouchedByAnAdopt() {
        val mover = FakeTaskMove()
        val firstDisplay = openFirst(mover)

        adopt()
        readUntil("window.opened")

        assertFalse(platform.closes.contains(1))
        assertEquals("one new display for the adopt", 2, platform.opens.size)
        assertTrue(platform.opens.any { it.displayId == firstDisplay && it.stream == 1 })
    }
}
