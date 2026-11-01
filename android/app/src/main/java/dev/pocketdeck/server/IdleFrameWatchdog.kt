package dev.pocketdeck.server

/**
 * The picture heartbeat a live stream owes the Mac: no quiet second while the
 * stream is live.
 *
 * Some vendor encoders stop honouring `KEY_REPEAT_PREVIOUS_FRAME_AFTER` on a
 * still screen: the field phone's codec left its running state after ~15 s of
 * stillness and sent nothing, so the Mac's WIN-17 called a healthy window "Not
 * responding" at 1.5 s. After [IDLE_MS] without an output buffer this machine
 * asks the encoder for a sync frame through the existing
 * `PARAMETER_KEY_REQUEST_SYNC_FRAME` call, and asks again once a second while
 * the silence lasts, so a still screen keeps producing frames.
 *
 * A paused or covered stream sends nothing on purpose (the Mac's occlusion rule
 * sends `window.pause`), so it is idle here; a closed one stops for good. A
 * genuinely stuck encoder produces nothing even for a sync request, and the
 * Mac's rule then fires as it should.
 *
 * One machine: [IdleFrameWatchdogState] plus the pure
 * [idleFrameWatchdogTransition]. Timestamps come from the caller (the drain
 * thread's clock), so a JVM test can drive a fake codec without MediaCodec.
 */
internal enum class IdleFrameWatchdogState {
    /** Nothing to watch: before the first attach, or paused/covered. */
    Idle,

    /** Live, and a frame arrived less than [IDLE_MS] ago. */
    Armed,

    /** Live, a sync frame was asked for, and nothing has arrived since. */
    Requested,

    /** The stream closed: nothing is ever asked for again. */
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

    /** The drain loop's poll. The only event that can ask for a frame. */
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
    /** `setParameters(PARAMETER_KEY_REQUEST_SYNC_FRAME)`. */
    data object RequestSyncFrame : IdleFrameWatchdogAction
}

internal data class IdleFrameWatchdogModel(
    val state: IdleFrameWatchdogState = IdleFrameWatchdogState.Idle,
    /** When the silence has lasted long enough to ask (or ask again). */
    val dueMs: Long = 0L,
    /** Sync frames asked for while the encoder stayed silent. */
    val requests: Int = 0,
    /** Keyframes that answered a request: the idle-screen cost, a fact. */
    val idleFrames: Int = 0,
)

internal data class IdleFrameWatchdogTransition(
    val model: IdleFrameWatchdogModel,
    val actions: List<IdleFrameWatchdogAction>,
)

/** How long a live stream may stay silent before it asks for a frame. */
internal const val IDLE_MS = 1_000L

/**
 * The one pure rule. Every state accepts every event, including the ones it
 * ignores, and nothing here touches the encoder: the caller performs the
 * actions. A frame in [IdleFrameWatchdogState.Requested] is counted as an idle
 * keyframe, which is how the emulator proof reads the cost of a still screen.
 */
internal fun idleFrameWatchdogTransition(
    model: IdleFrameWatchdogModel,
    event: IdleFrameWatchdogEvent,
): IdleFrameWatchdogTransition {
    fun ignored() = IdleFrameWatchdogTransition(model, emptyList())

    fun arm(nowMs: Long, idleFrame: Boolean = false) = IdleFrameWatchdogTransition(
        model.copy(
            state = IdleFrameWatchdogState.Armed,
            dueMs = nowMs + IDLE_MS,
            idleFrames = model.idleFrames + if (idleFrame) 1 else 0,
        ),
        emptyList(),
    )

    fun request(nowMs: Long) = IdleFrameWatchdogTransition(
        model.copy(
            state = IdleFrameWatchdogState.Requested,
            dueMs = nowMs + IDLE_MS,
            requests = model.requests + 1,
        ),
        listOf(IdleFrameWatchdogAction.RequestSyncFrame),
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
                if (event.nowMs >= model.dueMs) request(event.nowMs) else ignored()
            IdleFrameWatchdogEvent.Pause -> IdleFrameWatchdogTransition(model.copy(state = IdleFrameWatchdogState.Idle), emptyList())
            is IdleFrameWatchdogEvent.Resume -> arm(event.nowMs)
            IdleFrameWatchdogEvent.Close -> IdleFrameWatchdogTransition(model.copy(state = IdleFrameWatchdogState.Closed), emptyList())
            is IdleFrameWatchdogEvent.Live -> ignored()
        }

        IdleFrameWatchdogState.Requested -> when (event) {
            is IdleFrameWatchdogEvent.Frame -> arm(event.nowMs, idleFrame = event.keyframe)
            is IdleFrameWatchdogEvent.Tick ->
                if (event.nowMs >= model.dueMs) request(event.nowMs) else ignored()
            IdleFrameWatchdogEvent.Pause -> IdleFrameWatchdogTransition(model.copy(state = IdleFrameWatchdogState.Idle), emptyList())
            is IdleFrameWatchdogEvent.Resume -> arm(event.nowMs)
            IdleFrameWatchdogEvent.Close -> IdleFrameWatchdogTransition(model.copy(state = IdleFrameWatchdogState.Closed), emptyList())
            is IdleFrameWatchdogEvent.Live -> ignored()
        }
    }
}
