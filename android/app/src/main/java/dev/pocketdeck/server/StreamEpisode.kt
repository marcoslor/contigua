package dev.pocketdeck.server

/**
 * The power episode's lifetime: the set of app displays that still have a
 * window open, and whether they are paused (covered on the Mac) or live.
 *
 * The episode used to be "the displays that are not paused right now": a window
 * the Mac covered took its display out of the set, and closing the window that
 * covered it released the partial wake and put the phone back to sleep while the
 * first window was still open (the 11-01 field log: stream 7 closed at 12:30:50,
 * stream 6's display was released, the phone slept, and the resumed stream 6
 * found a panel the platform had just restored, so it was read as the person's).
 *
 * A covered window is still a window: its display keeps its wake lock and the
 * episode keeps running. Only the last close, or the all-paused grace
 * ([DarkPanelPolicy.PAUSE_GRACE_MS]), ends it. One pure transition, actions
 * performed by [AndroidPower] outside this class.
 */
internal enum class EpisodePhase {
    /** No app window: no partial wake, no display locks, no keep-alive. */
    IDLE,

    /** At least one window is open and drawing. */
    LIVE,

    /** Every open window is covered on the Mac; the panel state is kept for the grace. */
    PAUSED,
}

internal data class EpisodeState(
    val phase: EpisodePhase = EpisodePhase.IDLE,
    val displays: Set<Int> = emptySet(),
) {
    val active: Boolean get() = phase != EpisodePhase.IDLE
}

internal sealed interface EpisodeEvent {
    /**
     * The session's open app displays (covered windows included: a pause is not
     * a close) and whether every one of them is paused.
     */
    data class Streams(val displays: Set<Int>, val allPaused: Boolean) : EpisodeEvent

    /** The all-paused grace ran out: hand the phone back. */
    data object GraceExpired : EpisodeEvent
}

internal sealed interface EpisodeAction {
    /** First display of an episode: partial wake, the take-over, the timer. */
    data object Start : EpisodeAction

    /** Nothing of ours is open: release everything and restore the phone. */
    data object End : EpisodeAction

    /** Every window is covered: keep the state, start the grace. */
    data object Pause : EpisodeAction

    /** A window came back inside the grace: the episode goes on as it was. */
    data object Resume : EpisodeAction

    /** One stream's display joins the episode and gets its display wake lock. */
    data class Hold(val display: Int) : EpisodeAction

    /** One stream's display leaves; only that display's wake is released. */
    data class Drop(val display: Int) : EpisodeAction
}

internal class StreamEpisode(private val log: (String) -> Unit) {

    var state = EpisodeState()
        private set

    /** One event through the machine; the caller performs the returned actions. */
    fun dispatch(event: EpisodeEvent): List<EpisodeAction> {
        val (next, actions) = transition(state, event)
        if (next != state) {
            log("episode: ${state.phase} --${eventName(event)}--> ${next.phase} displays=${next.displays.size}")
        }
        state = next
        return actions
    }

    private fun eventName(event: EpisodeEvent): String = when (event) {
        is EpisodeEvent.Streams -> if (event.allPaused) "streams-paused" else "streams"
        EpisodeEvent.GraceExpired -> "grace-expired"
    }

    private companion object {
        fun transition(
            state: EpisodeState,
            event: EpisodeEvent,
        ): Pair<EpisodeState, List<EpisodeAction>> = when (event) {
            is EpisodeEvent.Streams -> onStreams(state, event)
            EpisodeEvent.GraceExpired -> onGraceExpired(state)
        }

        fun onStreams(
            state: EpisodeState,
            event: EpisodeEvent.Streams,
        ): Pair<EpisodeState, List<EpisodeAction>> {
            val displays = event.displays
            if (displays.isEmpty()) {
                return if (state.active) {
                    EpisodeState() to (drop(state.displays, displays) + EpisodeAction.End)
                } else {
                    state to emptyList()
                }
            }
            return when (state.phase) {
                EpisodePhase.IDLE -> if (event.allPaused) {
                    // Every window was covered before the episode began: there
                    // is nothing to take the phone over for, and no wake to
                    // undo a person's screen. The pause grace owns it from here.
                    EpisodeState(EpisodePhase.PAUSED, displays) to
                        (hold(state.displays, displays) + EpisodeAction.Pause)
                } else {
                    EpisodeState(EpisodePhase.LIVE, displays) to
                        (listOf(EpisodeAction.Start) + hold(state.displays, displays))
                }
                EpisodePhase.LIVE -> if (event.allPaused) {
                    EpisodeState(EpisodePhase.PAUSED, displays) to
                        (change(state.displays, displays) + EpisodeAction.Pause)
                } else {
                    EpisodeState(EpisodePhase.LIVE, displays) to change(state.displays, displays)
                }
                EpisodePhase.PAUSED -> if (event.allPaused) {
                    EpisodeState(EpisodePhase.PAUSED, displays) to change(state.displays, displays)
                } else {
                    EpisodeState(EpisodePhase.LIVE, displays) to
                        (change(state.displays, displays) + EpisodeAction.Resume)
                }
            }
        }

        fun onGraceExpired(state: EpisodeState): Pair<EpisodeState, List<EpisodeAction>> =
            if (state.phase == EpisodePhase.PAUSED) {
                EpisodeState() to (state.displays.map { EpisodeAction.Drop(it) } + EpisodeAction.End)
            } else {
                state to emptyList()
            }

        /** A display that appeared gets its lock, one that went away loses it. */
        fun change(from: Set<Int>, to: Set<Int>): List<EpisodeAction> =
            drop(from, to) + hold(from, to)

        fun hold(from: Set<Int>, to: Set<Int>): List<EpisodeAction> =
            to.filterNot { it in from }.map { EpisodeAction.Hold(it) }

        fun drop(from: Set<Int>, to: Set<Int>): List<EpisodeAction> =
            from.filterNot { it in to }.map { EpisodeAction.Drop(it) }
    }
}
