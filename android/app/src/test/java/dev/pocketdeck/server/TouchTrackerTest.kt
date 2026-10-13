package dev.pocketdeck.server

import dev.pocketdeck.proto.Frames
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TouchTrackerTest {

    private val logged = mutableListOf<String>()
    private val tracker = TouchTracker { logged += it }

    private fun touch(
        action: Int,
        pointerId: Int,
        nx: Float = 0.5f,
        ny: Float = 0.5f,
        downTime: Long = 0L,
        eventTime: Long = 0L,
        displayId: Int = 1,
    ) = tracker.onTouch(displayId, action, pointerId, nx, ny, downTime, eventTime)

    private fun ids(ev: TouchTracker.Event?) = ev!!.pointers.map { it.id }

    @Test
    fun pinchSequenceUsesPointerDownAndUpWithIndices() {
        val down0 = touch(Frames.TOUCH_DOWN, 0, 0.45f, 0.5f, downTime = 100, eventTime = 100)!!
        val down1 = touch(Frames.TOUCH_DOWN, 1, 0.55f, 0.5f, downTime = 110, eventTime = 110)!!
        val move0 = touch(Frames.TOUCH_MOVE, 0, 0.40f, 0.5f, eventTime = 120)!!
        val move1 = touch(Frames.TOUCH_MOVE, 1, 0.60f, 0.5f, eventTime = 121)!!
        val up1 = touch(Frames.TOUCH_UP, 1, 0.60f, 0.5f, eventTime = 130)!!
        val up0 = touch(Frames.TOUCH_UP, 0, 0.40f, 0.5f, eventTime = 131)!!

        assertEquals(
            listOf(
                TouchTracker.Kind.DOWN,
                TouchTracker.Kind.POINTER_DOWN,
                TouchTracker.Kind.MOVE,
                TouchTracker.Kind.MOVE,
                TouchTracker.Kind.POINTER_UP,
                TouchTracker.Kind.UP,
            ),
            listOf(down0, down1, move0, move1, up1, up0).map { it.kind },
        )
        assertEquals(0, down0.actionIndex)
        assertEquals(1, down1.actionIndex)
        assertEquals(1, up1.actionIndex)
        assertEquals(0, up0.actionIndex)
        assertEquals(listOf(0), ids(down0))
        assertEquals(listOf(0, 1), ids(down1))
        assertEquals(listOf(0, 1), ids(move1))
        assertEquals(listOf(0, 1), ids(up1))
        assertEquals(listOf(0), ids(up0))
    }

    @Test
    fun movesCarryBothPointersWithTheMovedCoordinateUpdated() {
        touch(Frames.TOUCH_DOWN, 0, 0.45f, 0.5f)
        touch(Frames.TOUCH_DOWN, 1, 0.55f, 0.5f)
        val move = touch(Frames.TOUCH_MOVE, 1, 0.70f, 0.6f)!!

        assertEquals(TouchTracker.Pointer(0, 0.45f, 0.5f), move.pointers[0])
        assertEquals(TouchTracker.Pointer(1, 0.70f, 0.6f), move.pointers[1])
    }

    @Test
    fun pointerUpSnapshotKeepsReleasedPointerAndRemovesItAfterwards() {
        touch(Frames.TOUCH_DOWN, 0)
        touch(Frames.TOUCH_DOWN, 1)
        touch(Frames.TOUCH_DOWN, 2)
        val upMiddle = touch(Frames.TOUCH_UP, 1)!!
        assertEquals(TouchTracker.Kind.POINTER_UP, upMiddle.kind)
        assertEquals(1, upMiddle.actionIndex)
        assertEquals(listOf(0, 1, 2), ids(upMiddle))
        assertEquals(listOf(0, 2), ids(touch(Frames.TOUCH_MOVE, 2)))
    }

    @Test
    fun releasingFirstPointerReportsIndexZero() {
        touch(Frames.TOUCH_DOWN, 0)
        touch(Frames.TOUCH_DOWN, 1)
        val up = touch(Frames.TOUCH_UP, 0)!!
        assertEquals(TouchTracker.Kind.POINTER_UP, up.kind)
        assertEquals(0, up.actionIndex)
        assertEquals(listOf(1), ids(touch(Frames.TOUCH_MOVE, 1)))
    }

    @Test
    fun cancelCarriesAllPointersThenClears() {
        touch(Frames.TOUCH_DOWN, 0, downTime = 50, eventTime = 50)
        touch(Frames.TOUCH_DOWN, 1, downTime = 60, eventTime = 60)
        val cancel = touch(Frames.TOUCH_CANCEL, 0, eventTime = 70)!!

        assertEquals(TouchTracker.Kind.CANCEL, cancel.kind)
        assertEquals(listOf(0, 1), ids(cancel))
        assertEquals(50L, cancel.downTime)
        assertNull(touch(Frames.TOUCH_MOVE, 0))
        assertNull(touch(Frames.TOUCH_CANCEL, 0))

        val next = touch(Frames.TOUCH_DOWN, 0, downTime = 200, eventTime = 200)!!
        assertEquals(TouchTracker.Kind.DOWN, next.kind)
        assertEquals(200L, next.downTime)
    }

    @Test
    fun moveForUnknownPointerIsIgnoredAndLoggedOnce() {
        touch(Frames.TOUCH_DOWN, 0)
        assertNull(touch(Frames.TOUCH_MOVE, 5))
        assertNull(touch(Frames.TOUCH_MOVE, 5))
        assertEquals(1, logged.size)
        assertEquals(listOf(0), ids(touch(Frames.TOUCH_MOVE, 0)))
    }

    @Test
    fun upForUnknownPointerIsIgnored() {
        touch(Frames.TOUCH_DOWN, 0)
        assertNull(touch(Frames.TOUCH_UP, 1))
        assertEquals(TouchTracker.Kind.UP, touch(Frames.TOUCH_UP, 0)!!.kind)
    }

    @Test
    fun duplicateDownBecomesMoveKeepingDownTime() {
        touch(Frames.TOUCH_DOWN, 0, 0.1f, 0.1f, downTime = 10, eventTime = 10)
        val again = touch(Frames.TOUCH_DOWN, 0, 0.2f, 0.3f, downTime = 99, eventTime = 20)!!

        assertEquals(TouchTracker.Kind.MOVE, again.kind)
        assertEquals(listOf(TouchTracker.Pointer(0, 0.2f, 0.3f)), again.pointers)
        assertEquals(10L, again.downTime)
    }

    @Test
    fun secondPointerDownKeepsTheGestureDownTime() {
        touch(Frames.TOUCH_DOWN, 0, downTime = 100, eventTime = 100)
        val second = touch(Frames.TOUCH_DOWN, 1, downTime = 105, eventTime = 105)!!
        assertEquals(100L, second.downTime)
        assertEquals(105L, second.eventTime)
    }

    @Test
    fun pointerIdsAtOrAboveTenAreIgnored() {
        assertNull(touch(Frames.TOUCH_DOWN, 10))
        assertNull(touch(Frames.TOUCH_DOWN, 255))
        assertEquals(1, logged.size)
        assertEquals(TouchTracker.Kind.DOWN, touch(Frames.TOUCH_DOWN, 9)!!.kind)
    }

    @Test
    fun unknownActionIsIgnored() {
        assertNull(touch(42, 0))
        assertEquals(1, logged.size)
    }

    @Test
    fun displaysTrackPointersIndependently() {
        assertEquals(TouchTracker.Kind.DOWN, touch(Frames.TOUCH_DOWN, 0, displayId = 1)!!.kind)
        assertEquals(TouchTracker.Kind.DOWN, touch(Frames.TOUCH_DOWN, 0, displayId = 2)!!.kind)
        assertEquals(TouchTracker.Kind.POINTER_DOWN, touch(Frames.TOUCH_DOWN, 1, displayId = 1)!!.kind)
        assertEquals(TouchTracker.Kind.UP, touch(Frames.TOUCH_UP, 0, displayId = 2)!!.kind)
        assertEquals(listOf(0, 1), ids(touch(Frames.TOUCH_MOVE, 0, displayId = 1)))
    }

    @Test
    fun singleFingerGestureIsDownMoveUpWithOneGestureDownTime() {
        val down = touch(Frames.TOUCH_DOWN, 0, 0.5f, 0.8f, downTime = 1000, eventTime = 1000)!!
        val move = touch(Frames.TOUCH_MOVE, 0, 0.5f, 0.7f, downTime = 1000, eventTime = 1016)!!
        val up = touch(Frames.TOUCH_UP, 0, 0.5f, 0.7f, downTime = 1000, eventTime = 1032)!!

        assertEquals(listOf(TouchTracker.Kind.DOWN, TouchTracker.Kind.MOVE, TouchTracker.Kind.UP),
            listOf(down.kind, move.kind, up.kind))
        assertEquals(listOf(1000L, 1000L, 1000L), listOf(down.downTime, move.downTime, up.downTime))
        assertEquals(listOf(1000L, 1016L, 1032L), listOf(down.eventTime, move.eventTime, up.eventTime))
        assertEquals(listOf(0), ids(down))
        assertEquals(listOf(0), ids(move))
        assertEquals(listOf(0), ids(up))
        assertEquals(TouchTracker.Pointer(0, 0.5f, 0.7f), move.pointers[0])
        assertEquals(0, down.actionIndex)
        assertEquals(0, move.actionIndex)
        assertEquals(0, up.actionIndex)
        assertEquals(TouchTracker.Pointer(0, 0.5f, 0.8f), down.pointers[0])
        assertEquals(TouchTracker.Pointer(0, 0.5f, 0.7f), up.pointers[0])
    }

    @Test
    fun nextGestureGetsItsOwnDownTime() {
        touch(Frames.TOUCH_DOWN, 0, downTime = 100, eventTime = 100)
        touch(Frames.TOUCH_UP, 0, downTime = 100, eventTime = 110)
        val second = touch(Frames.TOUCH_DOWN, 0, downTime = 500, eventTime = 500)!!
        assertEquals(500L, second.downTime)
        assertEquals(TouchTracker.Kind.DOWN, second.kind)
    }
}
