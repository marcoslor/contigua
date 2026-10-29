package dev.pocketdeck.server

/**
 * The one-session slot of a [Server] (docs/specs/pairing.md PAIR-21): free, one
 * Mac live, a live session whose teardown is still running, or handing a stale
 * session over to the Mac that is connecting now. The state is an identity (the
 * peer's TLS fingerprint hex) only — it is never logged, and the sessions
 * themselves stay in [SessionDropper].
 */
sealed interface SlotState {
    data object Free : SlotState

    /** [mac] is the live session's peer fingerprint; null before it authenticated. */
    data class Live(val mac: String?) : SlotState

    /**
     * The live session can serve nothing any more; its run is draining (it
     * releases the displays, the panel hold, the streams and the notify and clip
     * gates). A new session must not start until that finishes.
     */
    data class Draining(val mac: String?) : SlotState

    /** A stale [old] session's teardown is running; [new] is the Mac waiting for it. */
    data class Handing(val old: String?, val new: String) : SlotState
}

/** What happened to the slot. `Connect` is one accepted, TLS-terminated Mac. */
sealed interface SlotEvent {
    /** [samePinnedMac]: this Mac's certificate is the live session's and the phone pins it. */
    data class Connect(val peerMac: String, val samePinnedMac: Boolean) : SlotEvent

    /** The live session can serve nothing more and is draining. */
    data object Ending : SlotEvent

    /** The draining session's teardown finished inside the bound. */
    data object TeardownDone : SlotEvent

    /** The bound passed with the teardown still running. */
    data object TeardownSlow : SlotEvent

    /** The session's own run ended: its teardown is complete. */
    data object Ended : SlotEvent
}

/** What the caller does after a transition; nothing is performed inside it. */
enum class SlotAction {
    /** Create the session for the connecting Mac and make it the live one. */
    ADOPT,

    /** Hand the old session's close to the dropper's thread. */
    DROP_OLD,

    /** Wait for the old teardown, bounded, before adopting. */
    AWAIT_TEARDOWN,

    /** Answer `busy`: someone else's session still owns the phone. */
    BUSY,

    /** Answer `busy` and say the teardown did not finish in time. */
    BUSY_SLOW,
}

data class SlotStep(val next: SlotState, val actions: List<SlotAction>)

/** The slot's one transition function, exhaustive over states and events. */
object SessionSlot {

    fun transition(state: SlotState, event: SlotEvent): SlotStep = when (state) {
        SlotState.Free -> when (event) {
            is SlotEvent.Connect -> SlotStep(SlotState.Live(event.peerMac), listOf(SlotAction.ADOPT))
            SlotEvent.Ending, SlotEvent.TeardownDone, SlotEvent.TeardownSlow, SlotEvent.Ended ->
                SlotStep(SlotState.Free, emptyList())
        }
        is SlotState.Live -> when (event) {
            is SlotEvent.Connect ->
                if (event.samePinnedMac) {
                    SlotStep(
                        SlotState.Handing(old = state.mac, new = event.peerMac),
                        listOf(SlotAction.DROP_OLD, SlotAction.AWAIT_TEARDOWN),
                    )
                } else {
                    SlotStep(state, listOf(SlotAction.BUSY))
                }
            SlotEvent.Ending -> SlotStep(SlotState.Draining(state.mac), emptyList())
            SlotEvent.Ended -> SlotStep(SlotState.Free, emptyList())
            SlotEvent.TeardownDone, SlotEvent.TeardownSlow -> SlotStep(state, emptyList())
        }
        is SlotState.Draining -> when (event) {
            // The slot is free in a moment: whoever is connecting waits for the
            // teardown instead of hearing busy and backing off.
            is SlotEvent.Connect ->
                SlotStep(
                    SlotState.Handing(old = state.mac, new = event.peerMac),
                    listOf(SlotAction.DROP_OLD, SlotAction.AWAIT_TEARDOWN),
                )
            SlotEvent.Ended -> SlotStep(SlotState.Free, emptyList())
            SlotEvent.Ending, SlotEvent.TeardownDone, SlotEvent.TeardownSlow -> SlotStep(state, emptyList())
        }
        is SlotState.Handing -> when (event) {
            // One hand-over at a time: a third connection never joins a queue.
            is SlotEvent.Connect -> SlotStep(state, listOf(SlotAction.BUSY))
            SlotEvent.TeardownDone ->
                SlotStep(SlotState.Live(state.new), listOf(SlotAction.ADOPT))
            SlotEvent.TeardownSlow ->
                SlotStep(SlotState.Live(state.old), listOf(SlotAction.BUSY_SLOW))
            // The old session's end is the latch the waiter is on, not a state change.
            SlotEvent.Ending, SlotEvent.Ended -> SlotStep(state, emptyList())
        }
    }

    /** A closed token for the transition log: never a fingerprint, name or address. */
    fun describe(state: SlotState): String = when (state) {
        SlotState.Free -> "free"
        is SlotState.Live -> "live"
        is SlotState.Draining -> "draining"
        is SlotState.Handing -> "handing"
    }

    fun describe(event: SlotEvent): String = when (event) {
        is SlotEvent.Connect -> if (event.samePinnedMac) "connect(same mac)" else "connect(other mac)"
        SlotEvent.Ending -> "ending"
        SlotEvent.TeardownDone -> "teardown done"
        SlotEvent.TeardownSlow -> "teardown slow"
        SlotEvent.Ended -> "ended"
    }
}
