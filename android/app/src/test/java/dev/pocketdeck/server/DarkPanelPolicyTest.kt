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

    // --- stopping ----------------------------------------------------

    @Test
    fun `stopping while we own the panel asks for restore and sleep`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertTrue(p.streamsStopped())
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
}
