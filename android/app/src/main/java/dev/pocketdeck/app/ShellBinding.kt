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
 * ISS-100 added the slow probe schedule: a round that fails no longer ends the
 * binding, and a connect that lands after its timeout is still a connect.
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

/**
 * The binding's states. [Binding] and [WaitingRetry] carry the bounded tries;
 * every state that can wait carries the slow-ladder step so a round that fails
 * resumes the ladder instead of starting it over.
 */
sealed interface ShellState {
    /**
     * Shizuku's binder is not with this process: nothing can be bound yet.
     * [probeStep] is the slow-ladder step of the last wait (0 before any).
     */
    data class NoBinder(val probeStep: Int = 0) : ShellState

    /** The binder is here but PocketDeck may not use it: the person must allow. */
    data class NeedsPermission(val slowStep: Int = 0) : ShellState

    /** A bind is in flight; [tries] counts the binds started in this round. */
    data class Binding(val tries: Int, val slowStep: Int = 0) : ShellState

    /** A bind failed; waiting out its backoff, then [tries] + 1 will start. */
    data class WaitingRetry(
        val tries: Int,
        val reason: ShellFailure,
        val slowStep: Int = 0,
    ) : ShellState

    /** The shell service is bound and serving. */
    data object Ready : ShellState

    /**
     * Every try of this round failed: the card offers Try again and the slow
     * ladder keeps probing with no tap. [slowStep] is the step the last wait
     * used.
     */
    data class Failed(val reason: ShellFailure, val slowStep: Int = 0) : ShellState

    fun describe(): String = when (this) {
        is NoBinder -> "NoBinder"
        is NeedsPermission -> "NeedsPermission"
        is Binding -> "Binding($tries)"
        is WaitingRetry -> "WaitingRetry($tries, ${reason.describe()})"
        Ready -> "Ready"
        is Failed -> "Failed(${reason.describe()})"
    }
}

/** What the driver tells the machine. */
sealed interface ShellEvent {
    /** The driver started listening for the binder (a fresh process or attach). */
    data object Started : ShellEvent
    data object BinderReceived : ShellEvent
    data object BinderDead : ShellEvent

    /** The driver's binder probe found no live binder. */
    data object BinderAbsent : ShellEvent
    data object PermissionGranted : ShellEvent
    data object PermissionDenied : ShellEvent
    data object BindSucceeded : ShellEvent
    data class BindFailed(val failure: ShellFailure) : ShellEvent
    data object BindTimedOut : ShellEvent
    data object ServiceDied : ShellEvent

    /** The person tapped Try again, or a caller asked for the service now. */
    data object RetryRequested : ShellEvent

    /** The person tapped Try again while the binder answers but binds do not. */
    data object RestartRequested : ShellEvent

    /** The backoff or the slow-ladder wait elapsed. */
    data object RetryTick : ShellEvent

    val name: String
        get() = when (this) {
            Started -> "Started"
            BinderReceived -> "BinderReceived"
            BinderDead -> "BinderDead"
            BinderAbsent -> "BinderAbsent"
            PermissionGranted -> "PermissionGranted"
            PermissionDenied -> "PermissionDenied"
            BindSucceeded -> "BindSucceeded"
            is BindFailed -> "BindFailed"
            BindTimedOut -> "BindTimedOut"
            ServiceDied -> "ServiceDied"
            RetryRequested -> "RetryRequested"
            RestartRequested -> "RestartRequested"
            RetryTick -> "RetryTick"
        }

    /** The closed failure token this event carries, if it is a failure. */
    val reason: String?
        get() = when (this) {
            BinderDead -> ShellFailure.BINDER_DEAD
            BinderAbsent -> ShellFailure.BINDER_DEAD
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

    /** Re-ask for the binder: a ping, a sticky listener re-add, then an event. */
    data object ProbeBinder : ShellAction

    /** Wait out a backoff, then send [ShellEvent.RetryTick]. */
    data class WaitThenRetry(val ms: Long) : ShellAction

    /** The shell service is bound: the foreground service starts its server. */
    data object ReportReady : ShellAction

    /** The round is over: the card shows Couldn't start with Try again. */
    data class ReportFailure(val failure: ShellFailure) : ShellAction

    /**
     * Restart PocketDeck's own process so Shizuku's server pushes a binder to a
     * new pid (PHONE-23). [bounded] is the automatic probe path: one restart
     * per lost-binder episode, remembered across the restart. A person's tap is
     * unbounded but never loops by itself.
     */
    data class RestartSelf(val reason: ShellFailure, val bounded: Boolean) : ShellAction
}

/**
 * One transition function, exhaustive over every (state, event) pair, with no
 * unbounded fast loop: a round starts at most [maxTries] binds and ends in
 * [Failed]; from there the slow ladder ([slowDelay]) probes forever, and the
 * 60 s step restarts our own process once for a lost binder.
 */
class ShellBinding(
    private val maxTries: Int = MAX_TRIES,
    private val bindTimeoutMs: Long = BIND_TIMEOUT_MS,
    private val backoffMs: (Int) -> Long = ::defaultBackoff,
) {
    var state: ShellState = ShellState.NoBinder()
        private set

    fun transition(event: ShellEvent): List<ShellAction> {
        val (next, actions) = when (val from = state) {
            is ShellState.NoBinder -> noBinder(from, event)
            is ShellState.NeedsPermission -> needsPermission(from, event)
            is ShellState.Binding -> binding(from, event)
            is ShellState.WaitingRetry -> waitingRetry(from, event)
            ShellState.Ready -> ready(event)
            is ShellState.Failed -> failed(from, event)
        }
        state = next
        return actions
    }

    private fun noBinder(
        from: ShellState.NoBinder,
        event: ShellEvent,
    ): Pair<ShellState, List<ShellAction>> = when (event) {
        // A fresh process (or a re-attach) asks for the binder at once: the
        // sticky listener only replays a binder Shizuku already pushed.
        ShellEvent.Started -> from to listOf(ShellAction.ProbeBinder)
        ShellEvent.BinderReceived -> ShellState.NeedsPermission() to listOf(ShellAction.CheckPermission)
        // Losing the binder again is the same state; ask now, then wait.
        ShellEvent.BinderDead ->
            ShellState.NoBinder() to listOf(ShellAction.CancelTimers, ShellAction.ProbeBinder)
        ShellEvent.BinderAbsent ->
            ShellState.NoBinder(from.probeStep + 1) to
                listOf(ShellAction.WaitThenRetry(slowDelay(from.probeStep + 1)))
        ShellEvent.RetryTick ->
            if (from.probeStep == RESTART_STEP - 1) {
                // The ladder reached a minute with no binder: a new pid is the
                // one thing that makes a surviving server push (PHONE-23).
                ShellState.NoBinder(RESTART_STEP) to
                    listOf(
                        ShellAction.RestartSelf(ShellFailure(ShellFailure.BINDER_DEAD), bounded = true),
                        ShellAction.WaitThenRetry(slowDelay(RESTART_STEP)),
                    )
            } else {
                from to listOf(ShellAction.ProbeBinder)
            }
        // Nothing to do until a binder arrives. Asking to start with none is a
        // failure the person can see and the ladder keeps probing behind it.
        ShellEvent.RetryRequested ->
            ShellState.Failed(ShellFailure(ShellFailure.BINDER_DEAD)) to
                listOf(
                    ShellAction.CancelTimers,
                    ShellAction.ReportFailure(ShellFailure(ShellFailure.BINDER_DEAD)),
                    ShellAction.WaitThenRetry(slowDelay(1)),
                )
        ShellEvent.PermissionGranted,
        ShellEvent.PermissionDenied,
        ShellEvent.BindSucceeded,
        is ShellEvent.BindFailed,
        ShellEvent.BindTimedOut,
        ShellEvent.ServiceDied,
        ShellEvent.RestartRequested,
        -> from to emptyList()
    }

    private fun needsPermission(
        from: ShellState.NeedsPermission,
        event: ShellEvent,
    ): Pair<ShellState, List<ShellAction>> = when (event) {
        ShellEvent.PermissionGranted ->
            ShellState.Binding(1, from.slowStep) to
                listOf(ShellAction.BindService, ShellAction.ArmTimeout(bindTimeoutMs))
        // The person may still allow: the card keeps its Allow action.
        ShellEvent.PermissionDenied -> from to emptyList()
        ShellEvent.BinderDead ->
            ShellState.NoBinder() to listOf(ShellAction.CancelTimers, ShellAction.ProbeBinder)
        // The tap re-checks: the grant may have just landed.
        ShellEvent.RetryRequested -> from to listOf(ShellAction.CheckPermission)
        ShellEvent.Started,
        ShellEvent.BinderReceived,
        ShellEvent.BinderAbsent,
        ShellEvent.BindSucceeded,
        is ShellEvent.BindFailed,
        ShellEvent.BindTimedOut,
        ShellEvent.ServiceDied,
        ShellEvent.RestartRequested,
        ShellEvent.RetryTick,
        -> from to emptyList()
    }

    private fun binding(
        from: ShellState.Binding,
        event: ShellEvent,
    ): Pair<ShellState, List<ShellAction>> = when (event) {
        ShellEvent.BindSucceeded ->
            ShellState.Ready to listOf(ShellAction.CancelTimers, ShellAction.ReportReady)
        is ShellEvent.BindFailed -> retryOrFail(from.tries, from.slowStep, event.failure)
        ShellEvent.BindTimedOut ->
            retryOrFail(from.tries, from.slowStep, ShellFailure(ShellFailure.BIND_TIMEOUT))
        ShellEvent.ServiceDied ->
            retryOrFail(from.tries, from.slowStep, ShellFailure(ShellFailure.SERVICE_DIED))
        // The server went away mid-bind: wait for the next binder instead of
        // spending the rest of the round on a bind that cannot work.
        ShellEvent.BinderDead ->
            ShellState.NoBinder() to listOf(ShellAction.CancelTimers, ShellAction.ProbeBinder)
        ShellEvent.PermissionDenied ->
            ShellState.NeedsPermission(from.slowStep) to listOf(ShellAction.CancelTimers)
        ShellEvent.Started,
        ShellEvent.BinderReceived,
        ShellEvent.BinderAbsent,
        ShellEvent.PermissionGranted,
        ShellEvent.RetryRequested,
        ShellEvent.RestartRequested,
        ShellEvent.RetryTick,
        -> from to emptyList()
    }

    private fun waitingRetry(
        from: ShellState.WaitingRetry,
        event: ShellEvent,
    ): Pair<ShellState, List<ShellAction>> = when (event) {
        ShellEvent.RetryTick ->
            ShellState.Binding(from.tries + 1, from.slowStep) to
                listOf(ShellAction.BindService, ShellAction.ArmTimeout(bindTimeoutMs))
        // ISS-100: the connect that lost the race with the timeout is still the
        // service; dropping it was what restarted the slow cold start.
        ShellEvent.BindSucceeded ->
            ShellState.Ready to listOf(ShellAction.CancelTimers, ShellAction.ReportReady)
        ShellEvent.BinderDead ->
            ShellState.NoBinder() to listOf(ShellAction.CancelTimers, ShellAction.ProbeBinder)
        ShellEvent.PermissionDenied ->
            ShellState.NeedsPermission(from.slowStep) to listOf(ShellAction.CancelTimers)
        // An explicit ask starts a new round with the full budget.
        ShellEvent.RetryRequested ->
            ShellState.Binding(1, from.slowStep) to
                listOf(ShellAction.CancelTimers, ShellAction.BindService, ShellAction.ArmTimeout(bindTimeoutMs))
        ShellEvent.Started,
        ShellEvent.BinderReceived,
        ShellEvent.BinderAbsent,
        ShellEvent.PermissionGranted,
        is ShellEvent.BindFailed,
        ShellEvent.BindTimedOut,
        ShellEvent.ServiceDied,
        ShellEvent.RestartRequested,
        -> from to emptyList()
    }

    private fun ready(event: ShellEvent): Pair<ShellState, List<ShellAction>> = when (event) {
        // Served, then the service died: one new bounded round, after a
        // backoff so a service that dies on every bind cannot spin.
        ShellEvent.ServiceDied ->
            ShellState.WaitingRetry(0, ShellFailure(ShellFailure.SERVICE_DIED)) to
                listOf(ShellAction.WaitThenRetry(backoffMs(1)))
        ShellEvent.BinderDead ->
            ShellState.NoBinder() to listOf(ShellAction.CancelTimers, ShellAction.ProbeBinder)
        ShellEvent.Started,
        ShellEvent.BinderReceived,
        ShellEvent.BinderAbsent,
        ShellEvent.PermissionGranted,
        ShellEvent.PermissionDenied,
        ShellEvent.BindSucceeded,
        is ShellEvent.BindFailed,
        ShellEvent.BindTimedOut,
        ShellEvent.RetryRequested,
        ShellEvent.RestartRequested,
        ShellEvent.RetryTick,
        -> ShellState.Ready to emptyList()
    }

    private fun failed(
        from: ShellState.Failed,
        event: ShellEvent,
    ): Pair<ShellState, List<ShellAction>> = when (event) {
        // No tap: probe for a binder on the slow ladder, then start the next
        // round if one answers.
        ShellEvent.RetryTick -> from to listOf(ShellAction.ProbeBinder)
        ShellEvent.BinderAbsent ->
            ShellState.Failed(from.reason, from.slowStep + 1) to
                listOf(ShellAction.WaitThenRetry(slowDelay(from.slowStep + 1)))
        // The binder coming back is the recovery the person should not have to
        // ask for: re-check and bind without a tap.
        ShellEvent.BinderReceived ->
            ShellState.NeedsPermission(from.slowStep) to listOf(ShellAction.CheckPermission)
        // ISS-100: the service that finally started after the round gave up is
        // the same service; accept it.
        ShellEvent.BindSucceeded ->
            ShellState.Ready to listOf(ShellAction.CancelTimers, ShellAction.ReportReady)
        ShellEvent.BinderDead ->
            ShellState.NoBinder() to listOf(ShellAction.CancelTimers, ShellAction.ProbeBinder)
        ShellEvent.RetryRequested ->
            ShellState.Binding(1, from.slowStep) to
                listOf(ShellAction.CancelTimers, ShellAction.BindService, ShellAction.ArmTimeout(bindTimeoutMs))
        // A tap is consent to restart PocketDeck's own process now (PHONE-23);
        // the ladder stays at its last step so nothing loops by itself.
        ShellEvent.RestartRequested ->
            ShellState.Failed(from.reason, RESTART_STEP) to
                listOf(
                    ShellAction.RestartSelf(from.reason, bounded = false),
                    ShellAction.WaitThenRetry(slowDelay(RESTART_STEP)),
                )
        ShellEvent.Started,
        ShellEvent.PermissionGranted,
        ShellEvent.PermissionDenied,
        is ShellEvent.BindFailed,
        ShellEvent.BindTimedOut,
        ShellEvent.ServiceDied,
        -> from to emptyList()
    }

    /** The next try, or the end of this round and the next slow wait. */
    private fun retryOrFail(
        tries: Int,
        slowStep: Int,
        failure: ShellFailure,
    ): Pair<ShellState, List<ShellAction>> =
        if (tries < maxTries) {
            ShellState.WaitingRetry(tries, failure, slowStep) to
                listOf(ShellAction.CancelTimers, ShellAction.WaitThenRetry(backoffMs(tries)))
        } else {
            ShellState.Failed(failure, slowStep + 1) to
                listOf(
                    ShellAction.CancelTimers,
                    ShellAction.ReportFailure(failure),
                    ShellAction.WaitThenRetry(slowDelay(slowStep + 1)),
                )
        }

    companion object {
        /** Bound of one round: three binds, two waits (1 s, 2 s). */
        const val MAX_TRIES = 3

        /** A bind that has not connected in five seconds is a failed try. */
        const val BIND_TIMEOUT_MS = 5_000L

        /**
         * The slow ladder after a round failed or the binder went away: 10 s,
         * 30 s, 60 s, then every 60 s. Never a fast loop (ISS-100).
         */
        val SLOW_RETRY_MS = longArrayOf(10_000L, 30_000L, 60_000L)

        /** The step whose tick restarts our own process once (PHONE-23). */
        const val RESTART_STEP = 3

        fun slowDelay(step: Int): Long = SLOW_RETRY_MS[(step - 1).coerceIn(0, SLOW_RETRY_MS.size - 1)]

        fun defaultBackoff(tryNumber: Int): Long =
            minOf(1_000L shl (tryNumber - 1).coerceIn(0, 3), 8_000L)
    }
}
