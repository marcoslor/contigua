package app.contigua.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Every (state, event) pair of the shell binding, with the actions each one
 * returns (docs/specs/phone-app.md PHONE-20/PHONE-23). The pairs the machine
 * must ignore are in the same table: an ignored event changes nothing and does
 * nothing.
 */
class ShellBindingTest {

    private fun machine(maxTries: Int = ShellBinding.MAX_TRIES) = ShellBinding(maxTries = maxTries)

    /** Feed the machine a path; the last state is the one under test. */
    private fun ShellBinding.drive(vararg events: ShellEvent): List<ShellAction> =
        events.toList().flatMap { transition(it) }

    private fun List<ShellAction>.sig(): String = joinToString(",") { action ->
        when (action) {
            ShellAction.CheckPermission -> "check"
            ShellAction.BindService -> "bind"
            is ShellAction.ArmTimeout -> "timeout(${action.ms})"
            ShellAction.CancelTimers -> "cancel"
            ShellAction.ProbeBinder -> "probe"
            is ShellAction.WaitThenRetry -> "wait(${action.ms})"
            ShellAction.ReportReady -> "ready"
            is ShellAction.ReportFailure -> "fail(${action.failure.describe()})"
            is ShellAction.RestartSelf ->
                "restart(${action.reason.describe()},${if (action.bounded) "auto" else "tap"})"
        }
    }

    private val bound = ShellEvent.BindFailed(ShellFailure(ShellFailure.BIND_FAILED, "SecurityException"))

    /**
     * A machine parked in each state. Built by transitions only: a state that
     * no path reaches would be a state the app can never be in.
     */
    private fun parked(state: String): ShellBinding {
        val m = machine()
        when (state) {
            "NoBinder" -> Unit
            "NeedsPermission" -> m.transition(ShellEvent.BinderReceived)
            "Binding" -> m.drive(ShellEvent.BinderReceived, ShellEvent.PermissionGranted)
            "WaitingRetry" -> m.drive(ShellEvent.BinderReceived, ShellEvent.PermissionGranted, bound)
            "Ready" -> m.drive(ShellEvent.BinderReceived, ShellEvent.PermissionGranted, ShellEvent.BindSucceeded)
            "Failed" -> m.drive(
                ShellEvent.BinderReceived,
                ShellEvent.PermissionGranted,
                ShellEvent.BindTimedOut,
                ShellEvent.RetryTick,
                ShellEvent.BindTimedOut,
                ShellEvent.RetryTick,
                ShellEvent.BindTimedOut,
            )
            else -> error("unknown state $state")
        }
        return m
    }

    private val states = listOf("NoBinder", "NeedsPermission", "Binding", "WaitingRetry", "Ready", "Failed")

    private val events = listOf(
        ShellEvent.Started,
        ShellEvent.BinderReceived,
        ShellEvent.BinderDead,
        ShellEvent.PermissionGranted,
        ShellEvent.PermissionDenied,
        ShellEvent.BindSucceeded,
        bound,
        ShellEvent.BindTimedOut,
        ShellEvent.BinderAbsent,
        ShellEvent.ServiceDied,
        ShellEvent.RetryRequested,
        ShellEvent.RestartRequested,
        ShellEvent.RetryTick,
    )

    /** The whole table: state --event--> state + actions. */
    private val table: Map<String, Map<String, Pair<String, String>>> = mapOf(
        "NoBinder" to mapOf(
            "Started" to ("NoBinder" to "probe"),
            "BinderReceived" to ("NeedsPermission" to "check"),
            "BinderDead" to ("NoBinder" to "cancel,probe"),
            "PermissionGranted" to ("NoBinder" to ""),
            "PermissionDenied" to ("NoBinder" to ""),
            "BindSucceeded" to ("NoBinder" to ""),
            "BindFailed" to ("NoBinder" to ""),
            "BindTimedOut" to ("NoBinder" to ""),
            "BinderAbsent" to ("NoBinder" to "wait(10000)"),
            "ServiceDied" to ("NoBinder" to ""),
            "RetryRequested" to ("Failed(binder_dead)" to "cancel,fail(binder_dead),wait(10000)"),
            "RestartRequested" to ("NoBinder" to ""),
            "RetryTick" to ("NoBinder" to "probe"),
        ),
        "NeedsPermission" to mapOf(
            "Started" to ("NeedsPermission" to ""),
            "BinderReceived" to ("NeedsPermission" to ""),
            "BinderDead" to ("NoBinder" to "cancel,probe"),
            "PermissionGranted" to ("Binding(1)" to "bind,timeout(5000)"),
            "PermissionDenied" to ("NeedsPermission" to ""),
            "BindSucceeded" to ("NeedsPermission" to ""),
            "BindFailed" to ("NeedsPermission" to ""),
            "BindTimedOut" to ("NeedsPermission" to ""),
            "BinderAbsent" to ("NeedsPermission" to ""),
            "ServiceDied" to ("NeedsPermission" to ""),
            "RetryRequested" to ("NeedsPermission" to "check"),
            "RestartRequested" to ("NeedsPermission" to ""),
            "RetryTick" to ("NeedsPermission" to ""),
        ),
        "Binding" to mapOf(
            "Started" to ("Binding(1)" to ""),
            "BinderReceived" to ("Binding(1)" to ""),
            "BinderDead" to ("NoBinder" to "cancel,probe"),
            "PermissionGranted" to ("Binding(1)" to ""),
            "PermissionDenied" to ("NeedsPermission" to "cancel"),
            "BindSucceeded" to ("Ready" to "cancel,ready"),
            "BindFailed" to ("WaitingRetry(1, bind_failed/SecurityException)" to "cancel,wait(1000)"),
            "BindTimedOut" to ("WaitingRetry(1, bind_timeout)" to "cancel,wait(1000)"),
            "BinderAbsent" to ("Binding(1)" to ""),
            "ServiceDied" to ("WaitingRetry(1, service_died)" to "cancel,wait(1000)"),
            "RetryRequested" to ("Binding(1)" to ""),
            "RestartRequested" to ("Binding(1)" to ""),
            "RetryTick" to ("Binding(1)" to ""),
        ),
        "WaitingRetry" to mapOf(
            "Started" to ("WaitingRetry(1, bind_failed/SecurityException)" to ""),
            "BinderReceived" to ("WaitingRetry(1, bind_failed/SecurityException)" to ""),
            "BinderDead" to ("NoBinder" to "cancel,probe"),
            "PermissionGranted" to ("WaitingRetry(1, bind_failed/SecurityException)" to ""),
            "PermissionDenied" to ("NeedsPermission" to "cancel"),
            "BindSucceeded" to ("Ready" to "cancel,ready"),
            "BindFailed" to ("WaitingRetry(1, bind_failed/SecurityException)" to ""),
            "BindTimedOut" to ("WaitingRetry(1, bind_failed/SecurityException)" to ""),
            "BinderAbsent" to ("WaitingRetry(1, bind_failed/SecurityException)" to ""),
            "ServiceDied" to ("WaitingRetry(1, bind_failed/SecurityException)" to ""),
            "RetryRequested" to ("Binding(1)" to "cancel,bind,timeout(5000)"),
            "RestartRequested" to ("WaitingRetry(1, bind_failed/SecurityException)" to ""),
            "RetryTick" to ("Binding(2)" to "bind,timeout(5000)"),
        ),
        "Ready" to mapOf(
            "Started" to ("Ready" to ""),
            "BinderReceived" to ("Ready" to ""),
            "BinderDead" to ("NoBinder" to "cancel,probe"),
            "PermissionGranted" to ("Ready" to ""),
            "PermissionDenied" to ("Ready" to ""),
            "BindSucceeded" to ("Ready" to ""),
            "BindFailed" to ("Ready" to ""),
            "BindTimedOut" to ("Ready" to ""),
            "BinderAbsent" to ("Ready" to ""),
            "ServiceDied" to ("WaitingRetry(0, service_died)" to "wait(1000)"),
            "RetryRequested" to ("Ready" to ""),
            "RestartRequested" to ("Ready" to ""),
            "RetryTick" to ("Ready" to ""),
        ),
        "Failed" to mapOf(
            "Started" to ("Failed(bind_timeout)" to ""),
            "BinderReceived" to ("NeedsPermission" to "check"),
            "BinderDead" to ("NoBinder" to "cancel,probe"),
            "PermissionGranted" to ("Failed(bind_timeout)" to ""),
            "PermissionDenied" to ("Failed(bind_timeout)" to ""),
            "BindSucceeded" to ("Ready" to "cancel,ready"),
            "BindFailed" to ("Failed(bind_timeout)" to ""),
            "BindTimedOut" to ("Failed(bind_timeout)" to ""),
            "BinderAbsent" to ("Failed(bind_timeout)" to "wait(30000)"),
            "ServiceDied" to ("Failed(bind_timeout)" to ""),
            "RetryRequested" to ("Binding(1)" to "cancel,bind,timeout(5000)"),
            "RestartRequested" to ("Failed(bind_timeout)" to "restart(bind_timeout,tap),wait(60000)"),
            "RetryTick" to ("Failed(bind_timeout)" to "probe"),
        ),
    )

    @Test
    fun `every state and event pair follows the table`() {
        for (state in states) {
            for (event in events) {
                val row = table.getValue(state)[event.name]
                    ?: error("the table has no row for $state --${event.name}-->")
                val m = parked(state)
                val actions = m.transition(event)
                assertEquals("$state --${event.name}-->", row.first, m.state.describe())
                assertEquals("$state --${event.name}--> actions", row.second, actions.sig())
            }
        }
    }

    @Test
    fun `a round stops after the bound even if failures keep coming`() {
        val m = machine()
        m.drive(ShellEvent.BinderReceived, ShellEvent.PermissionGranted)
        assertEquals("Binding(1)", m.state.describe())
        repeat(20) {
            m.transition(ShellEvent.BindTimedOut)
            if (m.state is ShellState.WaitingRetry) m.transition(ShellEvent.RetryTick)
        }
        assertEquals("Failed(bind_timeout)", m.state.describe())
        assertTrue(m.transition(ShellEvent.BindTimedOut).isEmpty())
        assertEquals("Failed(bind_timeout)", m.state.describe())
    }

    @Test
    fun `the backs off between tries grows and the third try ends the round`() {
        val m = machine()
        m.drive(ShellEvent.BinderReceived, ShellEvent.PermissionGranted)
        assertEquals("cancel,wait(1000)", m.transition(bound).sig())
        m.transition(ShellEvent.RetryTick)
        assertEquals("Binding(2)", m.state.describe())
        assertEquals("cancel,wait(2000)", m.transition(bound).sig())
        m.transition(ShellEvent.RetryTick)
        assertEquals("Binding(3)", m.state.describe())
        assertEquals(
            "cancel,fail(bind_failed/SecurityException),wait(10000)",
            m.transition(bound).sig(),
        )
        assertEquals("Failed(bind_failed/SecurityException)", m.state.describe())
    }

    @Test
    fun `a dead binder ends the round and the next binder recovers without a tap`() {
        val m = parked("Failed")
        m.transition(ShellEvent.BinderDead)
        assertEquals("NoBinder", m.state.describe())
        assertEquals("probe", m.transition(ShellEvent.Started).sig())
        assertEquals("check", m.transition(ShellEvent.BinderReceived).sig())
        assertEquals(
            "bind,timeout(5000)",
            m.transition(ShellEvent.PermissionGranted).sig(),
        )
        assertEquals(
            "cancel,ready",
            m.transition(ShellEvent.BindSucceeded).sig(),
        )
        assertEquals("Ready", m.state.describe())
    }

    @Test
    fun `a served service that dies rebinds after one backoff`() {
        val m = parked("Ready")
        assertEquals("wait(1000)", m.transition(ShellEvent.ServiceDied).sig())
        assertEquals("WaitingRetry(0, service_died)", m.state.describe())
        assertEquals("bind,timeout(5000)", m.transition(ShellEvent.RetryTick).sig())
        assertEquals("Binding(1)", m.state.describe())
        assertEquals("cancel,ready", m.transition(ShellEvent.BindSucceeded).sig())
        assertEquals("Ready", m.state.describe())
    }

    @Test
    fun `the permission is only asked for while the binder is here`() {
        val m = machine()
        assertEquals("check", m.transition(ShellEvent.BinderReceived).sig())
        assertEquals("NeedsPermission", m.state.describe())
        // Denied stays on the Allow card: a tap re-checks, never binds.
        assertTrue(m.transition(ShellEvent.PermissionDenied).isEmpty())
        assertEquals("NeedsPermission", m.state.describe())
        assertEquals("check", m.transition(ShellEvent.RetryRequested).sig())
    }

    @Test
    fun `failure reasons are closed tokens and exceptions keep only their class`() {
        assertEquals("bind_timeout", ShellFailure(ShellFailure.BIND_TIMEOUT).describe())
        assertEquals("binder_dead", ShellFailure(ShellFailure.BINDER_DEAD).describe())
        assertEquals("permission_denied", ShellFailure(ShellFailure.PERMISSION_DENIED).describe())
        assertEquals("service_died", ShellFailure(ShellFailure.SERVICE_DIED).describe())
        assertEquals(
            "bind_failed/IllegalStateException",
            ShellFailure(ShellFailure.BIND_FAILED, "IllegalStateException").describe(),
        )
        // The transition log tells the path with the same tokens.
        assertEquals("BinderReceived", ShellEvent.BinderReceived.describe())
        assertEquals("BinderDead(binder_dead)", ShellEvent.BinderDead.describe())
        assertEquals("PermissionDenied(permission_denied)", ShellEvent.PermissionDenied.describe())
        assertEquals("ServiceDied(service_died)", ShellEvent.ServiceDied.describe())
        assertEquals("BindTimedOut(bind_timeout)", ShellEvent.BindTimedOut.describe())
        assertEquals("BinderAbsent(binder_dead)", ShellEvent.BinderAbsent.describe())
        assertEquals(
            "BindFailed(bind_failed/IllegalStateException)",
            ShellEvent.BindFailed(ShellFailure(ShellFailure.BIND_FAILED, "IllegalStateException")).describe(),
        )
        assertEquals("RetryTick", ShellEvent.RetryTick.describe())
        assertEquals("Started", ShellEvent.Started.describe())
        assertEquals("RestartRequested", ShellEvent.RestartRequested.describe())
    }

    @Test
    fun `the backoff is one second then two`() {
        assertEquals(1_000L, ShellBinding.defaultBackoff(1))
        assertEquals(2_000L, ShellBinding.defaultBackoff(2))
        assertEquals(8_000L, ShellBinding.defaultBackoff(4))
    }

    @Test
    fun `a bind that connects after its timeout is accepted as ready`() {
        // ISS-100: the service cold-starts past the 5 s timeout, so the connect
        // lands while the machine waits to retry ...
        val waiting = parked("WaitingRetry")
        assertEquals("cancel,ready", waiting.transition(ShellEvent.BindSucceeded).sig())
        assertEquals("Ready", waiting.state.describe())

        // ... or after the whole round already gave up.
        val failed = parked("Failed")
        assertEquals("cancel,ready", failed.transition(ShellEvent.BindSucceeded).sig())
        assertEquals("Ready", failed.state.describe())
    }

    @Test
    fun `a failed round keeps trying on a slow schedule with no tap`() {
        val m = parked("Failed")
        assertEquals("probe", m.transition(ShellEvent.RetryTick).sig())
        assertEquals("Failed(bind_timeout)", m.state.describe())
        // The probe found nothing: wait 30 s, then probe again, then every 60 s.
        assertEquals("wait(30000)", m.transition(ShellEvent.BinderAbsent).sig())
        assertEquals("probe", m.transition(ShellEvent.RetryTick).sig())
        assertEquals("wait(60000)", m.transition(ShellEvent.BinderAbsent).sig())
        assertEquals("probe", m.transition(ShellEvent.RetryTick).sig())
        assertEquals("wait(60000)", m.transition(ShellEvent.BinderAbsent).sig())
        // A binder that answers the probe starts a full round on the same step.
        m.transition(ShellEvent.RetryTick)
        assertEquals("check", m.transition(ShellEvent.BinderReceived).sig())
        assertEquals("bind,timeout(5000)", m.transition(ShellEvent.PermissionGranted).sig())
        assertEquals("Binding(1)", m.state.describe())
    }

    @Test
    fun `the slow ladder is one place and stops at a minute`() {
        assertEquals(10_000L, ShellBinding.slowDelay(1))
        assertEquals(30_000L, ShellBinding.slowDelay(2))
        assertEquals(60_000L, ShellBinding.slowDelay(3))
        assertEquals(60_000L, ShellBinding.slowDelay(9))
        assertEquals(3, ShellBinding.RESTART_STEP)
    }

    @Test
    fun `a lost binder probes on the slow schedule and restarts the process once`() {
        val m = machine()
        assertEquals("probe", m.transition(ShellEvent.Started).sig())
        assertEquals("wait(10000)", m.transition(ShellEvent.BinderAbsent).sig())
        assertEquals("probe", m.transition(ShellEvent.RetryTick).sig())
        assertEquals("wait(30000)", m.transition(ShellEvent.BinderAbsent).sig())
        // The 60 s step: one automatic restart of our own process, then never
        // again in this episode (the pref stops it across the restart).
        assertEquals(
            "restart(binder_dead,auto),wait(60000)",
            m.transition(ShellEvent.RetryTick).sig(),
        )
        assertEquals("probe", m.transition(ShellEvent.RetryTick).sig())
        assertEquals("wait(60000)", m.transition(ShellEvent.BinderAbsent).sig())
        assertEquals("probe", m.transition(ShellEvent.RetryTick).sig())
    }

    @Test
    fun `a binder that arrives while the restart waits still binds`() {
        val m = machine()
        m.drive(ShellEvent.Started, ShellEvent.BinderAbsent, ShellEvent.RetryTick, ShellEvent.BinderAbsent)
        assertEquals("restart(binder_dead,auto),wait(60000)", m.transition(ShellEvent.RetryTick).sig())
        assertEquals("check", m.transition(ShellEvent.BinderReceived).sig())
        assertEquals("NeedsPermission", m.state.describe())
    }

    @Test
    fun `the tap restarts the connection when the binder answers`() {
        val m = parked("Failed")
        assertEquals(
            "restart(bind_timeout,tap),wait(60000)",
            m.transition(ShellEvent.RestartRequested).sig(),
        )
        // A tap is consent: the restart itself is not bounded by the episode
        // flag, but it must not loop by itself afterwards.
        assertEquals("probe", m.transition(ShellEvent.RetryTick).sig())
    }
}
