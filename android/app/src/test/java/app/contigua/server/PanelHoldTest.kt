package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The "Turn Off Phone Screen" hold (docs/design/phone-mirror.md): one state
 * machine, every transition pinned, including the events each state ignores.
 *
 * The replay at the top is the phone log of 10-21 15:33:29: the Mac asked for
 * the panel off while the phone window was open, the window paused (AppKit
 * pauses a non-key, occluded window), and the hold ended at keep-alive step 2
 * without ever writing the panel back. The panel stayed in power mode OFF.
 */
class PanelHoldTest {

    private val allStates = PanelHoldState.values()
    private val allEvents = listOf(
        PanelHoldEvent.RequestOff(false),
        PanelHoldEvent.RequestOn,
        PanelHoldEvent.WindowOpened,
        PanelHoldEvent.WindowPaused,
        PanelHoldEvent.WindowResumed,
        PanelHoldEvent.WindowClosed,
        PanelHoldEvent.KeepAliveStep(panelOn = true),
        PanelHoldEvent.PowerPress,
        PanelHoldEvent.SessionEnded,
        PanelHoldEvent.CrashRecovery,
        PanelHoldEvent.RestoreDone,
    )

    private fun open(state: PanelHoldState) = PanelHoldModel(state = state, mirror = PanelMirror.Open)

    // --- the reported sequence, replayed -----------------------------------

    /**
     * The 15:33:29 sequence: request off with the window open and unpaused, one
     * keep-alive step (the take-over), the window's pause, its resume, then the
     * person turns the screen back on. The hold must survive the pause (it is
     * only suspended) and the panel must come back on every path out of it.
     */
    @Test
    fun `repro 15-33-29 the hold survives the window pause and restores the panel`() {
        val hold = PanelHoldMachine()

        hold.dispatch(PanelHoldEvent.WindowOpened)
        val off = hold.dispatch(PanelHoldEvent.RequestOff(ignorePower = false))
        assertEquals(PanelHoldState.Applying, hold.state)
        assertTrue("the request takes the panel", off.contains(PanelHoldAction.PanelOff(true)))
        assertTrue("the Mac hears panel off", off.contains(PanelHoldAction.ReportPanel(true)))

        val step = hold.dispatch(PanelHoldEvent.KeepAliveStep(panelOn = true))
        assertEquals(PanelHoldState.Held, hold.state)
        assertTrue("the step keeps the panel off", step.contains(PanelHoldAction.PanelOff(false)))

        // The window pauses (the log's silent setActiveStreams at 15:33:30.39):
        // the panel comes back, the request stays held.
        val paused = hold.dispatch(PanelHoldEvent.WindowPaused)
        assertEquals("a paused phone window suspends the hold, never ends it", PanelHoldState.Suspended, hold.state)
        assertFalse(hold.holdsPanel)
        assertTrue("the pause hands the panel back", paused.contains(PanelHoldAction.PanelNormal()))
        assertTrue("the Mac hears panel on", paused.contains(PanelHoldAction.ReportPanel(false)))
        assertTrue("the keep-alive stops while suspended", paused.contains(PanelHoldAction.StopKeepAlive))

        // It resumes: the request is applied again, without a new request from the Mac.
        val resumed = hold.dispatch(PanelHoldEvent.WindowResumed)
        assertEquals(PanelHoldState.Applying, hold.state)
        assertTrue(resumed.contains(PanelHoldAction.PanelOff(true)))
        assertTrue(resumed.contains(PanelHoldAction.StartKeepAlive))
        hold.dispatch(PanelHoldEvent.KeepAliveStep(panelOn = true))
        assertEquals(PanelHoldState.Held, hold.state)

        // The person turns the screen back on from the Mac.
        val on = hold.dispatch(PanelHoldEvent.RequestOn)
        assertEquals(PanelHoldState.Restoring, hold.state)
        assertTrue("request on hands the panel back", on.contains(PanelHoldAction.PanelNormal()))
        assertTrue(on.contains(PanelHoldAction.ReportPanel(false)))
        hold.dispatch(PanelHoldEvent.RestoreDone)
        assertEquals(PanelHoldState.Off, hold.state)
    }

    // --- the state/event table --------------------------------------------

    /**
     * One transition per state and event, the ignored ones included. The map is
     * the contract: a new event or state must be added here too.
     */
    @Test
    fun `every state and event transitions as the table says`() {
        val held = PanelHoldState.Held
        val off = PanelHoldState.Off
        val applying = PanelHoldState.Applying
        val suspended = PanelHoldState.Suspended
        val restoring = PanelHoldState.Restoring
        val expected = mapOf(
            (off to "requestOff") to applying,
            (off to "requestOn") to off,
            (off to "windowOpened") to off,
            (off to "windowPaused") to off,
            (off to "windowResumed") to off,
            (off to "windowClosed") to off,
            (off to "keepAlive") to off,
            (off to "powerPress") to off,
            (off to "sessionEnded") to off,
            (off to "crashRecovery") to restoring,
            (off to "restoreDone") to off,

            (applying to "requestOff") to applying,
            (applying to "requestOn") to restoring,
            (applying to "windowOpened") to applying,
            (applying to "windowPaused") to suspended,
            (applying to "windowResumed") to applying,
            (applying to "windowClosed") to restoring,
            (applying to "keepAlive") to held,
            (applying to "powerPress") to restoring,
            (applying to "sessionEnded") to restoring,
            (applying to "crashRecovery") to applying,
            (applying to "restoreDone") to applying,

            (held to "requestOff") to held,
            (held to "requestOn") to restoring,
            (held to "windowOpened") to held,
            (held to "windowPaused") to suspended,
            (held to "windowResumed") to held,
            (held to "windowClosed") to restoring,
            (held to "keepAlive") to held,
            (held to "powerPress") to restoring,
            (held to "sessionEnded") to restoring,
            (held to "crashRecovery") to held,
            (held to "restoreDone") to held,

            (suspended to "requestOff") to suspended,
            (suspended to "requestOn") to off,
            (suspended to "windowOpened") to applying,
            (suspended to "windowPaused") to suspended,
            (suspended to "windowResumed") to applying,
            (suspended to "windowClosed") to off,
            (suspended to "keepAlive") to suspended,
            (suspended to "powerPress") to suspended,
            (suspended to "sessionEnded") to off,
            (suspended to "crashRecovery") to suspended,
            (suspended to "restoreDone") to suspended,

            (restoring to "requestOff") to applying,
            (restoring to "requestOn") to off,
            (restoring to "windowOpened") to restoring,
            (restoring to "windowPaused") to restoring,
            (restoring to "windowResumed") to restoring,
            (restoring to "windowClosed") to restoring,
            (restoring to "keepAlive") to restoring,
            (restoring to "powerPress") to restoring,
            (restoring to "sessionEnded") to restoring,
            (restoring to "crashRecovery") to restoring,
            (restoring to "restoreDone") to off,
        )

        for (state in allStates) {
            for (event in allEvents) {
                val key = state to event.wire
                val want = expected[key] ?: error("no expected transition for $key")
                val got = panelHoldTransition(open(state), event)
                assertEquals("$state --${event.wire}-->", want, got.model.state)
            }
        }
        assertEquals("the table covers every pair", allStates.size * allEvents.size, expected.size)
    }

    /** A request off with no phone window is remembered, not applied. */
    @Test
    fun `a request with a closed window waits for it`() {
        val hold = PanelHoldMachine()
        val actions = hold.dispatch(PanelHoldEvent.RequestOff(ignorePower = false))
        assertEquals(PanelHoldState.Suspended, hold.state)
        assertFalse(hold.holdsPanel)
        assertTrue("nothing is applied without a window", actions.none { it is PanelHoldAction.PanelOff })

        hold.dispatch(PanelHoldEvent.WindowOpened)
        assertEquals(PanelHoldState.Applying, hold.state)
        assertTrue(hold.holdsPanel)
    }

    // --- the invariant: no exit leaves the panel off ----------------------

    private class FakePanel {
        /** POWER_MODE_NORMAL until a PanelOff action writes OFF. */
        var mode = "normal"
            private set

        fun apply(actions: List<PanelHoldAction>) {
            for (action in actions) {
                when (action) {
                    is PanelHoldAction.PanelOff -> mode = "off"
                    is PanelHoldAction.PanelNormal -> mode = "normal"
                    else -> Unit
                }
            }
        }
    }

    /**
     * The bug's invariant: every path out of [PanelHoldState.Applying] or
     * [PanelHoldState.Held] writes the panel back, whatever ended the hold
     * (request on, power press, window close, session end, crash recovery).
     */
    @Test
    fun `no exit from a hold leaves the panel off`() {
        var exits = 0
        for (state in listOf(PanelHoldState.Applying, PanelHoldState.Held)) {
            for (event in allEvents) {
                val panel = FakePanel()
                val transition = panelHoldTransition(open(state), event)
                panel.apply(transition.actions)
                if (transition.model.holdsPanel) {
                    // Still holding: the panel must not be handed back behind
                    // the phone window's back.
                    assertTrue("$state --${event.wire}--> hands the panel back while still holding",
                        transition.actions.none { it is PanelHoldAction.PanelNormal })
                    continue
                }
                assertFalse("$state --${event.wire}--> leaves the panel off", panel.mode == "off")
                assertTrue("$state --${event.wire}--> leaves the hold with no PanelNormal",
                    transition.actions.any { it is PanelHoldAction.PanelNormal })
                exits++
            }
        }
        assertTrue("the test saw no exit at all", exits >= 8)
    }

    /** `state.panel` is the machine's state: every change of it is reported. */
    @Test
    fun `every report matches the state the machine lands in`() {
        for (state in allStates) {
            for (event in allEvents) {
                val before = open(state)
                val transition = panelHoldTransition(before, event)
                val reports = transition.actions.filterIsInstance<PanelHoldAction.ReportPanel>()
                if (before.holdsPanel != transition.model.holdsPanel) {
                    assertEquals("$state --${event.wire}--> changes state.panel with one report",
                        1, reports.size)
                    assertEquals("$state --${event.wire}--> reports the new state",
                        transition.model.holdsPanel, reports.single().off)
                } else {
                    assertTrue("$state --${event.wire}--> reports an unchanged state",
                        reports.isEmpty())
                }
            }
        }
    }

    /**
     * The 16:44 log's cause: `state.panel` is reported the moment the hold
     * changes, before any platform action that can block — the panel write, the
     * wake wait, the keep-alive start/stop, and the watchdog's clean stop (it
     * waits up to 2 s for the child). Reported last, the Mac's button landed
     * 1.1 s after the phone's screen came back.
     */
    @Test
    fun `repro 16-44 the panel is reported before any blocking platform action`() {
        var reports = 0
        for (state in allStates) {
            for (event in allEvents) {
                val actions = panelHoldTransition(open(state), event).actions
                val report = actions.indexOfFirst { it is PanelHoldAction.ReportPanel }
                if (report < 0) continue
                reports++
                assertEquals("$state --${event.wire}--> reports after a platform action: $actions",
                    0, report)
            }
        }
        assertTrue("no transition reported a panel change", reports >= 3)
    }

    /** The log's two request paths: request on, and a power press while held. */
    @Test
    fun `a request reports the panel before the panel write and the wake`() {
        val hold = PanelHoldMachine()
        hold.dispatch(PanelHoldEvent.WindowOpened)
        hold.dispatch(PanelHoldEvent.RequestOff(ignorePower = false))
        hold.dispatch(PanelHoldEvent.KeepAliveStep(panelOn = true))
        assertEquals("the Mac hears panel on first", PanelHoldAction.ReportPanel(false),
            hold.dispatch(PanelHoldEvent.RequestOn).first())

        hold.dispatch(PanelHoldEvent.RequestOff(ignorePower = false))
        hold.dispatch(PanelHoldEvent.KeepAliveStep(panelOn = true))
        assertEquals("a power press reports before the blocking wake", PanelHoldAction.ReportPanel(false),
            hold.dispatch(PanelHoldEvent.PowerPress).first())
    }

    // --- item 2: one power press brings the screen back --------------------

    @Test
    fun `a power press while held ends the hold and wakes the panel`() {
        val hold = PanelHoldMachine()
        hold.dispatch(PanelHoldEvent.WindowOpened)
        hold.dispatch(PanelHoldEvent.RequestOff(ignorePower = false))
        hold.dispatch(PanelHoldEvent.KeepAliveStep(panelOn = true))
        assertEquals(PanelHoldState.Held, hold.state)

        val actions = hold.dispatch(PanelHoldEvent.PowerPress)
        assertEquals(PanelHoldState.Restoring, hold.state)
        assertTrue("the panel is handed back", actions.contains(PanelHoldAction.PanelNormal(wake = true)))
        assertTrue("the Mac's button flips back", actions.contains(PanelHoldAction.ReportPanel(false)))
        assertTrue(actions.contains(PanelHoldAction.StopKeepAlive))
    }

    /** The setting: a power press lights the screen only until the next step re-applies the hold. */
    @Test
    fun `with keep-it-off a power press keeps the hold and the next step re-applies`() {
        val hold = PanelHoldMachine()
        hold.dispatch(PanelHoldEvent.WindowOpened)
        hold.dispatch(PanelHoldEvent.RequestOff(ignorePower = true))
        hold.dispatch(PanelHoldEvent.KeepAliveStep(panelOn = true))

        val press = hold.dispatch(PanelHoldEvent.PowerPress)
        assertEquals("the hold goes on", PanelHoldState.Held, hold.state)
        assertTrue("the panel is not handed back", press.none { it is PanelHoldAction.PanelNormal })
        assertTrue("the Mac still says off", press.none { it is PanelHoldAction.ReportPanel })

        val step = hold.dispatch(PanelHoldEvent.KeepAliveStep(panelOn = true))
        assertTrue("the next step re-applies the panel off", step.contains(PanelHoldAction.PanelOff(false)))
    }

    /** The setting does not survive the ends the brief names: a new request reads the Mac's value. */
    @Test
    fun `the setting only changes what a power press does`() {
        for (event in listOf(PanelHoldEvent.RequestOn, PanelHoldEvent.WindowClosed,
                             PanelHoldEvent.SessionEnded)) {
            val hold = PanelHoldMachine()
            hold.dispatch(PanelHoldEvent.WindowOpened)
            hold.dispatch(PanelHoldEvent.RequestOff(ignorePower = true))
            hold.dispatch(PanelHoldEvent.KeepAliveStep(panelOn = true))
            val actions = hold.dispatch(event)
            assertEquals("$event ends the hold", PanelHoldState.Restoring, hold.state)
            assertTrue("$event hands the panel back", actions.contains(PanelHoldAction.PanelNormal()))
        }
    }

    // --- logging ----------------------------------------------------------

    @Test
    fun `every transition is logged with its event`() {
        val lines = mutableListOf<String>()
        val hold = PanelHoldMachine { lines.add(it) }
        hold.dispatch(PanelHoldEvent.WindowOpened)
        hold.dispatch(PanelHoldEvent.RequestOff())
        hold.dispatch(PanelHoldEvent.KeepAliveStep(panelOn = true))
        hold.dispatch(PanelHoldEvent.RequestOn)
        hold.dispatch(PanelHoldEvent.RestoreDone)

        assertTrue(lines.contains("panelhold: Off --windowOpened--> Off"))
        assertTrue(lines.contains("panelhold: Off --requestOff--> Applying"))
        assertTrue(lines.contains("panelhold: Applying --keepAlive--> Held"))
        assertTrue(lines.contains("panelhold: Held --requestOn--> Restoring"))
        assertTrue(lines.contains("panelhold: Restoring --restoreDone--> Off"))
        assertFalse("keep-alive steps that change nothing are not logged",
            lines.any { it.contains("Held --keepAlive--> Held") })
    }
}
