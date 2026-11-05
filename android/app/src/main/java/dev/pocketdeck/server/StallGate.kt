package dev.pocketdeck.server

/**
 * The on-demand link stall (ISS-40 round 2): the bench sets
 * `debug.pocketdeck.stream.stall_ms` and `stall_every_ms`; while a stream has
 * frames queued the session's writer then stops writing for that long every
 * period, so the queue fills exactly as it does when the link stalls.
 *
 * One closed state set, one pure transition, actions returned to the caller:
 * the writer performs the wait, so nothing goes to the socket while it lasts.
 * Only the debug property can create this gate; no product path sets a stall.
 */
internal enum class StallState {
    Flowing,
    Stalled,
}

internal sealed interface StallEvent {
    /** The writer is about to send a frame for this gate's stream. */
    data class Frame(val nowMs: Long) : StallEvent
}

internal sealed interface StallAction {
    /** One field-log line per injected stall. */
    data class LogInjected(val stream: Int, val ms: Int) : StallAction

    /** Do not write for this long: the queue fills behind the dead link. */
    data class Wait(val ms: Int) : StallAction
}

internal data class StallStep(
    val state: StallState,
    val actions: List<StallAction>,
    val event: String,
)

/**
 * The stall schedule for one stream. The first pause starts one period after
 * the stream opened; each following start is a full period after the last, so
 * a 400 ms stall with a 5000 ms period leaves 4.6 s of flow.
 */
internal class StallGate(
    val stream: Int,
    private val stallMs: Int,
    private val everyMs: Int,
    startMs: Long,
    private val log: (String) -> Unit = {},
) {
    var state: StallState = StallState.Flowing
        private set

    private var nextDueMs = startMs + everyMs
    private var stalledUntilMs = 0L

    fun beforeWrite(nowMs: Long): StallStep {
        val event = StallEvent.Frame(nowMs)
        val step = when (state) {
            StallState.Flowing ->
                if (nowMs >= nextDueMs) {
                    stalledUntilMs = nowMs + stallMs
                    nextDueMs = nowMs + everyMs
                    StallStep(
                        StallState.Stalled,
                        listOf(StallAction.LogInjected(stream, stallMs), StallAction.Wait(stallMs)),
                        "frame",
                    )
                } else {
                    StallStep(StallState.Flowing, emptyList(), "frame")
                }
            StallState.Stalled ->
                if (nowMs >= stalledUntilMs) {
                    StallStep(StallState.Flowing, emptyList(), "resume")
                } else {
                    StallStep(StallState.Stalled, emptyList(), "frame")
                }
        }
        if (step.state != state) {
            log("stall: ${state.name.lowercase()} --${step.event}--> ${step.state.name.lowercase()}")
        }
        state = step.state
        return step
    }
}
