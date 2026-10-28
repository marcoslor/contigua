package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WIN-28: an app stream's `window.title` goes out at most once a second, the
 * newest label always goes out, and a label that settles the instant after a
 * send is not dropped.
 */
class TaskLabelThrottleTest : SessionFixture() {

    private fun send(label: String, at: Long) =
        TaskLabelThrottle.transition(TaskLabelThrottle.State(), TaskLabelThrottle.Event.Label(label, at))

    @Test
    fun `the first label goes out at once`() {
        val first = send("Alpha", 1_000)
        assertEquals(listOf(TaskLabelThrottle.Action.Send("Alpha")), first.actions)
        assertEquals(TaskLabelThrottle.Phase.SENT, first.state.phase)
        assertEquals("Alpha", first.state.sent)
        assertEquals(1_000L, first.state.sentAtMs)
    }

    @Test
    fun `a label inside the second waits for it instead of being dropped`() {
        val held = TaskLabelThrottle.transition(
            send("Alpha", 1_000).state,
            TaskLabelThrottle.Event.Label("Beta", 1_200),
        )
        assertEquals(emptyList<TaskLabelThrottle.Action>(), held.actions.filterIsInstance<TaskLabelThrottle.Action.Send>())
        assertEquals(listOf(TaskLabelThrottle.Action.Wake(2_000)), held.actions)
        assertEquals(TaskLabelThrottle.Phase.HOLDING, held.state.phase)
        assertEquals("Beta", held.state.latest)
    }

    @Test
    fun `the held label goes out when its second is up`() {
        val state = TaskLabelThrottle.State(
            phase = TaskLabelThrottle.Phase.HOLDING, sent = "Alpha", latest = "Beta", sentAtMs = 1_000,
        )
        assertEquals(
            listOf(TaskLabelThrottle.Action.Wake(2_000)),
            TaskLabelThrottle.transition(state, TaskLabelThrottle.Event.Wake(1_500)).actions,
        )
        val sent = TaskLabelThrottle.transition(state, TaskLabelThrottle.Event.Wake(2_000))
        assertEquals(listOf(TaskLabelThrottle.Action.Send("Beta")), sent.actions)
        assertEquals(TaskLabelThrottle.Phase.SENT, sent.state.phase)
        assertEquals(2_000L, sent.state.sentAtMs)
    }

    @Test
    fun `several changes inside the second send only the last one`() {
        var state = send("A", 0).state
        for ((i, label) in listOf("B", "C", "D").withIndex()) {
            state = TaskLabelThrottle.transition(state, TaskLabelThrottle.Event.Label(label, 100L + i * 100)).state
        }
        val actions = TaskLabelThrottle.transition(state, TaskLabelThrottle.Event.Wake(1_000)).actions
        assertEquals(listOf(TaskLabelThrottle.Action.Send("D")), actions)
    }

    @Test
    fun `the same label twice sends once`() {
        var state = send("Alpha", 0).state
        val again = TaskLabelThrottle.transition(state, TaskLabelThrottle.Event.Label("Alpha", 500))
        assertEquals(emptyList<TaskLabelThrottle.Action>(), again.actions)
        state = again.state
        assertEquals(emptyList<TaskLabelThrottle.Action>(), TaskLabelThrottle.transition(state, TaskLabelThrottle.Event.Wake(1_000)).actions)
    }

    @Test
    fun `a label that comes back to the sent one stops waiting`() {
        var state = send("Alpha", 0).state
        state = TaskLabelThrottle.transition(state, TaskLabelThrottle.Event.Label("Beta", 100)).state
        assertEquals(TaskLabelThrottle.Phase.HOLDING, state.phase)
        val back = TaskLabelThrottle.transition(state, TaskLabelThrottle.Event.Label("Alpha", 200))
        assertEquals(emptyList<TaskLabelThrottle.Action>(), back.actions)
        assertEquals(TaskLabelThrottle.Phase.SENT, back.state.phase)
        assertEquals(emptyList<TaskLabelThrottle.Action>(), TaskLabelThrottle.transition(back.state, TaskLabelThrottle.Event.Wake(5_000)).actions)
    }

    @Test
    fun `a wake with nothing waiting is ignored`() {
        val state = send("Alpha", 0).state
        val ignored = TaskLabelThrottle.transition(state, TaskLabelThrottle.Event.Wake(900))
        assertEquals(state, ignored.state)
        assertTrue(ignored.actions.isEmpty())
    }

    @Test
    fun `a label exactly a second later goes at once`() {
        val state = send("Alpha", 1_000).state
        val atOnce = TaskLabelThrottle.transition(state, TaskLabelThrottle.Event.Label("Beta", 2_000))
        assertEquals(listOf(TaskLabelThrottle.Action.Send("Beta")), atOnce.actions)
        assertEquals(TaskLabelThrottle.Phase.SENT, atOnce.state.phase)
    }

    @Test
    fun `each send starts a new second`() {
        var state = TaskLabelThrottle.transition(send("Alpha", 0).state, TaskLabelThrottle.Event.Label("Beta", 1_000)).state
        assertEquals(1_000L, state.sentAtMs)
        val held = TaskLabelThrottle.transition(state, TaskLabelThrottle.Event.Label("Gamma", 1_500))
        assertEquals(listOf(TaskLabelThrottle.Action.Wake(2_000)), held.actions)
    }

    @Test
    fun `an identity change sends at once and counts as the send`() {
        val sent = send("Alpha", 1_000).state
        // Inside the second, a different app is on top: its title may not wait.
        val now = TaskLabelThrottle.transition(sent, TaskLabelThrottle.Event.Immediate("Beta", 1_200))
        assertEquals(listOf(TaskLabelThrottle.Action.Send("Beta")), now.actions)
        assertEquals(TaskLabelThrottle.Phase.SENT, now.state.phase)
        assertEquals("Beta", now.state.sent)
        assertEquals(1_200L, now.state.sentAtMs)
        // ...and that send is the second's: a title that follows is held.
        val held = TaskLabelThrottle.transition(now.state, TaskLabelThrottle.Event.Label("Gamma", 1_300))
        assertEquals(listOf(TaskLabelThrottle.Action.Wake(2_200)), held.actions)
    }

    @Test
    fun `an identity change supersedes a held label`() {
        val holding = TaskLabelThrottle.transition(send("Alpha", 1_000).state, TaskLabelThrottle.Event.Label("Beta", 1_100)).state
        assertEquals(TaskLabelThrottle.Phase.HOLDING, holding.phase)
        val now = TaskLabelThrottle.transition(holding, TaskLabelThrottle.Event.Immediate("Gamma", 1_200))
        assertEquals(listOf(TaskLabelThrottle.Action.Send("Gamma")), now.actions)
        assertEquals("Gamma", now.state.latest)
        assertEquals(emptyList<TaskLabelThrottle.Action>(), TaskLabelThrottle.transition(now.state, TaskLabelThrottle.Event.Wake(9_000)).actions)
    }

    // ------------------------------------------------------------------
    // the session's use of it
    // ------------------------------------------------------------------

    @Volatile private var task: TopTask? = null

    @Test
    fun `an app stream sends its task label, throttled`() {
        task = TopTask("com.a", "Alpha", taskId = 11, taskLabel = "First")
        connect(titleObserver = { task })
        open(1, "com.a")
        readUntil("window.opened")
        val first = readUntil("window.title")
        assertEquals(1L, first["stream"])
        assertEquals("First", first["title"])
        assertEquals("every window.title names its app too", "Alpha", first["label"])
        assertEquals("com.a", first["pkg"])

        // Two labels inside one second: the Mac sees the last one, once.
        task = TopTask("com.a", "Alpha", taskId = 11, taskLabel = "Second")
        val second = readUntil("window.title")
        assertEquals("Second", second["title"])
        task = TopTask("com.a", "Alpha", taskId = 11, taskLabel = "Third")
        val third = readUntil("window.title")
        assertEquals("Third", third["title"])
    }
}
