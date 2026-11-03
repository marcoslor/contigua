package dev.pocketdeck.server

/**
 * The one-session slot of a [Server] (docs/specs/pairing.md PAIR-21): free, one
 * Mac live, a live session whose teardown is still running, or handing a stale
 * session over to the Mac that is connecting now.
 *
 * The state carries the sessions themselves, so no second field can drift out
 * of step with it: "who owns the phone" and "which session owns it" are one
 * value. The session type is a type parameter, so [SessionSlot.transition] stays
 * pure and testable with a string in the session's place. The peer fingerprint
 * hex is held for the supersede decision and never logged.
 */
sealed interface SlotState<out S> {
    data object Free : SlotState<Nothing>

    /** [mac] is the live session's peer fingerprint; null before it authenticated. */
    data class Live<out S>(val mac: String?, val session: S) : SlotState<S>

    /**
     * The live session can serve nothing any more; its run is draining (it
     * releases the displays, the panel hold, the streams and the notify and clip
     * gates). A new session must not start until that finishes.
     */
    data class Draining<out S>(val mac: String?, val session: S) : SlotState<S>

    /** A stale [old] session's teardown is running; [newMac] is the Mac waiting for it. */
    data class Handing<out S>(val old: S, val oldMac: String?, val newMac: String) : SlotState<S>
}

/** What happened to the slot. `Connect` is one accepted, TLS-terminated Mac. */
sealed interface SlotEvent {
    /** [samePinnedMac]: this Mac's certificate is the live session's and the phone pins it.
     *  [join]: the hello carried `join`; [joinMatches]: it named the live session's id. */
    data class Connect(
        val peerMac: String,
        val samePinnedMac: Boolean,
        val join: Boolean = false,
        val joinMatches: Boolean = false,
        /** The peer's certificate is one this phone pins (PATH-11). */
        val pinned: Boolean = samePinnedMac,
    ) : SlotEvent

    /** The live session can serve nothing more and is draining. */
    data object Ending : SlotEvent

    /** The draining session's teardown finished inside the bound. */
    data object TeardownDone : SlotEvent

    /** The bound passed with the teardown still running. */
    data object TeardownSlow : SlotEvent

    /** The session's own run ended: its teardown is complete. */
    data object Ended : SlotEvent

    /** The app dropped every session (its data was cleared, a Mac was forgotten). */
    data object Cancelled : SlotEvent
}

/** What the caller does after a transition; nothing is performed inside it. */
enum class SlotAction {
    /** Create the session for the connecting Mac, then record it with [SessionSlot.adopt]. */
    ADOPT,

    /** Hand the old session's close to the dropper's thread. */
    DROP_OLD,

    /** Wait for the old teardown, bounded, before adopting. */
    AWAIT_TEARDOWN,

    /** Attach the connecting socket as one more path of the live session (PATH-3). */
    JOIN,

    /** Answer `no_session`: the live Mac's join named a session this phone does not serve. */
    NO_SESSION,

    /** Answer `busy`: someone else's session still owns the phone. */
    BUSY,

    /** Answer `busy` and say the teardown did not finish in time. */
    BUSY_SLOW,
}

data class SlotStep<S>(val next: SlotState<S>, val actions: List<SlotAction>)

/** The slot's one transition function, exhaustive over states and events. */
object SessionSlot {

    fun <S> transition(state: SlotState<S>, event: SlotEvent): SlotStep<S> = when (state) {
        SlotState.Free -> when (event) {
            // The session does not exist when this decision is made: the caller
            // builds it and reports it through [SessionSlot.adopt]. A join has
            // nothing to attach to (PATH-3).
            is SlotEvent.Connect ->
                when {
                    // A join with nothing to attach to: only a Mac this phone
                    // pins learns that the session is gone (PATH-11).
                    event.join && event.pinned -> SlotStep(SlotState.Free, listOf(SlotAction.NO_SESSION))
                    event.join -> SlotStep(SlotState.Free, listOf(SlotAction.BUSY))
                    else -> SlotStep(SlotState.Free, listOf(SlotAction.ADOPT))
                }
            SlotEvent.Ending, SlotEvent.TeardownDone, SlotEvent.TeardownSlow,
            SlotEvent.Ended, SlotEvent.Cancelled -> SlotStep(SlotState.Free, emptyList())
        }
        is SlotState.Live -> when (event) {
            is SlotEvent.Connect ->
                if (event.join) {
                    when {
                        // A joined path never supersedes: the session stays (PATH-3).
                        event.samePinnedMac && event.joinMatches ->
                            SlotStep(state, listOf(SlotAction.JOIN))
                        // Only the live session's own pinned Mac learns that id is gone.
                        event.samePinnedMac ->
                            SlotStep(state, listOf(SlotAction.NO_SESSION))
                        else -> SlotStep(state, listOf(SlotAction.BUSY))
                    }
                } else if (event.samePinnedMac) {
                    SlotStep(
                        SlotState.Handing(old = state.session, oldMac = state.mac, newMac = event.peerMac),
                        listOf(SlotAction.DROP_OLD, SlotAction.AWAIT_TEARDOWN),
                    )
                } else {
                    SlotStep(state, listOf(SlotAction.BUSY))
                }
            SlotEvent.Ending -> SlotStep(SlotState.Draining(state.mac, state.session), emptyList())
            SlotEvent.Ended, SlotEvent.Cancelled -> SlotStep(SlotState.Free, emptyList())
            SlotEvent.TeardownDone, SlotEvent.TeardownSlow -> SlotStep(state, emptyList())
        }
        is SlotState.Draining -> when (event) {
            // The session is over: a join finds nothing to attach to (PATH-3).
            is SlotEvent.Connect ->
                if (event.join) {
                    if (event.samePinnedMac) SlotStep(state, listOf(SlotAction.NO_SESSION))
                    else SlotStep(state, listOf(SlotAction.BUSY))
                } else {
                    // The slot is free in a moment: whoever is connecting waits
                    // for the teardown instead of hearing busy and backing off.
                    SlotStep(
                        SlotState.Handing(old = state.session, oldMac = state.mac, newMac = event.peerMac),
                        listOf(SlotAction.DROP_OLD, SlotAction.AWAIT_TEARDOWN),
                    )
                }
            SlotEvent.Ended, SlotEvent.Cancelled -> SlotStep(SlotState.Free, emptyList())
            SlotEvent.Ending, SlotEvent.TeardownDone, SlotEvent.TeardownSlow ->
                SlotStep(state, emptyList())
        }
        is SlotState.Handing -> when (event) {
            // One hand-over at a time: a third connection never joins a queue.
            is SlotEvent.Connect -> SlotStep(state, listOf(SlotAction.BUSY))
            // The old session's teardown is over: the waiter adopts on a free
            // slot, so a slow hand-over can never leave it stuck in `handing`.
            SlotEvent.TeardownDone -> SlotStep(SlotState.Free, emptyList())
            SlotEvent.TeardownSlow -> SlotStep(SlotState.Live(state.oldMac, state.old), listOf(SlotAction.BUSY_SLOW))
            SlotEvent.Cancelled -> SlotStep(SlotState.Free, emptyList())
            // Its own end is the latch the waiter is on, not a state change.
            SlotEvent.Ending, SlotEvent.Ended -> SlotStep(state, emptyList())
        }
    }

    /**
     * The session ADOPT asked for is now the slot's live one. Separate from
     * [transition] because the decision to adopt happens before the session
     * exists: [transition] never builds one.
     */
    fun <S> adopt(state: SlotState<S>, mac: String?, session: S): SlotState<S> =
        SlotState.Live(mac, session)

    /** A closed token for the transition log: never a fingerprint, name or address. */
    fun describe(state: SlotState<*>): String = when (state) {
        SlotState.Free -> "free"
        is SlotState.Live -> "live"
        is SlotState.Draining -> "draining"
        is SlotState.Handing -> "handing"
    }

    fun describe(event: SlotEvent): String = when (event) {
        is SlotEvent.Connect -> when {
            event.join && event.joinMatches -> "join(own session)"
            event.join -> "join(other session)"
            event.samePinnedMac -> "connect(same mac)"
            else -> "connect(other mac)"
        }
        SlotEvent.Ending -> "ending"
        SlotEvent.TeardownDone -> "teardown done"
        SlotEvent.TeardownSlow -> "teardown slow"
        SlotEvent.Ended -> "ended"
        SlotEvent.Cancelled -> "cancelled"
    }
}
