package app.contigua.server

import app.contigua.proto.Frames

/**
 * Pointer bookkeeping for injected touch, per display. Turns each TOUCH frame into
 * at most one [Event] describing the MotionEvent the injector must build: which
 * action, which pointer index changed, every pointer that is down, and the gesture's
 * downTime. Pure Kotlin so the multi-touch rules run on the JVM.
 *
 * Coordinates stay normalized; the injector scales them with the display size of
 * each event, so a resize between two fingers never mixes units.
 */
internal class TouchTracker(private val log: (String) -> Unit = {}) {

    enum class Kind { DOWN, POINTER_DOWN, MOVE, POINTER_UP, UP, CANCEL }

    data class Pointer(val id: Int, val nx: Float, val ny: Float)

    /**
     * [actionIndex] is the index into [pointers] of the pointer that changed; it is
     * only meaningful for POINTER_DOWN and POINTER_UP and 0 otherwise. For POINTER_UP
     * and UP, [pointers] still includes the released pointer, as Android expects.
     */
    class Event(
        val kind: Kind,
        val actionIndex: Int,
        val pointers: List<Pointer>,
        val downTime: Long,
        val eventTime: Long,
    )

    private class Gesture(val downTime: Long) {
        val pointers = ArrayList<Pointer>()
    }

    private val gestures = HashMap<Int, Gesture>()
    private val loggedReasons = HashSet<String>()

    /**
     * Applies one TOUCH frame on [displayId]. Returns null when the frame has no
     * MotionEvent to inject (unknown pointer, out-of-range id, nothing to cancel).
     */
    @Synchronized
    fun onTouch(
        displayId: Int,
        action: Int,
        pointerId: Int,
        nx: Float,
        ny: Float,
        downTime: Long,
        eventTime: Long,
    ): Event? {
        if (pointerId !in 0 until MAX_POINTERS) return ignore("pointer id out of range")
        val pointer = Pointer(pointerId, nx, ny)
        return when (action) {
            Frames.TOUCH_DOWN -> down(displayId, pointer, downTime, eventTime)
            Frames.TOUCH_MOVE -> move(displayId, pointer, eventTime)
            Frames.TOUCH_UP -> up(displayId, pointerId, eventTime)
            Frames.TOUCH_CANCEL -> cancel(displayId, eventTime)
            else -> ignore("unknown touch action")
        }
    }

    private fun down(displayId: Int, pointer: Pointer, downTime: Long, eventTime: Long): Event {
        val gesture = gestures[displayId]
        if (gesture == null) {
            val created = Gesture(downTime)
            created.pointers.add(pointer)
            gestures[displayId] = created
            return Event(Kind.DOWN, 0, created.pointers.toList(), downTime, eventTime)
        }
        val index = gesture.indexOf(pointer.id)
        if (index >= 0) {
            gesture.pointers[index] = pointer
            return Event(Kind.MOVE, 0, gesture.pointers.toList(), gesture.downTime, eventTime)
        }
        gesture.pointers.add(pointer)
        return Event(Kind.POINTER_DOWN, gesture.pointers.lastIndex, gesture.pointers.toList(), gesture.downTime, eventTime)
    }

    private fun move(displayId: Int, pointer: Pointer, eventTime: Long): Event? {
        val gesture = gestures[displayId]
        val index = gesture?.indexOf(pointer.id) ?: -1
        if (gesture == null || index < 0) return ignore("move for unknown pointer")
        gesture.pointers[index] = pointer
        return Event(Kind.MOVE, 0, gesture.pointers.toList(), gesture.downTime, eventTime)
    }

    private fun up(displayId: Int, pointerId: Int, eventTime: Long): Event? {
        val gesture = gestures[displayId]
        val index = gesture?.indexOf(pointerId) ?: -1
        if (gesture == null || index < 0) return ignore("up for unknown pointer")
        val snapshot = gesture.pointers.toList()
        gesture.pointers.removeAt(index)
        if (gesture.pointers.isEmpty()) {
            gestures.remove(displayId)
            return Event(Kind.UP, 0, snapshot, gesture.downTime, eventTime)
        }
        return Event(Kind.POINTER_UP, index, snapshot, gesture.downTime, eventTime)
    }

    private fun cancel(displayId: Int, eventTime: Long): Event? {
        val gesture = gestures.remove(displayId) ?: return null
        return Event(Kind.CANCEL, 0, gesture.pointers.toList(), gesture.downTime, eventTime)
    }

    private fun Gesture.indexOf(id: Int): Int = pointers.indexOfFirst { it.id == id }

    private fun ignore(reason: String): Event? {
        if (loggedReasons.add(reason)) log("touch ignored: $reason")
        return null
    }

    private companion object {
        /** Pointer ids are small on the wire; anything beyond this is not a finger we track. */
        const val MAX_POINTERS = 10
    }
}
