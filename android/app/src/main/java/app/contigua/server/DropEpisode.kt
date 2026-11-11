package app.contigua.server

/**
 * One stream's drop episode: the queue discards deltas from the first overflow
 * until the key frame that clears the episode. The count and the clock are the
 * episode's, not a 2 s snapshot's, because a key frame can take seconds.
 */
internal enum class DropPhase(val wire: String) {
    Flowing("flowing"),
    WaitingForKey("waiting"),
}

internal sealed interface DropEvent {
    /** [count] deltas were discarded by one overflow step. */
    data class DeltasDropped(val count: Int, val nowMs: Long) : DropEvent

    /** The first key frame after the drop was handed to the socket. */
    data class KeySent(val nowMs: Long, val nalTypes: List<Int>) : DropEvent
}

internal data class DropEpisode(
    val phase: DropPhase = DropPhase.Flowing,
    val dropped: Int = 0,
    /** When this episode's first delta was discarded. */
    val startedMs: Long = 0,
)

/** The new episode and, when a key frame closed it, the one field log line. */
internal data class DropStep(
    val episode: DropEpisode,
    val line: String? = null,
    val transition: Boolean = false,
)

internal fun dropEpisodeTransition(
    stream: Int,
    episode: DropEpisode,
    event: DropEvent,
): DropStep = when (event) {
    is DropEvent.DeltasDropped -> when (episode.phase) {
        DropPhase.Flowing -> DropStep(
            episode.copy(phase = DropPhase.WaitingForKey,
                         dropped = event.count,
                         startedMs = event.nowMs),
            transition = true,
        )
        DropPhase.WaitingForKey -> DropStep(
            episode.copy(dropped = episode.dropped + event.count),
        )
    }
    is DropEvent.KeySent -> when (episode.phase) {
        DropPhase.Flowing -> DropStep(episode)
        DropPhase.WaitingForKey -> DropStep(
            DropEpisode(),
            line = "stream $stream drop: ${episode.dropped} dropped, " +
                "key after ${(event.nowMs - episode.startedMs).coerceAtLeast(0)} ms, " +
                "nal=${event.nalTypes.joinToString(",")}",
            transition = true,
        )
    }
}
