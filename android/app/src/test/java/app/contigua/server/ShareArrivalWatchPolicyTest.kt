package app.contigua.server

import app.contigua.server.ShareArrivalWatch.Action
import app.contigua.server.ShareArrivalWatch.ListedTask
import app.contigua.server.ShareArrivalWatch.State
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * ISS-51: the arrival watch's timing and transitions. The first read is the
 * caller's, at once; re-reads are 16 ms apart; a task that never appears gives
 * up after about one second with one log action.
 */
class ShareArrivalWatchPolicyTest {

    private val chrome = "com.android.chrome"
    private val now = 10_000L

    private fun window(
        stream: Int = 1,
        displayId: Int = 100,
        shareAtMs: Long? = now - 200,
    ) = ShareArrivalPolicy.Window(stream, chrome, displayId, shareAtMs)

    private fun phoneTask(displayId: Int = ShareArrivalPolicy.PHONE_DISPLAY) =
        ListedTask(chrome, displayId)

    private fun watch(windows: List<ShareArrivalPolicy.Window> = listOf(window())) =
        ShareArrivalWatch(windows)

    @Test
    fun theWatchStartsWaitingForTheCallersFirstRead() {
        assertEquals(State.Waiting(ShareArrivalWatch.MAX_TRIES, now), watch().start(now))
    }

    @Test
    fun aMissingTaskSchedulesTheNextReadAfterSixteenMilliseconds() {
        val (next, actions) = watch().onRead(watch().start(now), null, now)
        assertEquals(State.Waiting(ShareArrivalWatch.MAX_TRIES - 1, now), next)
        assertEquals(listOf(Action.RetryAfter(16)), actions)
    }

    @Test
    fun aTaskNeverListedGivesUpAtTheSixtyThirdReadWithinOneSecond() {
        val watch = watch()
        var state = watch.start(now)
        repeat(ShareArrivalWatch.MAX_TRIES - 1) { index ->
            val read = watch.onRead(state, null, now + index * 16L)
            assertEquals(listOf(Action.RetryAfter(16)), read.second)
            state = read.first
        }
        val lastReadAt = now + (ShareArrivalWatch.MAX_TRIES - 1) * 16L
        val (next, actions) = watch.onRead(state, null, lastReadAt)
        val elapsed = lastReadAt - now
        assertEquals(State.GaveUp(elapsed), next)
        assertEquals(listOf(Action.LogGaveUp), actions)
        assertEquals(992L, elapsed)
    }

    @Test
    fun aTaskListedOnTheThirdReadIsMovedAtTheThirdRead() {
        val watch = watch()
        var state = watch.start(now)
        repeat(2) { index ->
            val (next, actions) = watch.onRead(state, null, now + index * 16L)
            assertEquals(listOf(Action.RetryAfter(16)), actions)
            state = next
        }
        val (found, actions) = watch.onRead(state, phoneTask(), now + 32L)
        assertEquals(State.Found(phoneTask(), Action.Move(1, 100)), found)
        assertEquals(listOf(Action.Move(1, 100)), actions)
    }

    @Test
    fun aTaskAlreadyOnTheWindowsDisplayIsKept() {
        val watch = watch()
        val (kept, actions) = watch.onRead(watch.start(now), phoneTask(displayId = 100), now)
        assertEquals(State.Kept(phoneTask(displayId = 100)), kept)
        assertEquals(emptyList<Action>(), actions)
    }

    @Test
    fun aTaskWithNoShareTriggerIsKept() {
        val watch = watch(emptyList())
        val (kept, actions) = watch.onRead(watch.start(now), phoneTask(), now)
        assertEquals(State.Kept(phoneTask()), kept)
        assertEquals(emptyList<Action>(), actions)
    }

    @Test
    fun theMoveAnswerSettlesAMovedOrKeptArrival() {
        val found = State.Found(phoneTask(), Action.Move(1, 100))
        assertEquals(State.Moved(1, 100), watch().onMoved(found, moved = true))
        assertEquals(State.Kept(phoneTask()), watch().onMoved(found, moved = false))
    }

    @Test
    fun everyOtherStateIgnoresAReadAndAMove() {
        val watch = watch()
        val kept = State.Kept(phoneTask())
        val moved = State.Moved(1, 100)
        val gaveUp = State.GaveUp(992)
        for (state in listOf(kept, moved, gaveUp)) {
            assertEquals(state to emptyList<Action>(), watch.onRead(state, phoneTask(), now))
            assertEquals(state, watch.onMoved(state, moved = true))
        }
        val waiting = watch.start(now)
        assertEquals(waiting, watch.onMoved(waiting, moved = true))
        // Found ignores a second read; its move transition is the test above.
        val found = State.Found(phoneTask(), Action.Move(1, 100))
        assertEquals(found to emptyList<Action>(), watch.onRead(found, phoneTask(), now))
    }
}
