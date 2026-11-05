package dev.pocketdeck.app

/**
 * The receiver's decision after a reboot or an app update, as one pure state
 * machine (docs/specs/phone-app.md PHONE-7, AGENTS.md, CONV-PD-08).
 *
 * ISS-42, the person's 2026-11-04 update: One UI held `MY_PACKAGE_REPLACED`
 * for 1 s, the receiver ran at 23:49:08, and Shizuku's binder arrived 0.41 s
 * later. The receiver read `pingBinder()` once, found nothing, and returned;
 * nothing else ever started the deck, so the Mac failed TLS until the person
 * tapped the icon six minutes later. A reboot can hit the same order.
 *
 * The machine is told the trigger (boot or update), the person's "keep
 * running" switch and whether the binder was already here. While waiting it
 * accepts the binder whenever it arrives — within the bound so the broadcast's
 * pending result can finish, and after it through the same sticky listener if
 * the process lives, because the person should never have to tap.
 */
enum class StartTrigger(val token: String) {
    Boot("boot"),
    Update("update"),
}

sealed interface StartupState {
    /** Nothing has asked for the deck. */
    data object Idle : StartupState

    /** The broadcast is held open for the binder, [waitedMs] into the bound. */
    data class Waiting(val trigger: StartTrigger, val waitedMs: Long) : StartupState

    /** The deck is starting; this is terminal, so it starts exactly once. */
    data object Starting : StartupState

    /**
     * The bound elapsed and the broadcast finished. A binder that arrives
     * later still starts the deck once while the process lives.
     */
    data class OutOfTime(val trigger: StartTrigger) : StartupState

    /** "Keep running" is off: no reboot or update ever starts the deck. */
    data object Off : StartupState

    fun describe(): String = when (this) {
        Idle -> "Idle"
        is Waiting -> "Waiting(${trigger.token}, ${waitedMs}ms)"
        Starting -> "Starting"
        is OutOfTime -> "OutOfTime(${trigger.token})"
        Off -> "Off"
    }
}

sealed interface StartupEvent {
    /**
     * The receiver ran. [binderReady] is the one read of Shizuku's binder;
     * from then on its arrival is an event.
     */
    data class Received(
        val trigger: StartTrigger,
        val keepRunning: Boolean,
        val binderReady: Boolean,
    ) : StartupEvent

    /** Shizuku's binder arrived (the sticky listener). */
    data object BinderArrived : StartupEvent

    /** The wait's clock reached [ms]. */
    data class Waited(val ms: Long) : StartupEvent

    fun describe(): String = when (this) {
        is Received -> "Received(${trigger.token}, keep=${if (keepRunning) "on" else "off"}, " +
            "binder=${if (binderReady) "here" else "absent"})"
        BinderArrived -> "BinderArrived"
        is Waited -> "Waited($ms)"
    }
}

/** What the receiver does. Side effects never run inside the transition. */
sealed interface StartupAction {
    /** Hold the broadcast open (goAsync) for the binder, within the bound. */
    data object WaitForBinder : StartupAction

    /** Finish the broadcast's pending result. */
    data object FinishBroadcast : StartupAction

    /** Start the deck; the only action that starts it. */
    data object StartDeck : StartupAction
}

/**
 * One transition function, exhaustive over every (state, event) pair. No
 * timeout restarts the wait and no event starts the deck twice.
 */
class DeckStartup(private val boundMs: Long = BOUND_MS) {

    var state: StartupState = StartupState.Idle
        private set

    fun transition(event: StartupEvent): List<StartupAction> {
        val (next, actions) = when (val from = state) {
            StartupState.Idle -> idle(event)
            is StartupState.Waiting -> waiting(from, event)
            StartupState.Starting -> StartupState.Starting to emptyList()
            is StartupState.OutOfTime -> outOfTime(from, event)
            StartupState.Off -> StartupState.Off to emptyList()
        }
        state = next
        return actions
    }

    private fun idle(event: StartupEvent): Pair<StartupState, List<StartupAction>> = when (event) {
        is StartupEvent.Received -> when {
            // The switch is the person's answer: off means not even a running
            // binder starts the deck.
            !event.keepRunning -> StartupState.Off to emptyList()
            event.binderReady ->
                StartupState.Starting to listOf(StartupAction.StartDeck, StartupAction.FinishBroadcast)
            else -> StartupState.Waiting(event.trigger, 0) to listOf(StartupAction.WaitForBinder)
        }
        // A binder with nothing asking for it starts nothing: the deck's
        // caller is the broadcast (or the ready guard in ShizukuClient).
        StartupEvent.BinderArrived,
        is StartupEvent.Waited,
        -> StartupState.Idle to emptyList()
    }

    private fun waiting(
        from: StartupState.Waiting,
        event: StartupEvent,
    ): Pair<StartupState, List<StartupAction>> = when (event) {
        StartupEvent.BinderArrived ->
            StartupState.Starting to listOf(StartupAction.FinishBroadcast, StartupAction.StartDeck)
        is StartupEvent.Waited ->
            if (event.ms >= boundMs) {
                StartupState.OutOfTime(from.trigger) to listOf(StartupAction.FinishBroadcast)
            } else {
                from.copy(waitedMs = event.ms) to emptyList()
            }
        // One broadcast decides; a second one is not a second start.
        is StartupEvent.Received -> from to emptyList()
    }

    private fun outOfTime(
        from: StartupState.OutOfTime,
        event: StartupEvent,
    ): Pair<StartupState, List<StartupAction>> = when (event) {
        // The broadcast had to finish, but the sticky listener is still in
        // this process: the person still gets the deck without a tap.
        StartupEvent.BinderArrived -> StartupState.Starting to listOf(StartupAction.StartDeck)
        is StartupEvent.Received,
        is StartupEvent.Waited,
        -> from to emptyList()
    }

    companion object {
        /**
         * 5 s. The person's binder was 0.41 s late, so several seconds are
         * headroom; a broadcast's goAsync result has about 10 s, and the other
         * half is left for the bind and the start itself.
         */
        const val BOUND_MS = 5_000L
    }
}
