package app.contigua.server

/**
 * The app-window episode (docs/specs/controls.md CTRL-14, "The app-window
 * episode"): the set of open app displays while at least one is live.
 *
 * A covered window is still a window: while a sibling is live its display keeps
 * its wake lock, so a sibling's open or close never changes it (the 11-01 field
 * log, where closing a covering window released the covered one's display).
 * When every open window is covered, or the last one closes, the episode ends
 * and releases everything. App displays sit in a group of their own (WIN-74),
 * so nothing here is about the phone's own screen. One pure transition, actions
 * performed by [AndroidPower].
 */
internal enum class EpisodePhase {
    /** No live app window: no partial wake, no display locks, no keep-alive. */
    IDLE,

    /** At least one open window is live. */
    LIVE,
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
     * a close) and whether every one of them is covered.
     */
    data class Streams(val displays: Set<Int>, val allPaused: Boolean) : EpisodeEvent
}

internal sealed interface EpisodeAction {
    /** First live display of an episode: partial wake, wake before the launch, the timer. */
    data object Start : EpisodeAction

    /** Nothing live is left: release everything. */
    data object End : EpisodeAction

    /** One stream's display joins the episode and gets its display wake lock. */
    data class Hold(val display: Int) : EpisodeAction

    /** One stream's display leaves; only that display's wake is released. */
    data class Drop(val display: Int) : EpisodeAction
}

/** The pure step: `(state, event) -> (state, actions)`. */
internal fun episodeStep(
    state: EpisodeState,
    event: EpisodeEvent,
): Pair<EpisodeState, List<EpisodeAction>> = when (event) {
    is EpisodeEvent.Streams -> {
        val displays = event.displays
        val live = displays.isNotEmpty() && !event.allPaused
        when {
            !live && state.active ->
                EpisodeState() to (episodeDiff(state.displays, emptySet()) + EpisodeAction.End)
            !live -> state to emptyList()
            !state.active ->
                EpisodeState(EpisodePhase.LIVE, displays) to
                    (listOf(EpisodeAction.Start) + episodeDiff(emptySet(), displays))
            else -> EpisodeState(EpisodePhase.LIVE, displays) to episodeDiff(state.displays, displays)
        }
    }
}

/** A display that went away loses its lock, one that appeared gets it. */
private fun episodeDiff(from: Set<Int>, to: Set<Int>): List<EpisodeAction> =
    from.filterNot { it in to }.map { EpisodeAction.Drop(it) } +
        to.filterNot { it in from }.map { EpisodeAction.Hold(it) }

internal class StreamEpisode(private val log: (String) -> Unit) {

    var state = EpisodeState()
        private set

    /** One event through the machine; the caller performs the returned actions. */
    fun dispatch(event: EpisodeEvent): List<EpisodeAction> {
        val (next, actions) = episodeStep(state, event)
        if (next != state) {
            val name = when (event) {
                is EpisodeEvent.Streams -> if (event.allPaused) "streams-covered" else "streams"
            }
            log("episode: ${state.phase} --$name--> ${next.phase} displays=${next.displays.size}")
        }
        state = next
        return actions
    }
}
