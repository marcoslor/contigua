package dev.pocketdeck.app

/**
 * The app's binding to the shell service inside Shizuku's server, as one pure
 * state machine (AGENTS.md, docs/specs/CONVENTIONS.md CONV-PD-08).
 *
 * The person's 10-28 report drove this: wireless debugging dropped, Shizuku's
 * server died with it, the person started the server again, and nothing ever
 * told the app to bind. The app sat in "Couldn't start" until it was tapped.
 * The machine is the only place the binding's state lives; [ShizukuClient]
 * performs the actions it returns and never keeps its own flags.
 *
 * Everything here is plain Kotlin so every transition is a JVM test.
 */

/**
 * A failure with a closed token. Log lines carry these tokens and, for a thrown
 * exception, only its class name (R-PRIV-1: no message, no device data).
 */
data class ShellFailure(val token: String, val exceptionClass: String? = null) {
    fun describe(): String = if (exceptionClass == null) token else "$token/$exceptionClass"

    companion object {
        const val BIND_TIMEOUT = "bind_timeout"
        const val BINDER_DEAD = "binder_dead"
        const val PERMISSION_DENIED = "permission_denied"
        const val SERVICE_DIED = "service_died"
        const val BIND_FAILED = "bind_failed"
    }
}

/** The binding's states. [Binding] and [WaitingRetry] carry the bounded tries. */
sealed interface ShellState {
    /** Shizuku's binder is not with this process: nothing can be bound yet. */
    data object NoBinder : ShellState

    /** The binder is here but PocketDeck may not use it: the person must allow. */
    data object NeedsPermission : ShellState

    /** A bind is in flight; [tries] counts the binds started in this round. */
    data class Binding(val tries: Int) : ShellState

    /** A bind failed; waiting out its backoff, then [tries] + 1 will start. */
    data class WaitingRetry(val tries: Int, val reason: ShellFailure) : ShellState

    /** The shell service is bound and serving. */
    data object Ready : ShellState

    /** Every try of this round failed: the card offers Try again. */
    data class Failed(val reason: ShellFailure) : ShellState

    fun describe(): String = when (this) {
        NoBinder -> "NoBinder"
        NeedsPermission -> "NeedsPermission"
        is Binding -> "Binding($tries)"
        is WaitingRetry -> "WaitingRetry($tries, ${reason.describe()})"
        Ready -> "Ready"
        is Failed -> "Failed(${reason.describe()})"
    }
}

/** What the driver tells the machine. */
sealed interface ShellEvent {
    data object BinderReceived : ShellEvent
    data object BinderDead : ShellEvent
    data object PermissionGranted : ShellEvent
    data object PermissionDenied : ShellEvent
    data object BindSucceeded : ShellEvent
    data class BindFailed(val failure: ShellFailure) : ShellEvent
    data object BindTimedOut : ShellEvent
    data object ServiceDied : ShellEvent

    /** The person tapped Try again, or a caller asked for the service now. */
    data object RetryRequested : ShellEvent

    /** The backoff elapsed. */
    data object RetryTick : ShellEvent

    val name: String
        get() = when (this) {
            BinderReceived -> "BinderReceived"
            BinderDead -> "BinderDead"
            PermissionGranted -> "PermissionGranted"
            PermissionDenied -> "PermissionDenied"
            BindSucceeded -> "BindSucceeded"
            is BindFailed -> "BindFailed"
            BindTimedOut -> "BindTimedOut"
            ServiceDied -> "ServiceDied"
            RetryRequested -> "RetryRequested"
            RetryTick -> "RetryTick"
        }

    /** The closed failure token this event carries, if it is a failure. */
    val reason: String?
        get() = when (this) {
            BinderDead -> ShellFailure.BINDER_DEAD
            PermissionDenied -> ShellFailure.PERMISSION_DENIED
            ServiceDied -> ShellFailure.SERVICE_DIED
            BindTimedOut -> ShellFailure.BIND_TIMEOUT
            is BindFailed -> failure.describe()
            else -> null
        }

    /** `Event` or `Event(closed_reason)` for the transition log. */
    fun describe(): String = reason?.let { "$name($it)" } ?: name
}

/** What the driver does. Side effects never run inside the transition. */
sealed interface ShellAction {
    /** Ask Shizuku whether PocketDeck may use it (answer as an event). */
    data object CheckPermission : ShellAction

    /** Bind the user service. */
    data object BindService : ShellAction

    /** Start the bind timeout. */
    data class ArmTimeout(val ms: Long) : ShellAction

    data object CancelTimers : ShellAction

    /** Wait out a backoff, then send [ShellEvent.RetryTick]. */
    data class WaitThenRetry(val ms: Long) : ShellAction

    /** The shell service is bound: the foreground service starts its server. */
    data object ReportReady : ShellAction

    /** The round is over: the card shows Couldn't start with Try again. */
    data class ReportFailure(val failure: ShellFailure) : ShellAction
}

/**
 * One transition function, exhaustive over every (state, event) pair, with no
 * unbounded loop: a round starts at most [maxTries] binds and ends in [Failed].
 * A binder death is not a failure — it returns to [NoBinder] and a later
 * [ShellEvent.BinderReceived] starts a fresh round by itself.
 */
class ShellBinding(
    private val maxTries: Int = MAX_TRIES,
    private val bindTimeoutMs: Long = BIND_TIMEOUT_MS,
    private val backoffMs: (Int) -> Long = ::defaultBackoff,
) {
    var state: ShellState = ShellState.NoBinder
        private set

    fun transition(event: ShellEvent): List<ShellAction> {
        val (next, actions) = when (val from = state) {
            ShellState.NoBinder -> noBinder(event)
            ShellState.NeedsPermission -> needsPermission(event)
            is ShellState.Binding -> binding(from, event)
            is ShellState.WaitingRetry -> waitingRetry(from, event)
            ShellState.Ready -> ready(event)
            is ShellState.Failed -> failed(from, event)
        }
        state = next
        return actions
    }

    private fun noBinder(event: ShellEvent): Pair<ShellState, List<ShellAction>> = when (event) {
        ShellEvent.BinderReceived -> ShellState.NeedsPermission to listOf(ShellAction.CheckPermission)
        // Nothing to do until a binder arrives. Asking to start with none is a
        // failure the person can see, not a silent no-op.
        ShellEvent.RetryRequested ->
            ShellState.Failed(ShellFailure(ShellFailure.BINDER_DEAD)) to
                listOf(ShellAction.ReportFailure(ShellFailure(ShellFailure.BINDER_DEAD)))
        ShellEvent.BinderDead,
        ShellEvent.PermissionGranted,
        ShellEvent.PermissionDenied,
        ShellEvent.BindSucceeded,
        is ShellEvent.BindFailed,
        ShellEvent.BindTimedOut,
        ShellEvent.ServiceDied,
        ShellEvent.RetryTick,
        -> ShellState.NoBinder to emptyList()
    }

    private fun needsPermission(event: ShellEvent): Pair<ShellState, List<ShellAction>> = when (event) {
        ShellEvent.PermissionGranted ->
            ShellState.Binding(1) to listOf(ShellAction.BindService, ShellAction.ArmTimeout(bindTimeoutMs))
        // The person may still allow: the card keeps its Allow action.
        ShellEvent.PermissionDenied -> ShellState.NeedsPermission to emptyList()
        ShellEvent.BinderDead -> ShellState.NoBinder to listOf(ShellAction.CancelTimers)
        // The tap re-checks: the grant may have just landed.
        ShellEvent.RetryRequested -> ShellState.NeedsPermission to listOf(ShellAction.CheckPermission)
        ShellEvent.BinderReceived,
        ShellEvent.BindSucceeded,
        is ShellEvent.BindFailed,
        ShellEvent.BindTimedOut,
        ShellEvent.ServiceDied,
        ShellEvent.RetryTick,
        -> ShellState.NeedsPermission to emptyList()
    }

    private fun binding(
        from: ShellState.Binding,
        event: ShellEvent,
    ): Pair<ShellState, List<ShellAction>> = when (event) {
        ShellEvent.BindSucceeded ->
            ShellState.Ready to listOf(ShellAction.CancelTimers, ShellAction.ReportReady)
        is ShellEvent.BindFailed -> retryOrFail(from.tries, event.failure)
        ShellEvent.BindTimedOut -> retryOrFail(from.tries, ShellFailure(ShellFailure.BIND_TIMEOUT))
        ShellEvent.ServiceDied -> retryOrFail(from.tries, ShellFailure(ShellFailure.SERVICE_DIED))
        // The server went away mid-bind: wait for the next binder instead of
        // spending the rest of the round on a bind that cannot work.
        ShellEvent.BinderDead -> ShellState.NoBinder to listOf(ShellAction.CancelTimers)
        ShellEvent.PermissionDenied -> ShellState.NeedsPermission to listOf(ShellAction.CancelTimers)
        ShellEvent.BinderReceived,
        ShellEvent.PermissionGranted,
        ShellEvent.RetryRequested,
        ShellEvent.RetryTick,
        -> from to emptyList()
    }

    private fun waitingRetry(
        from: ShellState.WaitingRetry,
        event: ShellEvent,
    ): Pair<ShellState, List<ShellAction>> = when (event) {
        ShellEvent.RetryTick ->
            ShellState.Binding(from.tries + 1) to
                listOf(ShellAction.BindService, ShellAction.ArmTimeout(bindTimeoutMs))
        ShellEvent.BinderDead -> ShellState.NoBinder to listOf(ShellAction.CancelTimers)
        ShellEvent.PermissionDenied -> ShellState.NeedsPermission to listOf(ShellAction.CancelTimers)
        // An explicit ask starts a new round with the full budget.
        ShellEvent.RetryRequested ->
            ShellState.Binding(1) to
                listOf(ShellAction.CancelTimers, ShellAction.BindService, ShellAction.ArmTimeout(bindTimeoutMs))
        ShellEvent.BinderReceived,
        ShellEvent.PermissionGranted,
        ShellEvent.BindSucceeded,
        is ShellEvent.BindFailed,
        ShellEvent.BindTimedOut,
        ShellEvent.ServiceDied,
        -> from to emptyList()
    }

    private fun ready(event: ShellEvent): Pair<ShellState, List<ShellAction>> = when (event) {
        // Served, then the service died: one new bounded round, after a
        // backoff so a service that dies on every bind cannot spin.
        ShellEvent.ServiceDied ->
            ShellState.WaitingRetry(0, ShellFailure(ShellFailure.SERVICE_DIED)) to
                listOf(ShellAction.WaitThenRetry(backoffMs(1)))
        ShellEvent.BinderDead -> ShellState.NoBinder to listOf(ShellAction.CancelTimers)
        ShellEvent.BinderReceived,
        ShellEvent.PermissionGranted,
        ShellEvent.PermissionDenied,
        ShellEvent.BindSucceeded,
        is ShellEvent.BindFailed,
        ShellEvent.BindTimedOut,
        ShellEvent.RetryRequested,
        ShellEvent.RetryTick,
        -> ShellState.Ready to emptyList()
    }

    private fun failed(from: ShellState.Failed, event: ShellEvent): Pair<ShellState, List<ShellAction>> = when (event) {
        // The binder coming back is the recovery the person should not have to
        // ask for: re-check and bind without a tap.
        ShellEvent.BinderReceived -> ShellState.NeedsPermission to listOf(ShellAction.CheckPermission)
        ShellEvent.BinderDead -> ShellState.NoBinder to emptyList()
        ShellEvent.RetryRequested ->
            ShellState.Binding(1) to listOf(ShellAction.BindService, ShellAction.ArmTimeout(bindTimeoutMs))
        ShellEvent.PermissionGranted,
        ShellEvent.PermissionDenied,
        ShellEvent.BindSucceeded,
        is ShellEvent.BindFailed,
        ShellEvent.BindTimedOut,
        ShellEvent.ServiceDied,
        ShellEvent.RetryTick,
        -> from to emptyList()
    }

    /** The next try, or the end of this round. */
    private fun retryOrFail(tries: Int, failure: ShellFailure): Pair<ShellState, List<ShellAction>> =
        if (tries < maxTries) {
            ShellState.WaitingRetry(tries, failure) to
                listOf(ShellAction.CancelTimers, ShellAction.WaitThenRetry(backoffMs(tries)))
        } else {
            ShellState.Failed(failure) to
                listOf(ShellAction.CancelTimers, ShellAction.ReportFailure(failure))
        }

    companion object {
        /** Bound of one round: three binds, two waits (1 s, 2 s). */
        const val MAX_TRIES = 3

        /** A bind that has not connected in five seconds is a failed try. */
        const val BIND_TIMEOUT_MS = 5_000L

        fun defaultBackoff(tryNumber: Int): Long =
            minOf(1_000L shl (tryNumber - 1).coerceIn(0, 3), 8_000L)
    }
}
