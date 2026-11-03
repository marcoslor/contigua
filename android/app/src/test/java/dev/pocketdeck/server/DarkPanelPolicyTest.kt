package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
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

    // --- an episode that starts while the group sleeps ----------------
    // The 10-30 report: the VD starts OFF with the panel's group, the activity
    // launch waits for the group to wake, and the take-over only ran after the
    // launch and its task wait (23 s to the first frame). The take-over is now
    // the episode start's own action, before the launch; the panel-off it owes
    // is the first step's.

    @Test
    fun `an episode on a sleeping group is woken before the launch, panel off after`() {
        val p = policy(forced = true)
        p.streamsStarted()
        val takeOver = p.episodeStarted(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertNotNull("the take-over must not wait for the launch", takeOver)
        // The panel-off is armed before the wake and owed again to the first
        // step: the platform answers the wake with its own ON either way.
        assertEquals(PanelPlan(wake = true, panelOff = true, transitional = true), takeOver)
        assertTrue(
            "the shared group is woken now",
            DarkPanelPolicy.wakesGroup(PanelStrategy.PANEL_DARK, takeOver!!),
        )
        // The wake lights the lock screen: the first step still owes the
        // panel-off, does not wake again, and keeps the transitional re-applies.
        val step = p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK)
        assertEquals(PanelPlan(wake = false, panelOff = true, transitional = true), step)
        // From there it is the existing steady dark path.
        assertEquals(
            PanelPlan(wake = true, panelOff = true, transitional = false),
            p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK),
        )
    }

    @Test
    fun `a take-over in flight is not repeated when the step already decided`() {
        val p = policy(forced = true)
        p.streamsStarted()
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertNull(p.episodeStarted(panelOn = false, strategy = PanelStrategy.PANEL_DARK))
    }

    @Test
    fun `no step after the take-over issues a group wake while the panel is owed off`() {
        val p = policy(forced = true)
        p.streamsStarted()
        val takeOver = p.episodeStarted(panelOn = false, strategy = PanelStrategy.PANEL_DARK)!!
        assertTrue(
            "the take-over is the one wake of the episode",
            DarkPanelPolicy.wakesGroup(PanelStrategy.PANEL_DARK, takeOver),
        )
        // The platform's display controller reports the panel on again after
        // the wake; every following step still owes the panel off and must not
        // ask for another group wake (the 11-01 step 2 line was a plan, not a
        // physical flash: SurfaceFlinger stayed OFF).
        p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK)
        repeat(3) {
            val plan = p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK)
            assertTrue("the panel-off stays owed", plan.panelOff)
            assertFalse(
                "a shared-group step beside a dark panel never wakes the group",
                DarkPanelPolicy.wakesGroup(PanelStrategy.PANEL_DARK, plan),
            )
        }
    }

    @Test
    fun `an episode on a lit panel is never taken over`() {
        val p = policy(forced = true)
        p.streamsStarted()
        assertNull("the person's panel is not ours to take", p.episodeStarted(panelOn = true, strategy = PanelStrategy.PANEL_DARK))
        val step = p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK)
        assertFalse(step.wake || step.panelOff || step.transitional)
    }

    @Test
    fun `an own-group episode is woken before its launch without owing a panel-off`() {
        val p = policy()
        p.streamsStarted()
        val takeOver = requireNotNull(p.episodeStarted(panelOn = false, strategy = PanelStrategy.GROUP_ONLY)) {
            "its own group also starts asleep with a new VD"
        }
        assertTrue(takeOver.wake)
        assertFalse(takeOver.panelOff)
        assertTrue("the step's own-group wake stays a harmless repeat", p.step(panelOn = false, strategy = PanelStrategy.GROUP_ONLY).wake)
    }

    @Test
    fun `a mirror is never woken before the launch`() {
        val p = policy(forced = true)
        p.streamsStarted()
        assertNull(p.episodeStarted(panelOn = false, strategy = PanelStrategy.PANEL_ALONE))
    }

    @Test
    fun `a close during the take-over hands the wake's panel back`() {
        val p = policy(forced = true)
        p.streamsStarted()
        p.episodeStarted(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertTrue("the wake lit the panel: a failed launch must restore it", p.streamsStopped())
    }

    @Test
    fun `a press during the take-over is the person's`() {
        val p = policy(forced = true)
        p.streamsStarted()
        p.episodeStarted(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        p.ownWake(nowMs = 1_000)
        assertEquals(
            "our own wake's off edge is not a press",
            PowerWatchAction.NONE,
            p.interactiveOff(nowMs = 1_100, streamsUp = true),
        )
        assertEquals(
            PowerWatchAction.HAND_BACK,
            p.interactiveOff(nowMs = 3_000, streamsUp = true),
        )
    }

    @Test
    fun `a pause during the take-over keeps the owed panel-off`() {
        val p = policy(forced = true)
        p.streamsStarted()
        p.episodeStarted(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertFalse("the panel is already ours", p.streamsPaused(nowMs = 1_000))
        assertEquals(
            PanelPlan(wake = false, panelOff = true, transitional = true),
            p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK),
        )
    }

    // --- the person's direct use wins (CTRL-11) -----------------------

    @Test
    fun `a power press while we own the panel hands the phone back`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK) // our forced-dark panel

        assertEquals(
            "the press is the person's: one hand back",
            PowerWatchAction.HAND_BACK,
            p.interactiveOff(nowMs = 9_000, streamsUp = true),
        )
        // The hand back is the whole decision: no relight, and no later tick
        // re-darkens the panel the person is now looking at.
        repeat(3) {
            val after = p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
            assertFalse("no wake after the hand back", after.wake)
            assertFalse("no panel-off after the hand back", after.panelOff)
        }
        assertFalse("the episode is the person's now", p.streamsStopped())
    }

    @Test
    fun `a press while dark is not also a relight`() {
        // The 16:33 race: the same press decided twice, once by a keep-alive
        // tick (relight + transitional re-apply) and once by the watch (hand
        // back). A tick now only reads the phase the watch decided.
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertEquals(PowerWatchAction.HAND_BACK, p.interactiveOff(nowMs = 9_000, streamsUp = true))
        val plan = p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertFalse("a press while dark never re-lights the streams", plan.wake)
        assertFalse("and never re-applies the panel-off", plan.panelOff)
        assertFalse(plan.transitional)
    }

    @Test
    fun `an unlock while the panel is dark gives it back`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK) // our forced-dark panel
        assertTrue("the panel is ours to give back", p.personUsed(PanelYieldReason.UNLOCK))
        val after = p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK)
        assertFalse(after.panelOff)
        assertFalse(after.wake)
    }

    @Test
    fun `a touch on display 0 while the panel is dark gives it back`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK)
        assertTrue(p.personUsed(PanelYieldReason.TOUCH))
        assertFalse(p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK).panelOff)
    }

    @Test
    fun `a key on display 0 while the panel is dark gives it back`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK)
        assertFalse("a panel that was already the person's is not ours to give", p.personUsed(PanelYieldReason.KEY))

        val q = policy()
        q.streamsStarted()
        q.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertTrue(q.personUsed(PanelYieldReason.KEY))
    }

    @Test
    fun `a second stream opening never darkens the panel the person is using`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK) // first stream: dark
        assertTrue(p.personUsed(PanelYieldReason.TOUCH)) // the person touches display 0

        // A second Mac window opens: the episode is already running, so the
        // policy only steps. The panel stays the person's.
        repeat(3) {
            val plan = p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK)
            assertFalse(plan.panelOff)
            assertFalse(plan.wake)
            assertFalse(plan.transitional)
        }
    }

    @Test
    fun `the panel darkens again only once the phone goes idle by itself`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertTrue(p.personUsed(PanelYieldReason.UNLOCK))

        // The person's screen times out (or they lock it) with the streams up:
        // the watch takes the panel over again, once, at the edge.
        assertEquals(
            PowerWatchAction.RELIGHT,
            p.interactiveOff(nowMs = 40_000, streamsUp = true),
        )
        val dark = p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertTrue(dark.wake)
        assertTrue(dark.panelOff)
    }

    @Test
    fun `a yield while the panel is not ours changes nothing`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK) // the person's own screen
        assertFalse(p.personUsed(PanelYieldReason.TOUCH))
    }

    @Test
    fun `the user's screen is left alone while it is on`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK)
        p.interactiveOff(nowMs = 9_000, streamsUp = true) // power press

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
        assertEquals(PowerWatchAction.HAND_BACK, p.interactiveOff(nowMs = 9_000, streamsUp = true))

        assertEquals(
            "their own screen going off again re-lights the streams",
            PowerWatchAction.RELIGHT,
            p.interactiveOff(nowMs = 40_000, streamsUp = true),
        )
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

        // The screen going off is the watch's edge, never a tick's.
        val later = p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertFalse("a tick does not take over on an off edge", later.wake)
        assertFalse(later.panelOff)
        assertEquals(PowerWatchAction.RELIGHT, p.interactiveOff(nowMs = 5_000, streamsUp = true))
        val dark = p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertTrue("the watch's relight takes the panel over", dark.wake)
        assertTrue(dark.panelOff)
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
        assertEquals(PowerWatchAction.HAND_BACK, p.interactiveOff(nowMs = 9_000, streamsUp = true))
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

    // --- the person's power press with app streams up (L1) -------------

    @Test
    fun `a press while the person holds the phone re-lights our VDs at once`() {
        val p = policy()
        p.streamsStarted()
        // The person's own screen with one app window streaming: nothing of
        // ours is dark, so the policy waits for its next 2 s step.
        val user = p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK)
        assertFalse(user.wake || user.panelOff)

        // The press sleeps the panel's group, which our VDs share. The watch
        // must take the panel over now, not at the next keep-alive step.
        assertEquals(PowerWatchAction.RELIGHT,
                     p.interactiveOff(nowMs = 5_000, streamsUp = true))
        // From here it is the existing PANEL_DARK path: every step wakes the
        // streaming group and holds the panel off under it. The immediate
        // take-over itself (wake, then panel off, transitional) is the caller's
        // action from the RELIGHT result.
        val dark = p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertTrue("the VD group is woken", dark.wake)
        assertTrue("the panel is powered off under it", dark.panelOff)
    }

    @Test
    fun `a press while the panel is ours and dark still hands it back`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK) // our forced-dark panel reads on
        assertEquals(PowerWatchAction.HAND_BACK,
                     p.interactiveOff(nowMs = 9_000, streamsUp = true))
        // The person's screen is theirs from here (the existing rule).
        val after = p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK)
        assertFalse(after.wake || after.panelOff)
    }

    @Test
    fun `our own wake is not a press`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        p.ownWake(nowMs = 1_000)
        assertEquals("the panel-off we just wrote is not the person",
                     PowerWatchAction.NONE, p.interactiveOff(nowMs = 1_100, streamsUp = true))
        // Once the settle is over a real press is handled again.
        assertEquals(PowerWatchAction.HAND_BACK, p.interactiveOff(nowMs = 3_000, streamsUp = true))
    }

    @Test
    fun `a press with no app stream up takes nothing over`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK)
        assertEquals(PowerWatchAction.NONE, p.interactiveOff(nowMs = 5_000, streamsUp = false))
    }

    @Test
    fun `own-group builds leave the person's screen off alone`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = true, strategy = PanelStrategy.GROUP_ONLY)
        assertEquals(PowerWatchAction.NONE, p.interactiveOff(nowMs = 5_000, streamsUp = true))
    }

    @Test
    fun `a mirrored panel is never taken over by a press`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = true, strategy = PanelStrategy.PANEL_ALONE)
        assertEquals(PowerWatchAction.NONE, p.interactiveOff(nowMs = 5_000, streamsUp = true))
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
        assertEquals(PowerWatchAction.HAND_BACK, p.interactiveOff(nowMs = 9_000, streamsUp = true))
        // The user is using the phone: never darken it, never wake it.
        repeat(3) {
            val plan = p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK)
            assertFalse(plan.panelOff)
            assertFalse(plan.wake)
        }
        // Their own screen-off (a timeout): the watch re-lights the stream.
        assertEquals(PowerWatchAction.RELIGHT, p.interactiveOff(nowMs = 40_000, streamsUp = true))
        val off = p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertTrue(off.panelOff)
        // The phone is ours again after that relight, so the close restores it.
        assertTrue(p.streamsStopped())
    }

    @Test
    fun `a power press is only ours to handle while dark`() {
        val p = policy()
        p.streamsStarted()
        p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK) // user already had it
        assertFalse(p.personUsed(PanelYieldReason.POWER))
    }
}
