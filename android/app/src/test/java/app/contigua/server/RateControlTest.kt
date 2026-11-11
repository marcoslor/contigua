package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The one rate machine (PATH-47/48/49): every phase/rung × event pair,
 * including the windows it must ignore, the two debug switches, a kept resize
 * and an explicit quality cancel.
 */
class RateControlTest {

    private val control = RateControl()
    private val fresh = RateControlState()
    private val high = 200_000L
    private val low = 20_000L
    private val mid = 70_000L
    private val link = 4_000_000
    private val belief = 8_000_000

    private fun window(
        state: RateControlState,
        nowMs: Long,
        delayP95Us: Long? = high,
        delayP50Us: Long? = if (delayP95Us != null) {
            delayP95Us.coerceAtMost(70_000L)
        } else {
            null
        },
        linkBps: Int? = link,
        believedBps: Int = belief,
        atFloor: Boolean = false,
        early: Boolean = true,
        ladder: Boolean = true,
    ): RateControlStep = control.step(
        state,
        RateControlEvent.Window(
            nowMs, delayP95Us, delayP50Us, linkBps, believedBps, atFloor, early, ladder,
        ),
    )

    private fun lowered(step: RateControlStep): Int? =
        (step.action as? RateControlAction.LowerTo)?.bps

    private fun scaled(step: RateControlStep): RateControlAction.Scale? =
        step.action as? RateControlAction.Scale

    // --- Steady ---------------------------------------------------------

    @Test
    fun `steady ignores a window with no samples`() {
        val step = window(fresh, 0, delayP95Us = null)
        assertEquals(RatePhase.Steady, step.state.phase)
        assertEquals(LadderRung.Full, step.state.rung)
        assertNull(lowered(step))
        assertNull(step.line)
    }

    @Test
    fun `steady ignores a low delay`() {
        val step = window(fresh, 0, delayP95Us = low)
        assertEquals(RatePhase.Steady, step.state.phase)
        assertEquals(RateControlState.NO_TIME, step.state.highSinceMs)
        assertNull(lowered(step))
    }

    @Test
    fun `steady lowers on the first high window`() {
        val step = window(fresh, 0)
        assertEquals(RatePhase.Pressured, step.state.phase)
        assertEquals(0, step.state.highSinceMs)
        assertEquals(3_000_000, lowered(step))
        assertTrue(step.line!!.contains("steady/full --hold--> pressured/full"))
        assertEquals(0, step.state.lastLowerAtMs)
    }

    @Test
    fun `steady takes the phase without a link reading`() {
        val step = window(fresh, 0, linkBps = null)
        assertEquals(RatePhase.Pressured, step.state.phase)
        assertNull("no link, no cap", lowered(step))
        assertTrue(step.line!!.contains("--hold-->"))
    }

    @Test
    fun `steady takes the phase when the belief already fits the link`() {
        val step = window(fresh, 0, linkBps = 12_000_000)
        assertEquals(RatePhase.Pressured, step.state.phase)
        assertNull("8 Mbps under 75% of 12 Mbps needs no move", lowered(step))
    }

    // --- Pressured ------------------------------------------------------

    @Test
    fun `pressured follows a lower link once per interval`() {
        var step = window(fresh, 0)
        assertEquals(3_000_000, lowered(step))
        val tooSoon = window(step.state, 1_000, linkBps = 2_000_000)
        assertNull(lowered(tooSoon))
        val next = window(tooSoon.state, 2_000, linkBps = 2_000_000)
        assertEquals(1_500_000, lowered(next))
        assertEquals(2_000, next.state.lastLowerAtMs)
    }

    @Test
    fun `pressured ignores a high window without a link`() {
        var step = window(fresh, 0)
        step = window(step.state, 3_000, linkBps = null)
        assertNull(lowered(step))
        assertEquals(RatePhase.Pressured, step.state.phase)
    }

    @Test
    fun `pressured returns to steady after five calm seconds`() {
        var step = window(fresh, 0)
        step = window(step.state, 1_000, delayP95Us = low)
        assertEquals(RatePhase.Pressured, step.state.phase)
        assertEquals(1_000, step.state.calmSinceMs)
        step = window(step.state, 5_999, delayP95Us = low)
        assertEquals("not yet", RatePhase.Pressured, step.state.phase)
        step = window(step.state, 6_000, delayP95Us = low)
        assertEquals(RatePhase.Steady, step.state.phase)
        assertTrue(step.line!!.contains("pressured/full --calm--> steady/full"))
    }

    @Test
    fun `a missing window breaks the calm run`() {
        var step = window(fresh, 0)
        step = window(step.state, 1_000, delayP95Us = low)
        step = window(step.state, 3_000, delayP95Us = null)
        assertEquals(RateControlState.NO_TIME, step.state.calmSinceMs)
        step = window(step.state, 4_000, delayP95Us = low)
        assertEquals(4_000, step.state.calmSinceMs)
        assertEquals(RatePhase.Pressured, step.state.phase)
    }

    @Test
    fun `a high window breaks the calm run`() {
        var step = window(fresh, 0)
        step = window(step.state, 1_000, delayP95Us = low)
        step = window(step.state, 2_000, delayP95Us = high)
        assertEquals(RateControlState.NO_TIME, step.state.calmSinceMs)
    }

    // --- Drop / Quality / Reset ----------------------------------------

    @Test
    fun `a drop keeps the drop rule alone for two seconds`() {
        var step = control.step(fresh, RateControlEvent.Drop(500))
        assertEquals(RatePhase.Steady, step.state.phase)
        assertTrue(step.line!!.contains("--drop-->"))
        step = window(step.state, 1_000)
        assertEquals(RatePhase.Pressured, step.state.phase)
        assertNull("the drop rule owns the episode", lowered(step))
        step = window(step.state, 2_600)
        assertEquals(3_000_000, lowered(step))
    }

    @Test
    fun `a drop clears the runs and keeps the rung`() {
        val state = RateControlState(
            phase = RatePhase.Pressured,
            rung = LadderRung.Half,
            baseBps = 8_000_000,
            calmSinceMs = 1_000,
            ladderCalmSinceMs = 2_000,
            stressSinceMs = 3_000,
        )
        val step = control.step(state, RateControlEvent.Drop(9_000))
        assertEquals(LadderRung.Half, step.state.rung)
        assertEquals(8_000_000, step.state.baseBps)
        assertEquals(3_000, step.state.stressSinceMs)
        assertEquals(RateControlState.NO_TIME, step.state.calmSinceMs)
        assertEquals(RateControlState.NO_TIME, step.state.ladderCalmSinceMs)
        assertEquals(9_000, step.state.lastDropAtMs)
    }

    @Test
    fun `quality returns a pressured stream to steady`() {
        val state = RateControlState(phase = RatePhase.Pressured)
        val step = control.step(state, RateControlEvent.Quality)
        assertEquals(RatePhase.Steady, step.state.phase)
        assertEquals(LadderRung.Full, step.state.rung)
        assertEquals(RateControlAction.None, step.action)
        assertTrue(step.line!!.contains("--quality-->"))
    }

    @Test
    fun `quality cancels the rung and asks for the asked box`() {
        val state = RateControlState(
            phase = RatePhase.Pressured,
            rung = LadderRung.Half,
            baseBps = 8_000_000,
        )
        val step = control.step(state, RateControlEvent.Quality)
        assertEquals(RatePhase.Steady, step.state.phase)
        assertEquals(LadderRung.Full, step.state.rung)
        assertEquals(
            RateControlAction.Scale(LadderRung.Half, LadderRung.Full, 8_000_000),
            step.action,
        )
        assertTrue(step.line!!.contains("pressured/half --quality--> steady/full"))
    }

    @Test
    fun `reset returns any state to steady full`() {
        val state = RateControlState(
            phase = RatePhase.Pressured,
            rung = LadderRung.Half,
            baseBps = 8_000_000,
            lastDropAtMs = 500,
        )
        val step = control.step(state, RateControlEvent.Reset)
        assertEquals(RateControlState(), step.state)
        assertEquals(RateControlAction.None, step.action)
    }

    // --- Caps and debounce --------------------------------------------

    @Test
    fun `a quarter megabit link caps at the encoder floor`() {
        val step = window(fresh, 0, linkBps = 200_000)
        assertEquals(250_000, lowered(step))
    }

    @Test
    fun `a lower belief is left alone`() {
        val step = window(fresh, 0, believedBps = 3_000_000)
        assertEquals(RatePhase.Pressured, step.state.phase)
        assertNull(lowered(step))
    }

    @Test
    fun `the early signal can be disabled`() {
        val first = window(fresh, 0, atFloor = true, early = false)
        assertEquals(RatePhase.Steady, first.state.phase)
        assertNull(lowered(first))
        assertNull("the ladder still has to fill its five seconds", scaled(first))
        val step = window(first.state, 5_000, atFloor = true, early = false)
        assertEquals(
            RateControlAction.Scale(LadderRung.Full, LadderRung.ThreeQuarters, 8_000_000),
            step.action,
        )
    }

    // --- Ladder: down --------------------------------------------------

    @Test
    fun `full watches the floor and a high delay`() {
        val step = window(fresh, 0, atFloor = true, early = false)
        assertEquals(LadderRung.Full, step.state.rung)
        assertEquals(0, step.state.stressSinceMs)
        assertNull(scaled(step))
    }

    @Test
    fun `full ignores a high delay when the belief is not at the floor`() {
        val step = window(fresh, 0, atFloor = false, early = false)
        assertEquals(RateControlState.NO_TIME, step.state.stressSinceMs)
        assertNull(scaled(step))
    }

    @Test
    fun `full ignores calm and missing windows`() {
        assertNull(scaled(window(fresh, 0, delayP95Us = low, atFloor = true, early = false)))
        assertNull(scaled(window(fresh, 0, delayP95Us = null, atFloor = true, early = false)))
    }

    @Test
    fun `full steps to three quarters after five stressed seconds`() {
        val first = window(fresh, 0, atFloor = true, early = false)
        val step = window(first.state, 5_000, atFloor = true, early = false)
        assertEquals(LadderRung.ThreeQuarters, step.state.rung)
        assertEquals(8_000_000, step.state.baseBps)
        assertEquals(
            RateControlAction.Scale(LadderRung.Full, LadderRung.ThreeQuarters, 8_000_000),
            step.action,
        )
        assertTrue(step.line!!.contains("steady/full --stress--> steady/three-quarters"))
        assertEquals(5_000, step.state.lastStepAtMs)
    }

    @Test
    fun `three quarters steps to half on more stress`() {
        val state = RateControlState(rung = LadderRung.ThreeQuarters, baseBps = 5_000_000)
        val first = window(state, 0, atFloor = true, early = false)
        val step = window(first.state, 5_000, atFloor = true, early = false)
        assertEquals(LadderRung.Half, step.state.rung)
        assertEquals(5_000_000, step.state.baseBps)
        assertEquals(
            RateControlAction.Scale(LadderRung.ThreeQuarters, LadderRung.Half, 5_000_000),
            step.action,
        )
    }

    @Test
    fun `half is the bottom rung`() {
        val state = RateControlState(rung = LadderRung.Half)
        val first = window(state, 0, atFloor = true, early = false)
        val step = window(first.state, 20_000, atFloor = true, early = false)
        assertEquals(LadderRung.Half, step.state.rung)
        assertNull(scaled(step))
    }

    // --- Ladder: up ----------------------------------------------------

    @Test
    fun `three quarters steps back to full after thirty calm seconds`() {
        val state = RateControlState(rung = LadderRung.ThreeQuarters, baseBps = 4_000_000)
        val first = window(state, 0, delayP95Us = low, atFloor = true, early = false)
        val step = window(first.state, 30_000, delayP95Us = low, atFloor = true, early = false)
        assertEquals(LadderRung.Full, step.state.rung)
        assertEquals(
            RateControlAction.Scale(LadderRung.ThreeQuarters, LadderRung.Full, 4_000_000),
            step.action,
        )
        assertTrue(step.line!!.contains("--recover-->"))
    }

    @Test
    fun `half steps back one rung, not two`() {
        val state = RateControlState(rung = LadderRung.Half, baseBps = 4_000_000)
        val first = window(state, 0, delayP95Us = low, atFloor = true, early = false)
        val step = window(first.state, 30_000, delayP95Us = low, atFloor = true, early = false)
        assertEquals(LadderRung.ThreeQuarters, step.state.rung)
        assertEquals(
            RateControlAction.Scale(LadderRung.Half, LadderRung.ThreeQuarters, 4_000_000),
            step.action,
        )
    }

    @Test
    fun `the middle band resets both runs`() {
        val stressed = window(fresh, 0, atFloor = true, early = false)
        val step = window(stressed.state, 3_000, delayP95Us = mid, atFloor = true, early = false)
        assertEquals(RateControlState.NO_TIME, step.state.stressSinceMs)
        assertEquals(RateControlState.NO_TIME, step.state.ladderCalmSinceMs)
        assertEquals(LadderRung.Full, step.state.rung)
    }

    @Test
    fun `a missing window is not calm`() {
        val state = RateControlState(rung = LadderRung.ThreeQuarters)
        val first = window(state, 0, delayP95Us = null, atFloor = true, early = false)
        assertEquals(RateControlState.NO_TIME, first.state.ladderCalmSinceMs)
        assertEquals(LadderRung.ThreeQuarters, first.state.rung)
    }

    @Test
    fun `one step per half minute`() {
        // An up-step at 0, then stress: five seconds is not enough to step
        // down while the half-minute hold is running.
        var state = RateControlState(rung = LadderRung.Full, lastStepAtMs = 0)
        state = window(state, 1_000, atFloor = true, early = false).state
        assertEquals(1_000, state.stressSinceMs)
        state = window(state, 6_000, atFloor = true, early = false).state
        assertEquals(LadderRung.Full, state.rung)
        state = window(state, 31_000, atFloor = true, early = false).state
        assertEquals(LadderRung.ThreeQuarters, state.rung)
    }

    @Test
    fun `the ladder can be disabled and restores the asked box`() {
        val state = RateControlState(rung = LadderRung.Half, baseBps = 8_000_000)
        val step = window(state, 0, atFloor = true, early = false, ladder = false)
        assertEquals(LadderRung.Full, step.state.rung)
        assertEquals(
            RateControlAction.Scale(LadderRung.Half, LadderRung.Full, 8_000_000),
            step.action,
        )
        assertTrue(step.line!!.contains("--off-->"))
    }

    // --- Kept resize ---------------------------------------------------

    @Test
    fun `a failed down step returns the rung without moving the belief`() {
        val state = RateControlState(
            phase = RatePhase.Pressured,
            rung = LadderRung.ThreeQuarters,
            baseBps = 4_000_000,
        )
        val step = control.step(
            state,
            RateControlEvent.RungFailed(
                LadderRung.Full, LadderRung.ThreeQuarters, 9_000,
            ),
        )
        assertEquals(LadderRung.Full, step.state.rung)
        assertEquals(4_000_000, step.state.baseBps)
        assertEquals(RateControlAction.None, step.action)
        assertTrue(step.line!!.contains("--kept-->"))
    }

    @Test
    fun `a failed up step returns the rung and keeps the base`() {
        val state = RateControlState(
            phase = RatePhase.Steady,
            rung = LadderRung.Full,
            baseBps = 4_000_000,
        )
        val step = control.step(
            state,
            RateControlEvent.RungFailed(
                LadderRung.ThreeQuarters, LadderRung.Full, 9_000,
            ),
        )
        assertEquals(LadderRung.ThreeQuarters, step.state.rung)
        assertEquals(4_000_000, step.state.baseBps)
    }

    @Test
    fun `a stale rung failure changes nothing`() {
        val state = RateControlState(rung = LadderRung.Half, baseBps = 4_000_000)
        val step = control.step(
            state,
            RateControlEvent.RungFailed(
                LadderRung.Full, LadderRung.ThreeQuarters, 9_000,
            ),
        )
        assertEquals(state, step.state)
        assertNull(step.line)
    }
}
