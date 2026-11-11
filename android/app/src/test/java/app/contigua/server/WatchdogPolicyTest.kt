package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The crash watchdog's decision: only a live panel-override marker (written just
 * before the panel was forced off, deleted once it is restored) gives the
 * watchdog work to do; a clean end or an override that the platform already
 * owns leaves nothing behind.
 */
class WatchdogPolicyTest {

    @Test
    fun `no marker means nothing to restore`() {
        val plan = WatchdogPolicy.onServerGone(markerExists = false, panelOn = true)
        assertFalse(plan.act)
        assertFalse(plan.restorePanel)
        assertFalse(plan.sleep)
    }

    @Test
    fun `a live marker with the panel believed on restores and sleeps`() {
        val plan = WatchdogPolicy.onServerGone(markerExists = true, panelOn = true)
        assertTrue(plan.act)
        assertTrue(plan.restorePanel)
        assertTrue(plan.sleep)
    }

    @Test
    fun `a stale marker whose panel is already off only sleeps`() {
        val plan = WatchdogPolicy.onServerGone(markerExists = true, panelOn = false)
        assertTrue(plan.act)
        assertFalse("the platform's own mode is already the right one", plan.restorePanel)
        assertTrue(plan.sleep)
    }

    @Test
    fun `the plan is symmetric for the off panel case`() {
        assertEquals(
            WatchdogPlan(restorePanel = false, sleep = false),
            WatchdogPolicy.onServerGone(markerExists = false, panelOn = false),
        )
    }
}
