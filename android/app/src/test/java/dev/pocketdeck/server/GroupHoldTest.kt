package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The keep-awake decision for a streaming display (docs/specs/phone-app.md
 * PHONE-22): the display-scoped SCREEN_BRIGHT wake lock and the keep-alive
 * `userActivity` poke both keep the display's power group awake. On a build
 * that puts our virtual display in the panel's group, that group is group 0, so
 * while the person owns the panel neither may be held: the phone's own screen
 * timeout runs, and its off edge re-lights the window displays exactly as a
 * power press does.
 */
class GroupHoldTest {

    private fun hold(
        owner: WakeOwner,
        sharedGroup: Boolean,
        streamsUp: Boolean = true,
    ): GroupHold = groupHold(owner, sharedGroup, streamsUp)

    @Test
    fun `the person's panel on a shared group holds no display lock and gets no poke`() {
        val decision = hold(WakeOwner.PERSON_TOOK_OVER, sharedGroup = true)
        assertFalse("a group-0 display lock keeps the phone's own screen on", decision.displayLock)
        assertFalse("a poke keeps the phone's own screen from timing out", decision.poke)
    }

    @Test
    fun `our wake on a shared group keeps the display lock and the poke`() {
        val decision = hold(WakeOwner.OURS_WOKE, sharedGroup = true)
        assertTrue(decision.displayLock)
        assertTrue(decision.poke)
    }

    @Test
    fun `a phone we did not wake keeps the display lock and the poke`() {
        val decision = hold(WakeOwner.NOT_OURS, sharedGroup = true)
        assertTrue(decision.displayLock)
        assertTrue(decision.poke)
    }

    @Test
    fun `an own display group is held as today in every state`() {
        for (owner in WakeOwner.entries) {
            val decision = hold(owner, sharedGroup = false)
            assertTrue("$owner: its own group never holds the panel awake", decision.displayLock)
            assertTrue("$owner: its own group never pokes the panel", decision.poke)
        }
    }

    @Test
    fun `no stream holds nothing whatever the owner`() {
        for (owner in WakeOwner.entries) {
            val decision = hold(owner, sharedGroup = true, streamsUp = false)
            assertFalse("$owner: a stopped stream must leave no lock", decision.displayLock)
            assertFalse("$owner: a stopped stream sends no poke", decision.poke)
        }
    }

    @Test
    fun `the phone's own timeout re-lights the streams as a press does`() {
        val p = DarkPanelPolicy(forced = false)
        p.streamsStarted()
        // The person's own screen with a shared-group window streaming: the
        // policy leaves the panel alone (PHONE-13).
        val user = p.step(panelOn = true, strategy = PanelStrategy.PANEL_DARK)
        assertFalse(user.wake || user.panelOff)
        // The phone's own screen timeout is the same off edge the watch reads
        // for a press: the streams are re-lit and the panel taken dark.
        assertEquals(
            PowerWatchAction.RELIGHT,
            p.interactiveOff(nowMs = 40_000, streamsUp = true),
        )
        val relit = p.step(panelOn = false, strategy = PanelStrategy.PANEL_DARK)
        assertTrue("the window display is woken", relit.wake)
        assertTrue("the panel stays dark under it", relit.panelOff)
    }
}
