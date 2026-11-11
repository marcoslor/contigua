package app.contigua.server

/**
 * One window stream's first frame, as an explicit machine (WIN-66, ISS-10).
 *
 * The 2026-11-05 field report: one window in 18 stayed without a picture for
 * its whole 22 s life. The phone's log of that minute had rotated out, and the
 * only "waiting" signal was a boolean inside `RedrawGuard` — read once, when a
 * frame finally arrived, so a stream that never got one left no trace at all.
 *
 * Here the state is named: a stream is [FirstFrameState.Opened] until its
 * display exists, [FirstFrameState.Waiting] until the first encoded frame or
 * the limit, [FirstFrameState.Flowing] once a frame arrived, and
 * [FirstFrameState.NoFrame] when the limit passed with no frame (one episode is
 * recorded, never a second). A frame or the close after the record ends the
 * same episode with [NoFrameOutcome]. Nothing else about the stream changes.
 *
 * One pure rule, [firstFrameTransition]; the caller performs its actions and
 * [FirstFrameWatch] logs every phase change as
 * `stream <id> firstframe: <from> --<event>--> <to>`.
 */
internal enum class FirstFrameState(val wire: String) {
    /** The stream exists; its display has not been created yet. */
    Opened("opened"),

    /** The display exists and no encoded frame has arrived; the clock runs. */
    Waiting("waiting-first-frame"),

    /** The encoder produced a picture: the stream is live. */
    Flowing("flowing"),

    /** The limit passed with no frame: one episode is recorded. */
    NoFrame("no-frame"),

    /** The stream closed; nothing is ever recorded again. */
    Closed("closed"),
}

internal sealed interface FirstFrameEvent {
    /** The event's token in the `firstframe:` log line. */
    val wire: String

    /** `EncoderAction.CreateDisplay` built the stream's display. */
    data class DisplayCreated(val nowMs: Long) : FirstFrameEvent {
        override val wire: String get() = "display"
    }

    /** An encoded picture buffer came out of the codec. */
    data class Frame(val nowMs: Long) : FirstFrameEvent {
        override val wire: String get() = "frame"
    }

    /** The drain loop's poll: the only event that can record the episode. */
    data class Deadline(val nowMs: Long) : FirstFrameEvent {
        override val wire: String get() = "deadline"
    }

    /** The stream closed (the Mac's `window.close`, the session, the last window). */
    data class Close(val nowMs: Long) : FirstFrameEvent {
        override val wire: String get() = "close"
    }
}

internal sealed interface FirstFrameAction {
    /** Record one episode, [waitedMs] after the display was created. */
    data class RecordNoFrame(val episode: Int, val waitedMs: Long) : FirstFrameAction

    /** The same episode ended: a first frame arrived, or the stream closed first. */
    data class EndNoFrame(
        val episode: Int,
        val outcome: NoFrameOutcome,
        val waitedMs: Long,
    ) : FirstFrameAction
}

internal data class FirstFrameModel(
    val state: FirstFrameState = FirstFrameState.Opened,
    /** The process's id for this stream's one episode. */
    val episode: Int = 0,
    val createdAtMs: Long = 0L,
    /** When the limit expires; 0 until the display exists. */
    val dueMs: Long = 0L,
    /** When the episode was recorded; 0 until then. */
    val recordedAtMs: Long = 0L,
)

internal data class FirstFrameTransition(
    val state: FirstFrameModel,
    val actions: List<FirstFrameAction>,
)

/**
 * The limit: `first_frame_ms` in docs/NFR.md (`macos/scripts/nfr-limits.json`),
 * 1500 ms. Not a new number.
 */
internal const val NO_FRAME_AFTER_MS = 1_500L

/** The one pure rule. Every state accepts every event; an unlisted pair is ignored. */
internal fun firstFrameTransition(
    model: FirstFrameModel,
    event: FirstFrameEvent,
): FirstFrameTransition {
    fun stay(actions: List<FirstFrameAction> = emptyList()) = FirstFrameTransition(model, actions)

    return when (model.state) {
        FirstFrameState.Closed -> stay()

        FirstFrameState.Opened -> when (event) {
            is FirstFrameEvent.DisplayCreated -> FirstFrameTransition(
                model.copy(
                    state = FirstFrameState.Waiting,
                    createdAtMs = event.nowMs,
                    dueMs = event.nowMs + NO_FRAME_AFTER_MS,
                ),
                emptyList(),
            )
            is FirstFrameEvent.Close -> FirstFrameTransition(
                // The stream closed before a display existed: nothing to record.
                model.copy(state = FirstFrameState.Closed),
                emptyList(),
            )
            is FirstFrameEvent.Frame, is FirstFrameEvent.Deadline -> stay()
        }

        FirstFrameState.Waiting -> when (event) {
            is FirstFrameEvent.Frame -> FirstFrameTransition(
                model.copy(state = FirstFrameState.Flowing),
                emptyList(),
            )
            is FirstFrameEvent.Deadline -> if (event.nowMs >= model.dueMs) {
                FirstFrameTransition(
                    model.copy(
                        state = FirstFrameState.NoFrame,
                        recordedAtMs = event.nowMs,
                    ),
                    listOf(
                        FirstFrameAction.RecordNoFrame(
                            episode = model.episode,
                            waitedMs = event.nowMs - model.createdAtMs,
                        ),
                    ),
                )
            } else {
                stay()
            }
            is FirstFrameEvent.Close -> FirstFrameTransition(
                model.copy(state = FirstFrameState.Closed),
                emptyList(),
            )
            is FirstFrameEvent.DisplayCreated -> stay()
        }

        FirstFrameState.Flowing -> when (event) {
            is FirstFrameEvent.Close -> FirstFrameTransition(
                model.copy(state = FirstFrameState.Closed),
                emptyList(),
            )
            is FirstFrameEvent.DisplayCreated, is FirstFrameEvent.Frame,
            is FirstFrameEvent.Deadline -> stay()
        }

        FirstFrameState.NoFrame -> when (event) {
            is FirstFrameEvent.Frame -> FirstFrameTransition(
                model.copy(state = FirstFrameState.Flowing),
                listOf(
                    FirstFrameAction.EndNoFrame(
                        episode = model.episode,
                        outcome = NoFrameOutcome.Late,
                        waitedMs = event.nowMs - model.createdAtMs,
                    ),
                ),
            )
            is FirstFrameEvent.Close -> FirstFrameTransition(
                model.copy(state = FirstFrameState.Closed),
                listOf(
                    FirstFrameAction.EndNoFrame(
                        episode = model.episode,
                        outcome = NoFrameOutcome.Closed,
                        waitedMs = event.nowMs - model.createdAtMs,
                    ),
                ),
            )
            // One episode per stream: a later deadline changes nothing.
            is FirstFrameEvent.DisplayCreated, is FirstFrameEvent.Deadline -> stay()
        }
    }
}

/**
 * The holder a `WindowStream` talks to: one model, one transition, and one log
 * line per phase change. The caller performs the actions.
 */
internal class FirstFrameWatch(
    private val stream: Int,
    private val episode: Int,
    private val log: (String) -> Unit,
) {
    @Volatile
    var model = FirstFrameModel(episode = episode)
        private set

    @Synchronized
    fun dispatch(event: FirstFrameEvent): List<FirstFrameAction> {
        val before = model
        val step = firstFrameTransition(before, event)
        model = step.state
        if (step.state.state != before.state) {
            log("stream $stream firstframe: ${before.state.wire} --${event.wire}--> ${step.state.state.wire}")
        }
        return step.actions
    }
}
