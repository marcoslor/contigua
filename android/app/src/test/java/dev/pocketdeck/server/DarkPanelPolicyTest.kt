package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The panel-dark decision logic, driven with plain values: which strategy a set
 * of display groups gets, when the panel is forced off, and when the phone is
 * handed back to normal Android behaviour after a power-button press.
 */
class DarkPanelPolicyTest {

    private val ownGroup = 1
    private val panelGroup = DisplayProbe.DEFAULT_GROUP_ID

    private fun policy(forced: Boolean = false) = DarkPanelPolicy(forced)

    // --- strategy ---------------------------------------------------

    @Test
    fun `virtual displays with their own group are never touched on the panel`() {
        val p = policy()
        assertEquals(PanelStrategy.GROUP_ONLY, p.strategy(listOf(ownGroup, ownGroup + 1)))
    }

    @Test
    fun `a virtual display in the panel's group selects the panel-dark path`() {
        val p = policy()
        assertEquals(PanelStrategy.PANEL_DARK, p.strategy(listOf(ownGroup, panelGroup)))
    }

    @Test
    fun `the debug property forces the panel-dark path even with an own group`() {
        val p = policy(forced = true)
        assertEquals(PanelStrategy.PANEL_DARK, p.strategy(listOf(ownGroup)))
    }

    // --- taking over -------------------------------------------------

    @Test
    fun `locked phone, first window - wake and darken the panel`() {
        val p = policy()
        p.streamsStarted()
        val plan = p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertTrue(plan.wake)
        assertTrue(plan.panelOff)
        assertTrue("first step of an episode re-applies the panel-off", plan.transitional)
    }

    @Test
    fun `steady state keeps waking and re-applying the dark panel`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        val plan = p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK)
        assertTrue(plan.wake)
        assertTrue(plan.panelOff)
        assertFalse("only an episode start is transitional", plan.transitional)
    }

    @Test
    fun `own-group builds never power the panel off`() {
        val p = policy()
        p.streamsStarted()
        for (on in listOf(false, true)) {
            val plan = p.step(panelOn = on, strategy = PanelStrategy.GROUP_ONLY)
            assertTrue(plan.wake)
            assertFalse(plan.panelOff)
            assertFalse(plan.transitional)
        }
    }

    // --- the user's power button wins --------------------------------

    @Test
    fun `a power press while we own the panel hands the phone back`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK) // our forced-dark panel

        val pressed = p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertFalse("no wake after the user asked for the screen off", pressed.wake)
        assertFalse(pressed.panelOff)

        val stillAsleep = p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertFalse(stillAsleep.wake)
        assertFalse(stillAsleep.panelOff)
    }

    @Test
    fun `the user's screen is left alone while it is on`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK)
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK) // power press

        val usersScreen = p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK)
        assertFalse(usersScreen.wake)
        assertFalse(usersScreen.panelOff)
    }

    @Test
    fun `darkening resumes once the user's screen goes off again`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK)
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK) // power press
        p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK) // user turned it on
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK) // and off again

        val resumed = p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertTrue(resumed.wake)
        assertTrue(resumed.panelOff)
    }

    @Test
    fun `a window opened while the user is on the phone never darkens the panel`() {
        val p = policy()
        p.streamsStarted()
        val plan = p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK)
        assertFalse(plan.wake)
        assertFalse(plan.panelOff)

        val later = p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertTrue("the screen went off: keep the VD lit", later.wake)
        assertTrue(later.panelOff)
        assertTrue(later.transitional)
    }

    // --- platform that never reports the panel on (forced path) -------

    @Test
    fun `a panel that never turns on keeps the fallback running`() {
        val p = policy(forced = true)
        p.streamsStarted()
        val first = p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertTrue(first.wake && first.panelOff)
        val next = p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertTrue("still ours, not a power press", next.wake)
        assertTrue(next.panelOff)
        assertFalse(next.transitional)
    }

    // --- the phone window and the panel it mirrors --------------------

    @Test
    fun `the mirror keeps the shared-group panel on`() {
        val p = policy()
        assertEquals("a phone window watching the panel is no reason to darken it",
                     PanelStrategy.PANEL_ALONE, p.strategy(listOf(ownGroup, panelGroup), mirroring = true))
        p.streamsStarted()
        val plan = p.step(panelOn = true, strategy = PanelStrategy.PANEL_ALONE)
        assertTrue("the app window's group stays awake", plan.wake)
        assertFalse("never power off the panel the person mirrors", plan.panelOff)
        assertFalse(plan.transitional)
        assertFalse("a mirror never wakes the phone", DarkPanelPolicy.wakesGroup(PanelStrategy.PANEL_ALONE, plan))
        assertTrue("the mirror steps at the shared-group cadence",
                   DarkPanelPolicy.keepAliveIntervalMs(PanelStrategy.PANEL_ALONE, displayLockHeld = false) < 6_000)
    }

    @Test
    fun `the forced debug path also spares the mirrored panel`() {
        assertEquals(PanelStrategy.PANEL_ALONE, policy(forced = true).strategy(listOf(ownGroup), mirroring = true))
    }

    @Test
    fun `a mirror opened during a dark episode hands the panel back`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        val mirrored = p.step(panelOn = true, strategy = PanelStrategy.PANEL_ALONE)
        assertFalse("the panel comes back for the mirror", mirrored.panelOff)
        assertFalse(DarkPanelPolicy.wakesGroup(PanelStrategy.PANEL_ALONE, mirrored))
        // Closing the mirror returns to the app window's path: the panel is on
        // and belongs to the person, so it is not darkened under them.
        val back = p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK)
        assertFalse(back.panelOff)
    }

    @Test
    fun `without a mirror the shared group still darkens the panel`() {
        val p = policy()
        p.streamsStarted()
        val plan = p.step(panelOn = false, strategy = p.strategy(listOf(panelGroup), mirroring = false))
        assertTrue(plan.panelOff)
    }

    // --- "Turn Off Phone Screen" --------------------------------------

    /// The policy never darkens the panel a person mirrors: the hold's machine
    /// owns that (PanelHoldTest), and decidePanelPlan ORs its panel-off in.
    /// With no hold the mirrored panel stays exactly as the person has it.
    @Test
    fun `the policy never darkens the mirrored panel`() {
        val p = policy()
        p.streamsStarted()
        val plan = p.step(panelOn = true, strategy = PanelStrategy.PANEL_ALONE)
        assertFalse(plan.panelOff)
        assertTrue("the mirror's frames keep the group awake", plan.wake)
        assertFalse(plan.transitional)
        // A dark app episode ends when the mirror opens.
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertFalse(p.step(panelOn = true, strategy = PanelStrategy.PANEL_ALONE).panelOff)
    }

    @Test
    fun `closing the phone window does not leave the policy owning anything`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = true, strategy = PanelStrategy.PANEL_ALONE)
        assertFalse("the mirror never took the panel", p.streamsStopped())
    }

    // --- stopping ----------------------------------------------------

    @Test
    fun `stopping while we own the panel asks for restore and sleep`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertTrue(p.streamsStopped())
    }

    // --- a paused window is not the end of streaming ------------------

    @Test
    fun `a pause keeps the panel state for the grace period`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK) // take the panel over
        p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK) // steady dark
        assertFalse("a covered window must not hand the panel back", p.streamsPaused(nowMs = 1_000))
        assertFalse("5 s into the pause the panel is still ours", p.pauseGraceExpired(nowMs = 6_000))
        assertFalse("29 s is still inside the grace", p.pauseGraceExpired(nowMs = 29_999))
    }

    @Test
    fun `a pause inside the grace period resumes without a new wake`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK)
        p.streamsPaused(nowMs = 1_000)
        assertFalse(p.pauseGraceExpired(nowMs = 6_000))
        p.streamsResumed()
        val resumed = p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK)
        assertFalse("an unpause inside the grace is no new episode", resumed.transitional)
        assertTrue("the panel is still held dark", resumed.panelOff)
        assertFalse("a resume ends the pause", p.pauseGraceExpired(nowMs = 60_000))
    }

    @Test
    fun `a pause longer than the grace hands the panel back`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        p.streamsPaused(nowMs = 1_000)
        assertTrue("31 s of a covered window hands the phone back", p.pauseGraceExpired(nowMs = 32_000))
        assertTrue("the episode was ours: restore and sleep", p.streamsStopped())
    }

    @Test
    fun `a pause while the person has the phone stops at once`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK) // the person's own screen
        assertTrue("nothing of ours to keep", p.streamsPaused(nowMs = 1_000))
    }

    @Test
    fun `closing the last stream hands the panel back at once`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertTrue("a close is not a pause", p.streamsStopped())
    }

    @Test
    fun `stopping while the user has the phone restores nothing`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK)
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK) // power press
        assertFalse(p.streamsStopped())
    }

    @Test
    fun `own-group builds restore nothing`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = false, strategy = PanelStrategy.GROUP_ONLY)
        assertFalse(p.streamsStopped())
    }

    @Test
    fun `a new episode starts clean`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertTrue(p.streamsStopped())

        p.streamsStarted()
        val plan = p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertTrue(plan.transitional)
        assertTrue(plan.panelOff)
    }

    @Test
    fun `the forced path is reported`() {
        assertTrue(policy(forced = true).isForced)
        assertFalse(policy().isForced)
    }

    @Test
    fun `a shared group is poked faster than the keyguard's 6 s timeout`() {
        for (lock in listOf(true, false)) {
            val ms = DarkPanelPolicy.keepAliveIntervalMs(PanelStrategy.PANEL_DARK, displayLockHeld = lock)
            assertTrue("interval $ms must beat the 6 s keyguard timeout", ms < 6_000)
        }
    }

    @Test
    fun `an own group with a display lock keeps the slow safety-net cadence`() {
        assertEquals(60_000L, DarkPanelPolicy.keepAliveIntervalMs(PanelStrategy.GROUP_ONLY, displayLockHeld = true))
        assertEquals(10_000L, DarkPanelPolicy.keepAliveIntervalMs(PanelStrategy.GROUP_ONLY, displayLockHeld = false))
    }

    @Test
    fun `a shared group is woken only when the panel is taken over`() {
        val p = policy()
        p.streamsStarted()
        val first = p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertTrue(DarkPanelPolicy.wakesGroup(PanelStrategy.PANEL_DARK, first))
        // Steady state: poke only. A wake here would undo a power press made
        // since the last step and start face unlock.
        val steady = p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK)
        assertTrue(steady.wake)
        assertFalse(DarkPanelPolicy.wakesGroup(PanelStrategy.PANEL_DARK, steady))
        // The user's power press: the group stays asleep and the phone is theirs.
        val pressed = p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertFalse(DarkPanelPolicy.wakesGroup(PanelStrategy.PANEL_DARK, pressed))
    }

    @Test
    fun `an own group is woken on every step`() {
        val p = policy()
        p.streamsStarted()
        repeat(3) {
            val plan = p.step(panelOn = false, strategy = PanelStrategy.GROUP_ONLY)
            assertTrue(DarkPanelPolicy.wakesGroup(PanelStrategy.GROUP_ONLY, plan))
        }
    }

    @Test
    fun `a power press while dark hands the phone back until its screen goes off again`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertTrue(p.userPressedPower())
        // The user is using the phone: never darken it, never wake it.
        repeat(3) {
            val plan = p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK)
            assertFalse(plan.panelOff)
            assertFalse(plan.wake)
        }
        // Their own screen-off: resume keeping the stream lit.
        val off = p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertTrue(off.panelOff)
        assertTrue(off.transitional)
        // The episode was the user's at the end: nothing of ours to restore.
        assertFalse(policy().also { it.streamsStarted() }.userPressedPower())
    }

    @Test
    fun `a power press is only ours to handle while dark`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK) // user already had it
        assertFalse(p.userPressedPower())
    }
}
