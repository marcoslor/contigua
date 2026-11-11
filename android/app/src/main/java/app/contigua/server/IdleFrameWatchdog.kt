package app.contigua.server

/**
 * The picture heartbeat a live stream owes the Mac: no quiet second while the
 * stream is live.
 *
 * Some vendor encoders stop honouring `KEY_REPEAT_PREVIOUS_FRAME_AFTER` on a
 * still screen: the field phone's codec left its running state after ~15 s of
 * stillness and sent nothing, so the Mac's WIN-17 called a healthy window "Not
 * responding" at 1.5 s. A sync-frame request cannot fix that: the encoder
 * applies it to its next input frame and a static surface submits none.
 *
 * So after [IDLE_MS] without an encoder output buffer this machine tells the
 * Mac the stream is alive with `{"t":"window.still","stream":N}`, and says it
 * again once a second while the silence lasts. The message goes out from the
 * stream's own drain loop, so it proves that loop and the session are alive; it
 * is based on encoder output, never on sent frames, so a backlogged socket
 * produces none.
 *
 * A paused or covered stream sends nothing on purpose (the Mac's occlusion rule
 * sends `window.pause`), so it is idle here; a closed one stops for good. A
 * stuck encoder or a stuck drain loop produces neither frames nor `still`, and
 * the Mac's rule then fires as it should.
 *
 * One machine: [IdleFrameWatchdogState] plus the pure
 * [idleFrameWatchdogTransition]. Timestamps come from the caller (the drain
 * thread's clock), so a JVM test can drive a fake drain without MediaCodec.
 */
internal enum class IdleFrameWatchdogState {
    /** Nothing to watch: before the first attach, or paused/covered. */
    Idle,

    /** Live, and a frame arrived less than [IDLE_MS] ago. */
    Armed,

    /** Live and silent: the stream is telling the Mac it is still there. */
    Still,

    /** The stream closed: nothing is ever sent again. */
    Closed,
    ;

    /** The token in the `heartbeat: <from> --<event>--> <to>` log line. */
    val wire: String get() = name.lowercase()
}

internal sealed interface IdleFrameWatchdogEvent {
    /** The event's token in the transition log. */
    val wire: String

    /** An encoder was attached for a live stream. */
    data class Live(val nowMs: Long) : IdleFrameWatchdogEvent {
        override val wire: String get() = "live"
    }

    /** The encoder produced a picture buffer; [keyframe] is its own flag. */
    data class Frame(val nowMs: Long, val keyframe: Boolean) : IdleFrameWatchdogEvent {
        override val wire: String get() = "frame"
    }

    /** The drain loop's poll. The only event that can send a `still`. */
    data class Tick(val nowMs: Long) : IdleFrameWatchdogEvent {
        override val wire: String get() = "tick"
    }

    /** The stream paused, or the Mac covered it (`window.pause`). */
    data object Pause : IdleFrameWatchdogEvent {
        override val wire: String get() = "pause"
    }

    data class Resume(val nowMs: Long) : IdleFrameWatchdogEvent {
        override val wire: String get() = "resume"
    }

    data object Close : IdleFrameWatchdogEvent {
        override val wire: String get() = "close"
    }
}

internal sealed interface IdleFrameWatchdogAction {
    /** Send `{"t":"window.still","stream":N}` on the session. */
    data object SendStill : IdleFrameWatchdogAction
}

internal data class IdleFrameWatchdogModel(
    val state: IdleFrameWatchdogState = IdleFrameWatchdogState.Idle,
    /** When the silence has lasted long enough to send a `still` again. */
    val dueMs: Long = 0L,
    /** `still` messages sent while the encoder stayed silent. */
    val stills: Int = 0,
)

internal data class IdleFrameWatchdogTransition(
    val model: IdleFrameWatchdogModel,
    val actions: List<IdleFrameWatchdogAction>,
)

/** How long a live stream may stay silent before it says it is still. */
internal const val IDLE_MS = 1_000L

/**
 * The one pure rule. Every state accepts every event, including the ones it
 * ignores, and nothing here touches the session: the caller performs the
 * actions.
 */
internal fun idleFrameWatchdogTransition(
    model: IdleFrameWatchdogModel,
    event: IdleFrameWatchdogEvent,
): IdleFrameWatchdogTransition {
    fun ignored() = IdleFrameWatchdogTransition(model, emptyList())

    fun arm(nowMs: Long) = IdleFrameWatchdogTransition(
        model.copy(state = IdleFrameWatchdogState.Armed, dueMs = nowMs + IDLE_MS),
        emptyList(),
    )

    fun sayStill(nowMs: Long) = IdleFrameWatchdogTransition(
        model.copy(
            state = IdleFrameWatchdogState.Still,
            dueMs = nowMs + IDLE_MS,
            stills = model.stills + 1,
        ),
        listOf(IdleFrameWatchdogAction.SendStill),
    )

    return when (model.state) {
        IdleFrameWatchdogState.Closed -> ignored()

        IdleFrameWatchdogState.Idle -> when (event) {
            is IdleFrameWatchdogEvent.Live -> arm(event.nowMs)
            is IdleFrameWatchdogEvent.Resume -> arm(event.nowMs)
            else -> ignored()
        }

        IdleFrameWatchdogState.Armed -> when (event) {
            is IdleFrameWatchdogEvent.Frame -> arm(event.nowMs)
            is IdleFrameWatchdogEvent.Tick ->
                if (event.nowMs >= model.dueMs) sayStill(event.nowMs) else ignored()
            IdleFrameWatchdogEvent.Pause -> IdleFrameWatchdogTransition(model.copy(state = IdleFrameWatchdogState.Idle), emptyList())
            is IdleFrameWatchdogEvent.Resume -> arm(event.nowMs)
            IdleFrameWatchdogEvent.Close -> IdleFrameWatchdogTransition(model.copy(state = IdleFrameWatchdogState.Closed), emptyList())
            is IdleFrameWatchdogEvent.Live -> ignored()
        }

        IdleFrameWatchdogState.Still -> when (event) {
            is IdleFrameWatchdogEvent.Frame -> arm(event.nowMs)
            is IdleFrameWatchdogEvent.Tick ->
                if (event.nowMs >= model.dueMs) sayStill(event.nowMs) else ignored()
            IdleFrameWatchdogEvent.Pause -> IdleFrameWatchdogTransition(model.copy(state = IdleFrameWatchdogState.Idle), emptyList())
            is IdleFrameWatchdogEvent.Resume -> arm(event.nowMs)
            IdleFrameWatchdogEvent.Close -> IdleFrameWatchdogTransition(model.copy(state = IdleFrameWatchdogState.Closed), emptyList())
            is IdleFrameWatchdogEvent.Live -> ignored()
        }
    }
}
