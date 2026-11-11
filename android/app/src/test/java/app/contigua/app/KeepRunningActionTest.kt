package app.contigua.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The one keep-running action shared by the onboarding step and the home switch
 * (docs/specs/phone-app.md PHONE-19). The reported bug: the onboarding button
 * stored "asked" and never turned the pref on, so nothing visible happened.
 */
class KeepRunningActionTest {

    private class Recorder(exempt: Boolean, private val opens: Boolean = true) {
        var exemptNow = exempt
        val stored = mutableListOf<Boolean>()
        var serviceStarts = 0
        var requests = 0
        val log = mutableListOf<String>()

        val action = KeepRunningAction(
            isExempt = { exemptNow },
            store = { stored += it },
            startService = { serviceStarts++ },
            requestExemption = { requests++; opens },
            log = { log += it },
        )
    }

    @Test
    fun `turning it on stores the pref and starts the service`() {
        val r = Recorder(exempt = true)

        assertEquals(KeepRunningAction.Result.ON_EXEMPT, r.action.apply(true))
        assertEquals(listOf(true), r.stored)
        assertEquals(1, r.serviceStarts)
    }

    @Test
    fun `the exemption is asked only while it is missing`() {
        val exempt = Recorder(exempt = true)
        val restricted = Recorder(exempt = false)

        assertEquals(KeepRunningAction.Result.ON_EXEMPT, exempt.action.apply(true))
        assertEquals(KeepRunningAction.Result.ON_ASKED, restricted.action.apply(true))

        assertEquals(0, exempt.requests)
        assertEquals(1, restricted.requests)
    }

    @Test
    fun `a missing exemption that opens a settings screen is reported as asked`() {
        val r = Recorder(exempt = false, opens = true)

        assertEquals(KeepRunningAction.Result.ON_ASKED, r.action.apply(true))
    }

    @Test
    fun `a missing exemption with no settings screen is reported, not swallowed`() {
        val r = Recorder(exempt = false, opens = false)

        assertEquals(KeepRunningAction.Result.ON_SETTINGS_UNAVAILABLE, r.action.apply(true))
        assertTrue("the failure needs a log line", r.log.any { it.contains("no battery settings") })
    }

    @Test
    fun `turning it off stores the pref and never starts or asks`() {
        val r = Recorder(exempt = false)

        assertEquals(KeepRunningAction.Result.OFF, r.action.apply(false))
        assertEquals(listOf(false), r.stored)
        assertEquals(0, r.serviceStarts)
        assertEquals(0, r.requests)
    }

    @Test
    fun `the pref is stored before the service starts`() {
        val order = mutableListOf<String>()
        val action = KeepRunningAction(
            isExempt = { true },
            store = { order += "store" },
            startService = { order += "start" },
            requestExemption = { order += "ask"; true },
        )

        action.apply(true)

        assertEquals(listOf("store", "start"), order)
    }
}
