package dev.pocketdeck.server

/**
 * The shell service's copy of what the app process vouches for: the phone's TLS
 * identity and the Macs it trusts (docs/design/e2ee.md §10). The app owns both;
 * the shell only holds them while the app is alive, because a shell-UID service
 * outlives an app whose data was cleared (the confirmed bug: the Mac kept its
 * session after Settings ▸ Apps ▸ Clear data).
 *
 * One state machine, one pure transition function. States are "the app has not
 * vouched" (nothing may be served) and "the app vouched for exactly this".
 * A push that matches the current identity and paired set keeps everything; a
 * push that differs, a push with no identity, or the app's binder dying drops
 * the live session and replaces the cached pairing state.
 */
object AppLink {

    /** What the app last vouched for. */
    sealed interface State {
        /**
         * No live app: no identity, no trusted Macs, nothing served. The TCP
         * socket may stay bound; every connection is refused before TLS.
         */
        data object Unlinked : State

        /** The app's current identity and paired Macs. */
        data class Linked(
            /** SHA-256 of the identity's 65-byte point (64 lowercase hex). */
            val identityFp: String,
            val certPem: String,
            val keyP8: String,
            val pairs: List<PairedClient>,
        ) : State
    }

    /** What the host does after a transition; the machine performs no side effects. */
    enum class Action {
        /** Close the live session at once (a new one needs a fresh app push). */
        DROP_SESSIONS,

        /** Drop the cached TLS material built from the old identity. */
        FORGET_CACHE,
    }

    sealed interface Event {
        /**
         * `setPairedClients`: the app's identity fingerprint and paired set, on
         * every bind and every change. An empty [identityFp] means the app has
         * no identity (generation failed): the same as it being gone.
         */
        data class AppPushed(
            val identityFp: String,
            val certPem: String,
            val keyP8: String,
            val pairs: List<PairedClient>,
        ) : Event

        /** The app process died (clear data, uninstall, a kill): its binder died. */
        data object AppGone : Event

        /** This phone completed a pairing; the app stores it and pushes back next. */
        data class PhonePaired(val client: PairedClient) : Event
    }

    data class Transition(val state: State, val actions: List<Action>)

    /** The pure transition: (state, event) -> (state, actions). */
    fun transition(state: State, event: Event): Transition = when (event) {
        is Event.AppPushed -> {
            val noIdentity = event.identityFp.isEmpty() || event.certPem.isEmpty() || event.keyP8.isEmpty()
            if (noIdentity) {
                gone(state)
            } else when (state) {
                State.Unlinked -> Transition(linked(event), emptyList())
                is State.Linked -> if (state.sameVouch(event)) {
                    Transition(linked(event), emptyList())
                } else {
                    Transition(linked(event), listOf(Action.DROP_SESSIONS, Action.FORGET_CACHE))
                }
            }
        }

        Event.AppGone -> gone(state)

        is Event.PhonePaired -> when (state) {
            State.Unlinked -> Transition(state, emptyList())
            is State.Linked -> {
                val pairs = if (state.pairs.any { it.clientId == event.client.clientId }) {
                    state.pairs.map { if (it.clientId == event.client.clientId) event.client else it }
                } else {
                    state.pairs + event.client
                }
                Transition(state.copy(pairs = pairs), emptyList())
            }
        }
    }

    private fun gone(state: State): Transition = when (state) {
        State.Unlinked -> Transition(state, emptyList())
        is State.Linked -> Transition(State.Unlinked, listOf(Action.DROP_SESSIONS, Action.FORGET_CACHE))
    }

    private fun linked(event: Event.AppPushed): State.Linked = State.Linked(
        identityFp = event.identityFp.lowercase(),
        certPem = event.certPem,
        keyP8 = event.keyP8,
        pairs = event.pairs,
    )

    /**
     * The same identity and the same set of pins. Names and order are display
     * data: a renamed Mac or a reordered list is not a new trust decision.
     */
    private fun State.Linked.sameVouch(event: Event.AppPushed): Boolean =
        identityFp == event.identityFp.lowercase() &&
            pairs.map { it.clientId to it.macFpHex }.toSet() ==
            event.pairs.map { it.clientId to it.macFpHex }.toSet()

    /** A log/`status` name for a state; never includes key material. */
    fun describe(state: State): String = when (state) {
        State.Unlinked -> "unlinked"
        is State.Linked -> "linked(fp=${state.identityFp.take(8)} pairs=${state.pairs.size})"
    }

    fun describe(event: Event): String = when (event) {
        is Event.AppPushed -> "push(fp=${event.identityFp.take(8)} pairs=${event.pairs.size})"
        Event.AppGone -> "app-gone"
        is Event.PhonePaired -> "paired(${event.client.clientId})"
    }
}
