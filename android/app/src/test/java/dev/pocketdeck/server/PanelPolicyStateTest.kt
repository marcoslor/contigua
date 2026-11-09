package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The panel policy's one transition, `(state, event) -> (state, actions)`
 * (AGENTS.md; SM-P-2): every state/event pair, including the events each state
 * must ignore. The field rules live in [DarkPanelPolicy]; this suite is the
 * table an agent can read.
 */
class PanelPolicyStateTest {

    private fun state(
        phase: PanelPhase,
        pausedAtMs: Long? = null,
        ownUntilMs: Long = 0L,
        strategy: PanelStrategy = PanelStrategy.PANEL_DARK,
        lastPanelOn: Boolean? = null,
    ) = PanelPolicyState(
        phase = phase,
        pausedAtMs = pausedAtMs,
        ownUntilMs = ownUntilMs,
        watchStrategy = strategy,
        lastPanelOn = lastPanelOn,
    )

    private fun step(state: PanelPolicyState, event: PanelEvent) = panelPolicyStep(state, event)

    private fun assertIgnored(state: PanelPolicyState, event: PanelEvent) {
        val result = step(state, event)
        assertEquals("$event must not change the state", state, result.state)
        assertTrue("$event must return no action", result.actions.isEmpty())
    }

    // --- StreamsStarted ----------------------------------------------

    @Test
    fun `streamsStarted resets the phase and the own-wake settle in every state`() {
        for (phase in PanelPhase.entries) {
            val result = step(
                state(phase, pausedAtMs = 5_000L, ownUntilMs = 9_000L, strategy = PanelStrategy.PANEL_ALONE),
                PanelEvent.StreamsStarted,
            )
            assertEquals(PanelPhase.INIT, result.state.phase)
            assertEquals("a new episode clears the settle, not the pause", 0L, result.state.ownUntilMs)
            assertEquals("the pause outlives the event today", 5_000L, result.state.pausedAtMs)
            assertEquals(PanelStrategy.PANEL_ALONE, result.state.watchStrategy)
            assertTrue(result.actions.isEmpty())
        }
    }

    // --- EpisodeStarted ----------------------------------------------

    @Test
    fun `episodeStarted on a sleeping shared group takes over and owes the panel-off`() {
        val result = step(state(PanelPhase.INIT), PanelEvent.EpisodeStarted(panelOn = false, PanelStrategy.PANEL_DARK))
        assertEquals(PanelPhase.WAKE, result.state.phase)
        assertEquals(
            listOf(PanelAction.WakeGroup, PanelAction.PanelOff(transitional = true)),
            result.actions,
        )
        assertEquals(PanelStrategy.PANEL_DARK, result.state.watchStrategy)
    }

    @Test
    fun `episodeStarted on a lit panel leaves it to the person`() {
        val result = step(state(PanelPhase.INIT), PanelEvent.EpisodeStarted(panelOn = true, PanelStrategy.PANEL_DARK))
        assertEquals(PanelPhase.USER, result.state.phase)
        assertTrue(result.actions.isEmpty())
    }

    @Test
    fun `episodeStarted for an own group only wakes it`() {
        val result = step(state(PanelPhase.INIT), PanelEvent.EpisodeStarted(panelOn = false, PanelStrategy.GROUP_ONLY))
        assertEquals(PanelPhase.INIT, result.state.phase)
        assertEquals(listOf(PanelAction.WakeGroup), result.actions)
    }

    @Test
    fun `episodeStarted for a mirror decides nothing`() {
        val result = step(state(PanelPhase.INIT), PanelEvent.EpisodeStarted(panelOn = false, PanelStrategy.PANEL_ALONE))
        assertEquals(PanelPhase.INIT, result.state.phase)
        assertTrue(result.actions.isEmpty())
    }

    @Test
    fun `episodeStarted after the first one only records the strategy`() {
        for (phase in listOf(PanelPhase.WAKE, PanelPhase.DARK, PanelPhase.USER)) {
            val result = step(
                state(phase, strategy = PanelStrategy.GROUP_ONLY),
                PanelEvent.EpisodeStarted(panelOn = false, PanelStrategy.PANEL_DARK),
            )
            assertEquals(phase, result.state.phase)
            assertEquals(PanelStrategy.PANEL_DARK, result.state.watchStrategy)
            assertTrue("a repeated episode start takes nothing over", result.actions.isEmpty())
        }
    }

    // --- Step --------------------------------------------------------

    @Test
    fun `step from INIT on a sleeping panel takes it over`() {
        val result = step(state(PanelPhase.INIT), PanelEvent.Step(panelOn = false, PanelStrategy.PANEL_DARK))
        assertEquals(PanelPhase.DARK, result.state.phase)
        assertEquals(
            listOf(PanelAction.WakeGroup, PanelAction.PanelOff(transitional = true)),
            result.actions,
        )
    }

    @Test
    fun `step from INIT on a lit panel leaves it to the person`() {
        val result = step(state(PanelPhase.INIT), PanelEvent.Step(panelOn = true, PanelStrategy.PANEL_DARK))
        assertEquals(PanelPhase.USER, result.state.phase)
        assertTrue(result.actions.isEmpty())
    }

    @Test
    fun `step from WAKE applies the owed panel-off without a second wake`() {
        for (panelOn in listOf(false, true)) {
            val result = step(state(PanelPhase.WAKE), PanelEvent.Step(panelOn, PanelStrategy.PANEL_DARK))
            assertEquals(PanelPhase.DARK, result.state.phase)
            assertEquals(
                listOf(PanelAction.PanelOff(transitional = true)),
                result.actions,
            )
        }
    }

    @Test
    fun `step from DARK keeps waking and re-applying`() {
        val result = step(state(PanelPhase.DARK), PanelEvent.Step(panelOn = true, PanelStrategy.PANEL_DARK))
        assertEquals(PanelPhase.DARK, result.state.phase)
        assertEquals(
            listOf(PanelAction.WakeGroup, PanelAction.PanelOff(transitional = false)),
            result.actions,
        )
    }

    @Test
    fun `step from USER decides nothing`() {
        val result = step(state(PanelPhase.USER), PanelEvent.Step(panelOn = true, PanelStrategy.PANEL_DARK))
        assertEquals(PanelPhase.USER, result.state.phase)
        assertEquals("only the platform reading is recorded", true, result.state.lastPanelOn)
        assertTrue(result.actions.isEmpty())
    }

    @Test
    fun `step for an own group only wakes it, in every state`() {
        for (phase in PanelPhase.entries) {
            val result = step(state(phase), PanelEvent.Step(panelOn = false, PanelStrategy.GROUP_ONLY))
            assertEquals(phase, result.state.phase)
            assertEquals(listOf(PanelAction.WakeGroup), result.actions)
        }
    }

    @Test
    fun `step for a mirror ends the dark phase and clears the pause`() {
        for (phase in PanelPhase.entries) {
            val result = step(
                state(phase, pausedAtMs = 5_000L),
                PanelEvent.Step(panelOn = true, PanelStrategy.PANEL_ALONE),
            )
            assertEquals(PanelPhase.INIT, result.state.phase)
            assertEquals("the mirror's frames keep the group awake", listOf(PanelAction.WakeGroup), result.actions)
            assertEquals("a mirror is no pause", null, result.state.pausedAtMs)
        }
    }

    @Test
    fun `step records the platform's panel reading for the field log`() {
        val result = step(state(PanelPhase.INIT, lastPanelOn = false), PanelEvent.Step(panelOn = true, PanelStrategy.PANEL_DARK))
        assertEquals(true, result.state.lastPanelOn)
        assertEquals(PanelPhase.USER, result.state.phase)
    }

    // --- PersonUsed --------------------------------------------------

    @Test
    fun `personUsed while dark gives the panel back`() {
        val result = step(state(PanelPhase.DARK), PanelEvent.PersonUsed(PanelYieldReason.TOUCH))
        assertEquals(PanelPhase.USER, result.state.phase)
        assertEquals(listOf(PanelAction.PanelNormal(wake = false)), result.actions)
    }

    @Test
    fun `personUsed during the take-over gives the wake's panel back`() {
        val result = step(state(PanelPhase.WAKE), PanelEvent.PersonUsed(PanelYieldReason.UNLOCK))
        assertEquals(PanelPhase.USER, result.state.phase)
        assertEquals(listOf(PanelAction.PanelNormal(wake = false)), result.actions)
    }

    @Test
    fun `personUsed while the person already has the phone changes nothing`() {
        for (phase in listOf(PanelPhase.INIT, PanelPhase.USER)) {
            for (reason in PanelYieldReason.entries) {
                assertIgnored(state(phase), PanelEvent.PersonUsed(reason))
            }
        }
    }

    // --- InteractiveOff ----------------------------------------------

    @Test
    fun `an off edge inside our own wake settle is ignored in every state`() {
        for (phase in PanelPhase.entries) {
            assertIgnored(
                state(phase, ownUntilMs = 2_000L),
                PanelEvent.InteractiveOff(nowMs = 1_999L, streamsUp = true),
            )
        }
    }

    @Test
    fun `an off edge at the settle boundary is decided`() {
        val result = step(
            state(PanelPhase.DARK, ownUntilMs = 2_000L),
            PanelEvent.InteractiveOff(nowMs = 2_000L, streamsUp = true),
        )
        assertEquals(PanelPhase.USER, result.state.phase)
        assertEquals(listOf(PanelAction.PanelNormal(wake = true)), result.actions)
    }

    @Test
    fun `interactiveOff while dark is the person's press, not a relight`() {
        val result = step(state(PanelPhase.DARK), PanelEvent.InteractiveOff(nowMs = 9_000L, streamsUp = true))
        assertEquals(PanelPhase.USER, result.state.phase)
        assertEquals(listOf(PanelAction.PanelNormal(wake = true)), result.actions)
    }

    @Test
    fun `interactiveOff during the take-over hands the phone back`() {
        val result = step(state(PanelPhase.WAKE), PanelEvent.InteractiveOff(nowMs = 9_000L, streamsUp = true))
        assertEquals(PanelPhase.USER, result.state.phase)
        assertEquals(listOf(PanelAction.PanelNormal(wake = true)), result.actions)
    }

    @Test
    fun `interactiveOff with our streams up on a shared group relights them`() {
        for (phase in listOf(PanelPhase.INIT, PanelPhase.USER)) {
            val result = step(
                state(phase, strategy = PanelStrategy.PANEL_DARK),
                PanelEvent.InteractiveOff(nowMs = 9_000L, streamsUp = true),
            )
            assertEquals(PanelPhase.DARK, result.state.phase)
            assertEquals(listOf(PanelAction.Relight), result.actions)
        }
    }

    @Test
    fun `interactiveOff with no stream or another strategy takes nothing over`() {
        for (phase in listOf(PanelPhase.INIT, PanelPhase.USER)) {
            assertIgnored(state(phase), PanelEvent.InteractiveOff(nowMs = 9_000L, streamsUp = false))
            assertIgnored(
                state(phase, strategy = PanelStrategy.GROUP_ONLY),
                PanelEvent.InteractiveOff(nowMs = 9_000L, streamsUp = true),
            )
            assertIgnored(
                state(phase, strategy = PanelStrategy.PANEL_ALONE),
                PanelEvent.InteractiveOff(nowMs = 9_000L, streamsUp = true),
            )
        }
    }

    // --- OwnWake -----------------------------------------------------

    @Test
    fun `ownWake opens a settle in every state`() {
        for (phase in PanelPhase.entries) {
            val result = step(state(phase), PanelEvent.OwnWake(nowMs = 3_000L))
            assertEquals(3_000L + DarkPanelPolicy.OWN_WAKE_SETTLE_MS, result.state.ownUntilMs)
            assertEquals(phase, result.state.phase)
            assertTrue(result.actions.isEmpty())
        }
    }

    // --- StreamsPaused -----------------------------------------------

    @Test
    fun `streamsPaused keeps a dark or taking-over panel`() {
        for (phase in listOf(PanelPhase.DARK, PanelPhase.WAKE)) {
            val result = step(state(phase), PanelEvent.StreamsPaused(nowMs = 1_000L))
            assertEquals(phase, result.state.phase)
            assertEquals(1_000L, result.state.pausedAtMs)
            assertTrue("the episode is ours: keep it for the grace", result.actions.isEmpty())
        }
    }

    @Test
    fun `streamsPaused with nothing of ours held ends the episode at once`() {
        for (phase in listOf(PanelPhase.INIT, PanelPhase.USER)) {
            val result = step(state(phase), PanelEvent.StreamsPaused(nowMs = 1_000L))
            assertEquals(PanelPhase.INIT, result.state.phase)
            assertEquals(1_000L, result.state.pausedAtMs)
            assertEquals(listOf(PanelAction.NothingHeld), result.actions)
        }
    }

    // --- StreamsResumed ----------------------------------------------

    @Test
    fun `streamsResumed ends the pause in every state`() {
        for (phase in PanelPhase.entries) {
            val result = step(state(phase, pausedAtMs = 1_000L), PanelEvent.StreamsResumed)
            assertEquals(phase, result.state.phase)
            assertEquals(null, result.state.pausedAtMs)
            assertTrue(result.actions.isEmpty())
        }
    }

    // --- GraceExpired ------------------------------------------------

    @Test
    fun `graceExpired without a pause decides nothing in every state`() {
        for (phase in PanelPhase.entries) {
            assertIgnored(state(phase), PanelEvent.GraceExpired(nowMs = 60_000L))
        }
    }

    @Test
    fun `graceExpired before the deadline decides nothing`() {
        assertIgnored(
            state(PanelPhase.DARK, pausedAtMs = 1_000L),
            PanelEvent.GraceExpired(nowMs = 1_000L + DarkPanelPolicy.PAUSE_GRACE_MS - 1),
        )
    }

    @Test
    fun `graceExpired at the deadline asks for the hand back`() {
        val result = step(
            state(PanelPhase.DARK, pausedAtMs = 1_000L),
            PanelEvent.GraceExpired(nowMs = 1_000L + DarkPanelPolicy.PAUSE_GRACE_MS),
        )
        assertEquals("the close that follows owns the restore", PanelPhase.DARK, result.state.phase)
        assertEquals(listOf(PanelAction.GraceOver), result.actions)
    }

    // --- StreamsStopped ----------------------------------------------

    @Test
    fun `streamsStopped while dark or taking over restores and sleeps`() {
        for (phase in listOf(PanelPhase.DARK, PanelPhase.WAKE)) {
            val result = step(state(phase, pausedAtMs = 1_000L), PanelEvent.StreamsStopped)
            assertEquals(PanelPhase.INIT, result.state.phase)
            assertEquals(null, result.state.pausedAtMs)
            assertEquals(listOf(PanelAction.RestoreAndSleep), result.actions)
        }
    }

    @Test
    fun `streamsStopped while the person has the phone restores nothing`() {
        for (phase in listOf(PanelPhase.INIT, PanelPhase.USER)) {
            val result = step(state(phase, pausedAtMs = 1_000L), PanelEvent.StreamsStopped)
            assertEquals(PanelPhase.INIT, result.state.phase)
            assertEquals(null, result.state.pausedAtMs)
            assertTrue(result.actions.isEmpty())
        }
    }

    // --- the live holder ---------------------------------------------

    @Test
    fun `the holder logs the transition path`() {
        val lines = mutableListOf<String>()
        val policy = DarkPanelPolicy(forced = false)
        policy.logger = { lines.add(it) }
        policy.streamsStarted()
        policy.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertEquals(
            listOf("panelpolicy: INIT --step--> DARK"),
            lines,
        )
    }

    @Test
    fun `the holder keeps the forced flag in its state`() {
        val policy = DarkPanelPolicy(forced = true)
        assertTrue(policy.current.forced)
        assertFalse(DarkPanelPolicy(forced = false).current.forced)
    }
}
