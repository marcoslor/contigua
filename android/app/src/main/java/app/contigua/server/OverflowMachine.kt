package app.contigua.server

/**
 * Q1's overflow policy for one stream: flowing, suspended (the encoder skips
 * frames at its input, so the reference chain stays intact), or
 * fallback-dropped (the hard byte ceiling: today's discard + keyframe).
 *
 * One pure transition over a closed state set, actions returned to the caller;
 * SendQueue performs them outside its lock. A suspended encoder resumes once
 * the queue is below half its budget, so the picture does not oscillate on the
 * threshold.
 */
internal enum class OverflowState {
    Flowing,
    Suspended,
    FallbackDropped,
    ;

    val wire: String get() = name.lowercase()
}

internal sealed interface OverflowEvent {
    /** The queued video passed the budget; [hardCeiling] means past 4×. */
    data class Pressure(val hardCeiling: Boolean) : OverflowEvent

    /** A queued delta left and the backlog is below half the budget. */
    data object Drained : OverflowEvent

    /** A config or keyframe was queued: the backlog is about to be discarded. */
    data object Control : OverflowEvent

    /**
     * The session's ticker. [suspendedSinceMs] is when this stream's suspend
     * began; [backlogUnderHalf] is the drained condition at this tick.
     */
    data class Tick(
        val nowMs: Long,
        val suspendedSinceMs: Long,
        val backlogUnderHalf: Boolean,
    ) : OverflowEvent
}

/** Q1: a suspend never outlives its cause by more than this, whatever the backlog. */
internal const val SUSPEND_TIMEOUT_MS = 1_000L

internal sealed interface OverflowAction {
    /** `PARAMETER_KEY_SUSPEND` 1: stop taking input, keep the encoder running. */
    data object SuspendEncoder : OverflowAction

    /** `PARAMETER_KEY_SUSPEND` 0: take input again. */
    data object ResumeEncoder : OverflowAction

    /** The queue overflowed: today's −25 % bitrate reaction, no keyframe. */
    data object LowerBitrate : OverflowAction

    /** At the hard ceiling: today's discard-everything + keyframe request. */
    data object DropAndKeyframe : OverflowAction
}

internal data class OverflowStep(
    val state: OverflowState,
    val actions: List<OverflowAction>,
    /** The event token in the transition log line. */
    val event: String,
)

internal fun overflowStep(state: OverflowState, event: OverflowEvent): OverflowStep {
    fun stay(actions: List<OverflowAction> = emptyList(), token: String) =
        OverflowStep(state, actions, token)

    return when (state) {
        OverflowState.Flowing -> when (event) {
            is OverflowEvent.Pressure ->
                if (event.hardCeiling) {
                    OverflowStep(OverflowState.FallbackDropped,
                                 listOf(OverflowAction.DropAndKeyframe), "pressure-hard")
                } else {
                    OverflowStep(OverflowState.Suspended,
                                 listOf(OverflowAction.SuspendEncoder, OverflowAction.LowerBitrate),
                                 "pressure")
                }
            OverflowEvent.Drained -> stay(token = "drained")
            OverflowEvent.Control -> stay(token = "control")
            is OverflowEvent.Tick -> stay(token = "tick")
        }

        OverflowState.Suspended -> when (event) {
            is OverflowEvent.Pressure ->
                if (event.hardCeiling) {
                    OverflowStep(OverflowState.FallbackDropped,
                                 listOf(OverflowAction.ResumeEncoder, OverflowAction.DropAndKeyframe),
                                 "pressure-hard")
                } else {
                    stay(token = "pressure")
                }
            OverflowEvent.Drained ->
                OverflowStep(OverflowState.Flowing, listOf(OverflowAction.ResumeEncoder), "drained")
            OverflowEvent.Control ->
                OverflowStep(OverflowState.Flowing, listOf(OverflowAction.ResumeEncoder), "control")
            is OverflowEvent.Tick ->
                when {
                    event.backlogUnderHalf ->
                        OverflowStep(OverflowState.Flowing,
                                     listOf(OverflowAction.ResumeEncoder), "tick")
                    event.nowMs - event.suspendedSinceMs > SUSPEND_TIMEOUT_MS ->
                        OverflowStep(OverflowState.Flowing,
                                     listOf(OverflowAction.ResumeEncoder), "timeout")
                    else -> stay(token = "tick")
                }
        }

        OverflowState.FallbackDropped -> when (event) {
            OverflowEvent.Control -> OverflowStep(OverflowState.Flowing, emptyList(), "control")
            is OverflowEvent.Pressure -> stay(token = "pressure")
            OverflowEvent.Drained -> stay(token = "drained")
            is OverflowEvent.Tick -> stay(token = "tick")
        }
    }
}

/** One stream's queue budget and overflow policy, read at its first delta. */
internal data class QueuePolicy(
    val overflow: StreamStrategy.Overflow,
    val maxBytes: Int,
    val maxDurationUs: Long,
) {
    /** The memory guard: at 4× the byte budget the stream falls back to drops. */
    val hardBytes: Int get() = maxBytes * 4

    companion object {
        fun of(strategy: StreamStrategy, baseBytes: Int, baseDurationUs: Long) = QueuePolicy(
            overflow = strategy.overflow,
            maxBytes = strategy.queueBytes(baseBytes).coerceAtLeast(1),
            maxDurationUs = strategy.queueDurationUs(baseDurationUs),
        )

        fun today(baseBytes: Int, baseDurationUs: Long) =
            QueuePolicy(StreamStrategy.Overflow.Drop, baseBytes, baseDurationUs)
    }
}
