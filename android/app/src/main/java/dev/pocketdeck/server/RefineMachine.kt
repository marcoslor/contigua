package dev.pocketdeck.server

/**
 * T1's still refinement: one higher-quality frame after motion stops, and never
 * a wait for motion.
 *
 * idle → refining on a still period; the refined sync frame ends it (done), a
 * changed frame or a suspend cancels it and restores the target at once. Done
 * ignores further still events, so one still period gets one refinement; new
 * motion re-arms it. A one-second timeout restores the target if the sync frame
 * never arrives (an encoder that produces nothing at all).
 *
 * Pure: the caller performs the returned actions on the encoder.
 */
internal enum class RefineState {
    Idle,
    Refining,
    Done,
    ;

    val wire: String get() = name.lowercase()
}

internal sealed interface RefineEvent {
    /** The stream has produced no new picture for the still threshold. */
    data object Still : RefineEvent

    /**
     * One encoded frame left the encoder. [keyframe] is its own flag;
     * [changed] says its size differs from the previous frame, the one signal
     * an encoder gives that its input moved (repeats keep the same size).
     */
    data class Frame(val keyframe: Boolean, val changed: Boolean) : RefineEvent

    /** The drain loop's clock, for the refinement's safety timeout. */
    data class Tick(val nowMs: Long) : RefineEvent

    /** Q1 suspended the encoder: motion is intentionally paused, not still. */
    data object Suspend : RefineEvent

    data object Close : RefineEvent
}

internal sealed interface RefineAction {
    /** Raise the live bitrate to 3× the target, up to the cap. */
    data object RaiseBitrate : RefineAction

    /** Ask the encoder for one sync frame at that bitrate. */
    data object RequestSync : RefineAction

    /** Back to the adaptation's current target. */
    data object RestoreBitrate : RefineAction
}

internal data class RefineModel(
    val state: RefineState = RefineState.Idle,
    val startedMs: Long = 0,
)

internal data class RefineStep(
    val model: RefineModel,
    val actions: List<RefineAction>,
    val event: String,
)

/** How long a refinement may wait for its sync frame before restoring. */
internal const val REFINE_TIMEOUT_MS = 1_000L

internal fun refineStep(model: RefineModel, event: RefineEvent, nowMs: Long = 0): RefineStep {
    fun stay(actions: List<RefineAction> = emptyList(), token: String) =
        RefineStep(model, actions, token)

    fun cancel(actions: List<RefineAction>, token: String) =
        RefineStep(RefineModel(RefineState.Idle), actions, token)

    return when (model.state) {
        RefineState.Idle -> when (event) {
            RefineEvent.Still -> RefineStep(
                RefineModel(RefineState.Refining, nowMs),
                listOf(RefineAction.RaiseBitrate, RefineAction.RequestSync),
                "still",
            )
            is RefineEvent.Frame -> stay(token = "frame")
            is RefineEvent.Tick -> stay(token = "tick")
            RefineEvent.Suspend -> stay(token = "suspend")
            RefineEvent.Close -> stay(token = "close")
        }

        RefineState.Refining -> when (event) {
            is RefineEvent.Frame -> when {
                event.keyframe -> RefineStep(
                    RefineModel(RefineState.Done),
                    listOf(RefineAction.RestoreBitrate),
                    "keyframe",
                )
                event.changed -> cancel(listOf(RefineAction.RestoreBitrate), "motion")
                else -> stay(token = "repeat")
            }
            is RefineEvent.Tick ->
                if (nowMs - model.startedMs >= REFINE_TIMEOUT_MS) {
                    // One refinement per still period: a sync frame that never
                    // comes does not retry until motion re-arms the machine.
                    RefineStep(RefineModel(RefineState.Done),
                               listOf(RefineAction.RestoreBitrate), "timeout")
                } else {
                    stay(token = "tick")
                }
            RefineEvent.Still -> stay(token = "still")
            RefineEvent.Suspend -> cancel(listOf(RefineAction.RestoreBitrate), "suspend")
            RefineEvent.Close -> cancel(listOf(RefineAction.RestoreBitrate), "close")
        }

        RefineState.Done -> when (event) {
            is RefineEvent.Frame -> if (!event.keyframe && event.changed) {
                RefineStep(RefineModel(RefineState.Idle), emptyList(), "motion")
            } else {
                stay(token = "frame")
            }
            is RefineEvent.Tick -> stay(token = "tick")
            RefineEvent.Still -> stay(token = "still") // one per still period
            RefineEvent.Suspend -> RefineStep(RefineModel(RefineState.Idle), emptyList(), "suspend")
            RefineEvent.Close -> RefineStep(RefineModel(RefineState.Idle), emptyList(), "close")
        }
    }
}
