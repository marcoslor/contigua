package app.contigua.server

import android.view.accessibility.AccessibilityEvent
import app.contigua.server.SettleWatch.Action
import app.contigua.server.SettleWatch.Event
import app.contigua.server.SettleWatch.State
import java.util.ArrayDeque
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * MCP-81/MCP-107: the phone's settle watch, one test per row of
 * docs/specs/mcp.md "Settling a display". The machine is pure: [runWatch]
 * drives it with explicit events and a clock that honours its own
 * `ScheduleTick` actions (one pending tick; a new one replaces it).
 */
class SettleWatchTest {

    /** A loading result for the latest check the machine asked for. */
    private data class Found(val found: Boolean, val now: Long)

    /**
     * Feeds [feed] (events and [Found] results) at their own times, firing the
     * machine's scheduled tick whenever it comes first. Returns the first reply.
     */
    private fun runWatch(
        quietMs: Long = 300, timeoutMs: Long = 2_000, feed: List<Any> = emptyList(), windowed: Boolean = true,
    ): Action.Reply? {
        var state: State = State.Idle
        var reply: Action.Reply? = null
        var lastCheck = 0
        var nextTick = Long.MAX_VALUE
        val queue = ArrayDeque(feed)

        fun apply(event: Event) {
            val step = SettleWatch.reduce(state, event)
            state = step.state
            for (action in step.actions) when (action) {
                is Action.ScheduleTick -> nextTick = action.atMs
                is Action.CheckLoading -> lastCheck = action.check
                is Action.Reply -> if (reply == null) reply = action
                else -> Unit
            }
        }

        fun timeOf(item: Any): Long = when (item) {
            is Found -> item.now
            is Event.A11y -> item.now
            else -> error("unsupported feed item $item")
        }

        apply(Event.Start(quietMs, timeoutMs, 0, windowed))
        while (reply == null) {
            val next = queue.peekFirst()
            if (next == null && nextTick == Long.MAX_VALUE) return null
            val eventTime = next?.let(::timeOf) ?: Long.MAX_VALUE
            if (nextTick <= eventTime) {
                val at = nextTick
                nextTick = Long.MAX_VALUE
                apply(Event.Tick(at))
            } else {
                queue.removeFirst()
                when (next) {
                    is Found -> apply(Event.Loading(next.found, lastCheck, next.now))
                    is Event -> apply(next)
                }
            }
        }
        return reply
    }

    private fun content(now: Long) = Event.A11y(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED, true, now)
    private fun watching() = SettleWatch.reduce(State.Idle, Event.Start(300, 2_000, 0)).state
    private fun checking(): State {
        val step = SettleWatch.reduce(watching(), Event.Tick(300))
        assertTrue(step.state is State.Checking)
        return step.state
    }

    // Idle

    @Test
    fun testStartListensAndTicksAfterQuietMs() { // [MCP-81]
        val step = SettleWatch.reduce(State.Idle, Event.Start(300, 2_000, 50))
        assertEquals(State.Watching(300, 2_000, start = 50, lastChange = 50, events = 0, loading = false, check = 0), step.state)
        assertEquals(listOf(Action.Listen, Action.ScheduleTick(350)), step.actions)
    }

    @Test
    fun testATimeoutShorterThanQuietMsTicksAtTheTimeout() { // [MCP-81]
        val step = SettleWatch.reduce(State.Idle, Event.Start(2_000, 200, 0))
        assertTrue(Action.ScheduleTick(200) in step.actions)
        assertEquals(Action.Reply.StillChanging(200, 0, "changes"), runWatch(quietMs = 2_000, timeoutMs = 200))
    }

    @Test
    fun testIdleIgnoresEverythingButStart() { // [MCP-81]
        for (event in listOf(content(1), Event.Tick(1), Event.SessionEnd)) {
            assertEquals(SettleWatch.Step(State.Idle, emptyList()), SettleWatch.reduce(State.Idle, event))
        }
    }

    @Test
    fun testALateLoadingCheckIsIgnored() { // [MCP-81]
        assertEquals(SettleWatch.Step(State.Idle, emptyList()), SettleWatch.reduce(State.Idle, Event.Loading(true, 1, 100)))
    }

    // Watching

    @Test
    fun testQuietForQuietMsSettles() { // [MCP-81]
        assertEquals(Action.Reply.Settled(400, 1), runWatch(feed = listOf(content(100), Found(false, 400))))
    }

    @Test
    fun testATickBeforeTheQuietPeriodWaitsForIt() { // [MCP-81]
        val changed = SettleWatch.reduce(watching(), content(100)).state
        val step = SettleWatch.reduce(changed, Event.Tick(300))
        assertEquals(changed, step.state)
        assertEquals(listOf(Action.ScheduleTick(400)), step.actions)
    }

    @Test
    fun testTimeoutAnswersNotSettled() { // [MCP-81]
        val feed = (100L..2_100L step 100).map { content(it) }
        assertEquals(Action.Reply.StillChanging(2_000, 19, "changes"), runWatch(feed = feed))
    }

    @Test
    fun testAnotherDisplaysEventsAreIgnored() { // [MCP-81]
        val other = Event.A11y(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED, false, 100)
        assertEquals(SettleWatch.Step(watching(), emptyList()), SettleWatch.reduce(watching(), other))
        assertEquals(Action.Reply.Settled(300, 0), runWatch(feed = listOf(other, Found(false, 300))))
    }

    @Test
    fun testASecondStartIsBusy() { // [MCP-81]
        for (state in listOf(watching(), checking())) {
            val step = SettleWatch.reduce(state, Event.Start(300, 2_000, 100))
            assertEquals(state, step.state)
            assertEquals(listOf(Action.Reply.Busy), step.actions)
        }
    }

    @Test
    fun testDisplayGoneAnswersNoDisplay() { // [MCP-81]
        // The check finds the display no longer listed, after it had a window.
        val step = SettleWatch.reduce(checking(), Event.Loading(false, 1, 320, listed = false))
        assertEquals(State.Idle, step.state)
        assertEquals(listOf(Action.StopListening, Action.Reply.NoDisplay), step.actions)
    }

    @Test
    fun testSessionEndRepliesNothing() { // [MCP-81]
        for (state in listOf(watching(), checking())) {
            assertEquals(SettleWatch.Step(State.Idle, listOf(Action.StopListening)), SettleWatch.reduce(state, Event.SessionEnd))
        }
    }

    // Checking

    @Test
    fun testTheQuietPeriodStartsACheckAndArmsTheTimeout() { // [MCP-107]
        val step = SettleWatch.reduce(watching(), Event.Tick(300))
        assertEquals(State.Checking(300, 2_000, 0, 0, 0, false, check = 1), step.state)
        assertEquals(listOf(Action.CheckLoading(1), Action.ScheduleTick(2_000)), step.actions)
    }

    @Test
    fun testAChangeDuringACheckWatchesAgain() { // [MCP-107]
        val step = SettleWatch.reduce(checking(), content(350))
        assertEquals(State.Watching(300, 2_000, 0, 350, 1, false, check = 1), step.state)
        assertEquals(listOf(Action.ScheduleTick(650)), step.actions)
    }

    @Test
    fun testACheckDroppedByAChangeIsIgnored() { // [MCP-107]
        // Check 1 is in flight when a change comes; its "nothing loading" must
        // not settle the watch, nor be taken for check 2's answer.
        val afterChange = SettleWatch.reduce(checking(), content(350)).state
        assertEquals(SettleWatch.Step(afterChange, emptyList()), SettleWatch.reduce(afterChange, Event.Loading(false, 1, 360)))
        val second = SettleWatch.reduce(afterChange, Event.Tick(650))
        assertEquals(listOf(Action.CheckLoading(2), Action.ScheduleTick(2_000)), second.actions)
        assertEquals(SettleWatch.Step(second.state, emptyList()), SettleWatch.reduce(second.state, Event.Loading(false, 1, 660)))
        val settled = SettleWatch.reduce(second.state, Event.Loading(false, 2, 700))
        assertEquals(listOf(Action.StopListening, Action.Reply.Settled(700, 1)), settled.actions)
    }

    @Test
    fun testAnOtherEventDuringACheckIsIgnored() { // [MCP-107]
        val focus = Event.A11y(AccessibilityEvent.TYPE_VIEW_FOCUSED, true, 350)
        assertEquals(SettleWatch.Step(checking(), emptyList()), SettleWatch.reduce(checking(), focus))
    }

    @Test
    fun testATickBeforeTheTimeoutDuringACheckWaits() { // [MCP-107]
        assertEquals(SettleWatch.Step(checking(), emptyList()), SettleWatch.reduce(checking(), Event.Tick(1_000)))
    }

    @Test
    fun testATimeoutDuringACheckAnswers() { // [MCP-107]
        // The check never comes back: the timeout tick still answers.
        val step = SettleWatch.reduce(checking(), Event.Tick(2_000))
        assertEquals(State.Idle, step.state)
        assertEquals(listOf(Action.StopListening, Action.Reply.StillChanging(2_000, 0, "changes")), step.actions)
    }

    @Test
    fun testOnlyContentChangesCount() { // [MCP-107]
        val feed = buildList<Any> {
            for (now in 50L..1_000L step 50) {
                add(Event.A11y(AccessibilityEvent.TYPE_VIEW_FOCUSED, true, now))
                add(Event.A11y(AccessibilityEvent.TYPE_VIEW_CLICKED, true, now))
                if (now == 300L) add(Found(false, 300))
            }
        }
        assertEquals(Action.Reply.Settled(300, 0), runWatch(feed = feed))
    }

    @Test
    fun testEveryListedTypeIsAContentChange() { // [MCP-107]
        val counted = listOf(
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED, AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            AccessibilityEvent.TYPE_WINDOWS_CHANGED, AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED,
            AccessibilityEvent.TYPE_VIEW_SCROLLED,
        )
        val ignored = listOf(
            AccessibilityEvent.TYPE_VIEW_FOCUSED, AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUSED,
            AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED, AccessibilityEvent.TYPE_VIEW_SELECTED,
            AccessibilityEvent.TYPE_VIEW_CLICKED, AccessibilityEvent.TYPE_VIEW_HOVER_ENTER,
            AccessibilityEvent.TYPE_ANNOUNCEMENT, AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED,
        )
        for (type in counted) assertTrue("type $type counts", SettleWatch.isContentChange(type))
        for (type in ignored) assertTrue("type $type is ignored", !SettleWatch.isContentChange(type))
    }

    @Test
    fun testASpinnerKeepsTheWatchOpen() { // [MCP-107]
        val reply = runWatch(feed = listOf(Found(true, 300), Found(true, 600), Found(false, 900)))
        assertEquals(Action.Reply.Settled(900, 0), reply)
    }

    @Test
    fun testALoadingCheckTicksAgainAfterAQuietPeriod() { // [MCP-107]
        val step = SettleWatch.reduce(checking(), Event.Loading(true, 1, 320))
        assertEquals(State.Watching(300, 2_000, 0, 0, 0, true, check = 1), step.state)
        assertEquals(listOf(Action.ScheduleTick(620)), step.actions)
    }

    @Test
    fun testATimeoutWhileLoadingSaysLoading() { // [MCP-107]
        val feed = (300L..1_800L step 300).map { Found(true, it) }
        assertEquals(Action.Reply.StillChanging(2_000, 0, "loading"), runWatch(feed = feed))
    }

    @Test
    fun testATimeoutAfterAChangeSaysChanges() { // [MCP-107]
        val feed = (300L..1_800L step 300).map<Long, Any> { Found(true, it) } + content(1_900)
        assertEquals(Action.Reply.StillChanging(2_000, 1, "changes"), runWatch(feed = feed))
    }

    // A display with no window yet is still opening (MCP-103, MCP-107)

    private fun opening() = SettleWatch.reduce(State.Idle, Event.Start(300, 2_000, 0, windowed = false)).state

    @Test
    fun testAnEmptyDisplayIsStillOpening() { // [MCP-107]
        // No window at the start and none arrives: every check finds the
        // display empty, and the timeout says it is still loading.
        val step = SettleWatch.reduce(State.Idle, Event.Start(300, 2_000, 0, windowed = false))
        assertEquals(State.Watching(300, 2_000, 0, 0, 0, loading = true, check = 0, windowed = false), step.state)
        assertEquals(listOf(Action.Listen, Action.ScheduleTick(300)), step.actions)
        val feed = (300L..1_800L step 300).map { Found(true, it) }
        assertEquals(Action.Reply.StillChanging(2_000, 0, "loading"), runWatch(feed = feed, windowed = false))
        assertEquals(Action.Reply.StillChanging(2_000, 0, "loading"), runWatch(windowed = false))
    }

    @Test
    fun testTheFirstWindowIsACountedChange() { // [MCP-107]
        val arrived = SettleWatch.reduce(opening(), content(500))
        assertEquals(State.Watching(300, 2_000, 0, 500, 1, loading = false, check = 0, windowed = true), arrived.state)
        val reply = runWatch(feed = listOf(Found(true, 300), content(500), Found(false, 800)), windowed = false)
        assertEquals(Action.Reply.Settled(800, 1), reply)
    }

    @Test
    fun testAnUnlistedDisplayBeforeItsFirstWindowIsLoading() { // [MCP-107]
        // A check that finds the display not listed yet is a loading signal,
        // not a gone display: the watch keeps going.
        val checkingOpen = SettleWatch.reduce(opening(), Event.Tick(300)).state
        assertTrue(checkingOpen is State.Checking)
        val step = SettleWatch.reduce(checkingOpen, Event.Loading(false, 1, 320, listed = false))
        assertEquals(State.Watching(300, 2_000, 0, 0, 0, loading = true, check = 1, windowed = false), step.state)
        assertEquals(listOf(Action.ScheduleTick(620)), step.actions)
    }

    @Test
    fun testADisplayGoneAfterItsFirstWindowAnswersNoDisplay() { // [MCP-81]
        val arrived = SettleWatch.reduce(opening(), content(100)).state
        val checked = SettleWatch.reduce(arrived, Event.Tick(400)).state
        val step = SettleWatch.reduce(checked, Event.Loading(false, 1, 420, listed = false))
        assertEquals(listOf(Action.StopListening, Action.Reply.NoDisplay), step.actions)
    }
}
