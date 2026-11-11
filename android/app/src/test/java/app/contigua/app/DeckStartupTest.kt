package app.contigua.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Every (state, event) pair of the receiver's boot/update decision
 * (docs/specs/phone-app.md PHONE-7, ISS-42). The person's 2026-11-04 update
 * ran the receiver 0.41 s before Shizuku's binder arrived; the deck then did
 * not start at all. The table includes the pairs the machine must ignore: an
 * ignored event changes nothing and does nothing.
 */
class DeckStartupTest {

    private fun List<StartupAction>.sig(): String = joinToString(",") { action ->
        when (action) {
            StartupAction.WaitForBinder -> "wait"
            StartupAction.FinishBroadcast -> "finish"
            StartupAction.StartDeck -> "start"
        }
    }

    private val bootBinder = StartupEvent.Received(StartTrigger.Boot, keepRunning = true, binderReady = true)
    private val updateNoBinder = StartupEvent.Received(StartTrigger.Update, keepRunning = true, binderReady = false)
    private val updateOff = StartupEvent.Received(StartTrigger.Update, keepRunning = false, binderReady = false)

    /** A machine parked in each state. Built by transitions only. */
    private fun parked(state: String): DeckStartup {
        val m = DeckStartup()
        when (state) {
            "Idle" -> Unit
            "Waiting" -> m.transition(updateNoBinder)
            "Starting" -> m.transition(bootBinder)
            "OutOfTime" -> {
                m.transition(updateNoBinder)
                m.transition(StartupEvent.Waited(DeckStartup.BOUND_MS))
            }
            "Off" -> m.transition(updateOff)
            else -> error("unknown state $state")
        }
        return m
    }

    private val states = listOf("Idle", "Waiting", "Starting", "OutOfTime", "Off")

    private val events = listOf(
        bootBinder,
        updateNoBinder,
        updateOff,
        StartupEvent.BinderArrived,
        StartupEvent.Waited(1_000),
        StartupEvent.Waited(DeckStartup.BOUND_MS),
    )

    /** The whole table: state --event--> state + actions. */
    private val table: Map<String, Map<String, Pair<String, String>>> = mapOf(
        "Idle" to mapOf(
            bootBinder.describe() to ("Starting" to "start,finish"),
            updateNoBinder.describe() to ("Waiting(update, 0ms)" to "wait"),
            updateOff.describe() to ("Off" to ""),
            "BinderArrived" to ("Idle" to ""),
            "Waited(1000)" to ("Idle" to ""),
            "Waited(5000)" to ("Idle" to ""),
        ),
        "Waiting" to mapOf(
            bootBinder.describe() to ("Waiting(update, 0ms)" to ""),
            updateNoBinder.describe() to ("Waiting(update, 0ms)" to ""),
            updateOff.describe() to ("Waiting(update, 0ms)" to ""),
            "BinderArrived" to ("Starting" to "finish,start"),
            "Waited(1000)" to ("Waiting(update, 1000ms)" to ""),
            "Waited(5000)" to ("OutOfTime(update)" to "finish"),
        ),
        "Starting" to mapOf(
            bootBinder.describe() to ("Starting" to ""),
            updateNoBinder.describe() to ("Starting" to ""),
            updateOff.describe() to ("Starting" to ""),
            "BinderArrived" to ("Starting" to ""),
            "Waited(1000)" to ("Starting" to ""),
            "Waited(5000)" to ("Starting" to ""),
        ),
        "OutOfTime" to mapOf(
            bootBinder.describe() to ("OutOfTime(update)" to ""),
            updateNoBinder.describe() to ("OutOfTime(update)" to ""),
            updateOff.describe() to ("OutOfTime(update)" to ""),
            "BinderArrived" to ("Starting" to "start"),
            "Waited(1000)" to ("OutOfTime(update)" to ""),
            "Waited(5000)" to ("OutOfTime(update)" to ""),
        ),
        "Off" to mapOf(
            bootBinder.describe() to ("Off" to ""),
            updateNoBinder.describe() to ("Off" to ""),
            updateOff.describe() to ("Off" to ""),
            "BinderArrived" to ("Off" to ""),
            "Waited(1000)" to ("Off" to ""),
            "Waited(5000)" to ("Off" to ""),
        ),
    )

    @Test
    fun `every state and event pair follows the table`() {
        for (state in states) {
            for (event in events) {
                val row = table.getValue(state)[event.describe()]
                    ?: error("the table has no row for $state --${event.describe()}-->")
                val m = parked(state)
                val actions = m.transition(event)
                assertEquals("$state --${event.describe()}-->", row.first, m.state.describe())
                assertEquals("$state --${event.describe()}--> actions", row.second, actions.sig())
            }
        }
    }

    @Test
    fun `a binder that arrives later starts the deck exactly once`() {
        val m = DeckStartup()
        m.transition(updateNoBinder)
        m.transition(StartupEvent.Waited(DeckStartup.BOUND_MS))
        assertEquals("OutOfTime(update)", m.state.describe())
        assertEquals("start", m.transition(StartupEvent.BinderArrived).sig())
        assertEquals("Starting", m.state.describe())
        assertTrue(m.transition(StartupEvent.BinderArrived).isEmpty())
        assertTrue(m.transition(bootBinder).isEmpty())
        assertEquals("Starting", m.state.describe())
    }

    @Test
    fun `keep running off never starts the deck`() {
        val m = DeckStartup()
        assertTrue(m.transition(updateOff).isEmpty())
        assertEquals("Off", m.state.describe())
        assertTrue(m.transition(StartupEvent.BinderArrived).isEmpty())
        assertTrue(m.transition(StartupEvent.Waited(DeckStartup.BOUND_MS)).isEmpty())
        assertTrue(m.transition(bootBinder).isEmpty())
        assertEquals("Off", m.state.describe())
    }

    @Test
    fun `the wait is bounded at five seconds`() {
        // The person's binder was 0.41 s late; goAsync gives a broadcast about
        // 10 s, so half of it waits and half is left for the start itself.
        assertEquals(5_000L, DeckStartup.BOUND_MS)
        val m = DeckStartup()
        m.transition(updateNoBinder)
        assertTrue(m.transition(StartupEvent.Waited(DeckStartup.BOUND_MS - 1)).isEmpty())
        assertEquals("Waiting(update, 4999ms)", m.state.describe())
        assertEquals("finish", m.transition(StartupEvent.Waited(DeckStartup.BOUND_MS)).sig())
        assertEquals("OutOfTime(update)", m.state.describe())
    }

    @Test
    fun `a ready shell service starts the deck only when nobody serves and keep running is on`() {
        // ISS-42's second half: the notification listener alone can start the
        // app process and bind the shell service. Ready with no foreground
        // service would otherwise hold no pairings and refuse every Mac.
        assertTrue(startsDeckWhenReady(keepRunning = true, deckRunning = false))
        assertFalse(startsDeckWhenReady(keepRunning = true, deckRunning = true))
        assertFalse(startsDeckWhenReady(keepRunning = false, deckRunning = false))
        assertFalse(startsDeckWhenReady(keepRunning = false, deckRunning = true))
    }

    @Test
    fun `the transition log uses closed tokens only`() {
        assertEquals("Idle", StartupState.Idle.describe())
        assertEquals("Waiting(update, 0ms)", StartupState.Waiting(StartTrigger.Update, 0).describe())
        assertEquals("Starting", StartupState.Starting.describe())
        assertEquals("OutOfTime(boot)", StartupState.OutOfTime(StartTrigger.Boot).describe())
        assertEquals("Off", StartupState.Off.describe())
        assertEquals("boot", StartTrigger.Boot.token)
        assertEquals("update", StartTrigger.Update.token)
        assertEquals("Received(boot, keep=on, binder=here)", bootBinder.describe())
        assertEquals("Received(update, keep=on, binder=absent)", updateNoBinder.describe())
        assertEquals("Received(update, keep=off, binder=absent)", updateOff.describe())
        assertEquals("BinderArrived", StartupEvent.BinderArrived.describe())
        assertEquals("Waited(1000)", StartupEvent.Waited(1_000).describe())
    }
}
