package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Replays the emulator's 13:25-13:26 sequence through the decision half of
 * `AndroidPower.keepAliveStep` (strategy selection + step), not only through
 * `DarkPanelPolicy`. The captured plans were `wake=true, panelOff=false,
 * transitional=false`, which is the GROUP_ONLY/PANEL_ALONE answer: a forced
 * server cannot produce it for an app window on a non-default group.
 */
class PanelDecisionTest {

    private val appDisplay = 2
    private val nonDefaultGroup = 5

    private fun decide(
        policy: DarkPanelPolicy,
        panelOn: Boolean,
        mirrorOpen: Boolean = false,
        mirrorOff: Boolean = false,
    ): PanelDecision = decidePanelPlan(
        policy = policy,
        activeDisplayIds = listOf(appDisplay),
        requestOnly = false,
        mirrorOpen = mirrorOpen,
        mirrorOff = mirrorOff,
        panelOn = panelOn,
        groupOf = { nonDefaultGroup },
    )!!

    @Test
    fun `forced app window on a non-default group takes the panel dark once`() {
        val policy = DarkPanelPolicy(forced = true)
        policy.streamsStarted()

        val decision = decide(policy, panelOn = false)

        assertEquals(PanelStrategy.PANEL_DARK, decision.strategy)
        assertEquals(PanelPlan(wake = true, panelOff = true, transitional = true), decision.plan)
    }

    @Test
    fun `pause inside the grace neither hands back nor re-takes`() {
        val policy = DarkPanelPolicy(forced = true)
        policy.streamsStarted()
        decide(policy, panelOn = false) // the take-over

        assertFalse("a dark episode is not handed back by a pause", policy.streamsPaused(1_000))
        policy.streamsResumed()
        val decision = decide(policy, panelOn = false)

        assertEquals(PanelPlan(wake = true, panelOff = true, transitional = false), decision.plan)
    }

    @Test
    fun `a mirror over an app window is panel alone, never dark`() {
        val policy = DarkPanelPolicy(forced = true)
        policy.streamsStarted()

        val decision = decide(policy, panelOn = false, mirrorOpen = true)

        assertEquals(PanelStrategy.PANEL_ALONE, decision.strategy)
        assertEquals(PanelPlan(wake = true, panelOff = false, transitional = false), decision.plan)
    }

    @Test
    fun `mirror-only phone panel off plans the dark take-over`() {
        val policy = DarkPanelPolicy(forced = true)
        policy.streamsStarted()
        policy.requestMirrorOff(true)

        val decision = decidePanelPlan(
            policy = policy,
            activeDisplayIds = emptyList(),
            requestOnly = true,
            mirrorOpen = true,
            mirrorOff = true,
            panelOn = false,
            groupOf = { nonDefaultGroup },
        )!!

        assertEquals(PanelStrategy.PANEL_ALONE, decision.strategy)
        assertEquals(PanelPlan(wake = true, panelOff = true, transitional = true), decision.plan)
    }

    @Test
    fun `phone panel off plans a dark take-over and on plans it back`() {
        val policy = DarkPanelPolicy(forced = true)
        policy.streamsStarted()
        decide(policy, panelOn = false, mirrorOpen = true) // the mirror, no request

        assertTrue(policy.requestMirrorOff(true))
        val off = decide(policy, panelOn = false, mirrorOpen = true, mirrorOff = true)
        assertEquals(PanelStrategy.PANEL_ALONE, off.strategy)
        assertEquals(PanelPlan(wake = true, panelOff = true, transitional = true), off.plan)

        assertTrue(policy.requestMirrorOff(false))
        val on = decide(policy, panelOn = false, mirrorOpen = true, mirrorOff = false)
        assertEquals(PanelPlan(wake = true, panelOff = false, transitional = false), on.plan)
    }

    @Test
    fun `a close after the dark take-over owns the panel`() {
        val policy = DarkPanelPolicy(forced = true)
        policy.streamsStarted()
        decide(policy, panelOn = false)

        // restoreAfterStop only calls goToSleep when streamsStopped() says the
        // policy owned the panel; with an unforced server this is false, which
        // is why the boot's first_sleep was "none".
        assertTrue(policy.streamsStopped())
    }
}
