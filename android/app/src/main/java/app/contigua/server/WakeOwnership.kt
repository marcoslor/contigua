package app.contigua.server

/**
 * Who woke the phone's own panel for a streaming episode, and whether the phone
 * is still as Contigua left it (docs/specs/controls.md CTRL-7).
 *
 * Contigua wakes the panel's power group when an episode starts. If the
 * person then unlocks the phone, uses display 0 or wakes it themselves, the
 * phone is theirs: the last stream's close must leave the screen alone instead
 * of sleeping it under their hands. One machine for the whole phone, not per
 * stream, and only a wake that named the panel's own group arms it.
 *
 * Pure: every platform fact arrives as a value, and actions come back rather
 * than being performed.
 */
internal enum class WakeOwner(val wire: String) {
    /** Contigua did not wake the panel's group, or the episode is over. */
    NOT_OURS("notours"),

    /** Our wake lit the panel's group for this episode and nobody took over. */
    OURS_WOKE("ourswoke"),

    /** The person unlocked, used or woke the phone since our wake: it is theirs. */
    PERSON_TOOK_OVER("person"),
}

/** Everything that can move the wake's ownership. */
internal sealed interface WakeEvent {
    /** The event's name for the log: a closed token, never a value. */
    val wire: String

    /** Our wake of the panel's group landed (an episode's take-over or a relight). */
    data class OurWake(val nowMs: Long) : WakeEvent {
        override val wire: String get() = "ourWake"
    }

    /** Display 0 changed its power state (`state.screen`). */
    data class ScreenReported(val on: Boolean, val nowMs: Long) : WakeEvent {
        override val wire: String get() = if (on) "screenOn" else "screenOff"
    }

    /** The keyguard went unlocked (`state.locked` false). */
    data object PersonUnlocked : WakeEvent {
        override val wire: String get() = "unlocked"
    }

    /** The person touched the panel or pressed a key on it (CTRL-11). */
    data object PersonUsed : WakeEvent {
        override val wire: String get() = "used"
    }

    /**
     * The phone went idle by itself while we had its panel: its own screen
     * timeout or lock, with no press of ours in flight. The person is done with
     * it, so Contigua takes the phone back for the streams.
     */
    data object PersonIdle : WakeEvent {
        override val wire: String get() = "idle"
    }

    /** The last stream closed, or the session ended. */
    data object StreamsStopped : WakeEvent {
        override val wire: String get() = "stopped"
    }
}

/** What the caller must run after a close. */
internal enum class WakeAction { SLEEP_PHONE }

/** Why the phone was left awake: a closed set, for the log. */
internal enum class WakeCloseReason(val wire: String) {
    PERSON_UNLOCKED("person_unlocked"),
    PERSON_ACTIVE("person_active"),
}

internal data class WakeState(
    val owner: WakeOwner = WakeOwner.NOT_OURS,
    /** Display 0's last reported power state: only an off -> on edge is a wake. */
    val screenOn: Boolean = false,
    /** Until when a screen-on edge is our own wake landing, not the person's. */
    val ownUntilMs: Long = 0L,
    /** Why the person owns the phone, for the close log. */
    val reason: WakeCloseReason? = null,
)

internal data class WakeStep(
    val state: WakeState,
    val actions: List<WakeAction> = emptyList(),
    /** On a close that leaves the phone alone: the reason to log. */
    val closeReason: WakeCloseReason? = null,
)

/** The own-wake window: a screen-on edge inside it is our own wake landing. */
internal const val WAKE_OWN_SETTLE_MS = 2_000L

/**
 * The one pure rule. Every state accepts every event, including the ones it
 * ignores, and nothing here touches the platform.
 *
 * The person's takeover is never undone by our own wake or a keep-alive poke
 * (that is what left the phone in `person` and then moved it back to
 * `ourswoke` on the next relight). It ends only when the phone goes idle by
 * itself ([WakeEvent.PersonIdle]) or when the streams stop.
 */
internal fun wakeTransition(state: WakeState, event: WakeEvent): WakeStep = when (event) {
    is WakeEvent.OurWake -> when (state.owner) {
        WakeOwner.PERSON_TOOK_OVER ->
            WakeStep(state.copy(ownUntilMs = event.nowMs + WAKE_OWN_SETTLE_MS))
        WakeOwner.NOT_OURS, WakeOwner.OURS_WOKE -> WakeStep(
            state.copy(
                owner = WakeOwner.OURS_WOKE,
                ownUntilMs = event.nowMs + WAKE_OWN_SETTLE_MS,
                reason = null,
            ),
        )
    }

    WakeEvent.PersonUnlocked -> when (state.owner) {
        WakeOwner.NOT_OURS, WakeOwner.PERSON_TOOK_OVER -> WakeStep(state.copy(screenOn = true))
        WakeOwner.OURS_WOKE -> WakeStep(
            state.copy(owner = WakeOwner.PERSON_TOOK_OVER, screenOn = true, reason = WakeCloseReason.PERSON_UNLOCKED),
        )
    }

    WakeEvent.PersonUsed -> when (state.owner) {
        // Nothing of ours to lose: the wake machine only decides a close.
        WakeOwner.NOT_OURS -> WakeStep(state)
        WakeOwner.OURS_WOKE -> WakeStep(
            state.copy(owner = WakeOwner.PERSON_TOOK_OVER, screenOn = true, reason = WakeCloseReason.PERSON_ACTIVE),
        )
        WakeOwner.PERSON_TOOK_OVER -> WakeStep(state.copy(screenOn = true))
    }

    WakeEvent.PersonIdle -> when (state.owner) {
        WakeOwner.PERSON_TOOK_OVER -> WakeStep(WakeState())
        WakeOwner.NOT_OURS, WakeOwner.OURS_WOKE -> WakeStep(state)
    }

    is WakeEvent.ScreenReported -> {
        val next = state.copy(screenOn = event.on)
        val woke = event.on && !state.screenOn
        when {
            // Off, or a repeat of on: only an edge can wake anything.
            !woke -> WakeStep(next)
            // Not our wake, or already the person's: nothing of ours to lose.
            state.owner != WakeOwner.OURS_WOKE -> WakeStep(next)
            // Our own wake's screen-on arriving.
            event.nowMs <= state.ownUntilMs -> WakeStep(next)
            else -> WakeStep(
                next.copy(owner = WakeOwner.PERSON_TOOK_OVER, reason = WakeCloseReason.PERSON_ACTIVE),
            )
        }
    }

    WakeEvent.StreamsStopped -> when (state.owner) {
        WakeOwner.OURS_WOKE -> WakeStep(WakeState(), listOf(WakeAction.SLEEP_PHONE))
        WakeOwner.PERSON_TOOK_OVER ->
            WakeStep(WakeState(), closeReason = state.reason ?: WakeCloseReason.PERSON_ACTIVE)
        WakeOwner.NOT_OURS -> WakeStep(WakeState())
    }
}

/** The live machine: keeps the state, logs every transition, returns the actions. */
internal class WakeOwnershipMachine(private val log: (String) -> Unit = {}) {

    private val lock = Object()
    private var state = WakeState()

    /** The owner now, for the tests and the report's closed token. */
    fun owner(): WakeOwner = synchronized(lock) { state.owner }

    fun dispatch(event: WakeEvent): WakeStep {
        val step = synchronized(lock) {
            val before = state
            val step = wakeTransition(before, event)
            state = step.state
            if (before.owner != step.state.owner || event is WakeEvent.StreamsStopped) {
                log("wake: ${before.owner.wire} --${event.wire}--> ${step.state.owner.wire}")
            }
            step
        }
        return step
    }
}
