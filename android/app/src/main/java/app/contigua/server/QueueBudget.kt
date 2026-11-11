package app.contigua.server

/**
 * One stream's video queue budget: the base 250 ms, extended while a key frame
 * is queued and while the deltas that arrived behind it drain.
 *
 * The overrun spiral (arm A): a key frame is bigger than a byte budget sized
 * for the *believed* target (256 KB at 8 Mbps), so the deltas behind it
 * overflow, the queue asks for another key frame, and the cycle repeats on a
 * link that carries every byte. The budget must admit a whole key frame and
 * the video that arrived while it was being written, and its byte half must
 * follow the measured rate (the link's goodput when it is known, else the
 * encoder's own output), not a constant 8 Mbps.
 *
 * One pure transition over a closed set of phases, no side effects: the queue
 * reads [BudgetState.keyBytes] and [BudgetState.creditUs] when it checks a
 * delta and performs the logging. The states are:
 * - Steady: no key frame queued, no credit.
 * - Keyframe: at least one key frame is queued; its bytes extend the byte
 *   budget and its send time extends the duration budget.
 * - Draining: the key frames left, but deltas that arrived behind them are
 *   still queued; their bytes and wait stay as credit until they drain, then
 *   Steady. The byte credit is what admits the video that arrived while the
 *   key was being written; dropping it when the writer dequeues the key makes
 *   the queue drop those deltas and ask for another key.
 */
internal enum class BudgetPhase(val wire: String) {
    Steady("steady"),
    Keyframe("keyframe"),
    Draining("draining"),
}

internal data class BudgetState(
    val phase: BudgetPhase = BudgetPhase.Steady,
    /** Key frame bytes queued but not yet handed to the socket. */
    val keyBytes: Long = 0,
    /**
     * Bytes of key frames already handed to the socket whose deltas are still
     * draining. They extend the byte budget until the deltas that arrived
     * while the key was being written have left, then [BudgetEvent.Drained]
     * clears them.
     */
    val byteCredit: Long = 0,
    /** Extra wait the deltas behind a key frame may have, in µs. */
    val creditUs: Long = 0,
)

internal sealed interface BudgetEvent {
    /** A video key frame was queued; [rateBps] sizes its send-time credit. */
    data class KeyQueued(val bytes: Int, val rateBps: Int) : BudgetEvent

    /** A queued key frame left for the socket. */
    data class KeySent(val bytes: Int) : BudgetEvent

    /** The stream's delta queue is empty and no key frame is queued. */
    data object Drained : BudgetEvent
}

internal data class BudgetStep(
    val state: BudgetState,
    /** The event token in the transition log line. */
    val event: String,
    val transition: Boolean,
)

/** A key frame's send-time credit never exceeds this, whatever the link says. */
internal const val MAX_BUDGET_CREDIT_US = 2_000_000L

internal fun budgetStep(state: BudgetState, event: BudgetEvent): BudgetStep = when (event) {
    is BudgetEvent.KeyQueued -> {
        val credit = if (event.rateBps > 0) {
            (event.bytes.toLong() * 8_000_000L / event.rateBps)
                .coerceAtMost(MAX_BUDGET_CREDIT_US)
        } else {
            0L
        }
        BudgetStep(
            BudgetState(
                phase = BudgetPhase.Keyframe,
                keyBytes = state.keyBytes + event.bytes,
                // A key frame queued while an earlier key's deltas are still
                // draining must not throw away that earlier key's bytes.
                byteCredit = state.byteCredit,
                creditUs = maxOf(state.creditUs, credit),
            ),
            "key(${event.bytes})",
            true,
        )
    }

    is BudgetEvent.KeySent -> {
        val left = (state.keyBytes - event.bytes).coerceAtLeast(0)
        if (state.keyBytes == 0L) {
            // No key frame was queued: a stale event changes nothing.
            BudgetStep(state, "key-sent", false)
        } else {
            BudgetStep(
                state.copy(
                    phase = if (left > 0) BudgetPhase.Keyframe else BudgetPhase.Draining,
                    keyBytes = left,
                    // The key is on the socket but its send still occupies the
                    // link; the deltas that arrived behind it keep its bytes as
                    // credit until they drain.
                    byteCredit = state.byteCredit + event.bytes,
                ),
                "key-sent",
                true,
            )
        }
    }

    BudgetEvent.Drained -> when {
        // A queued key frame means the video lane is not drained yet.
        state.keyBytes > 0 -> BudgetStep(state, "drained", false)
        state.phase == BudgetPhase.Steady -> BudgetStep(state, "drained", false)
        else -> BudgetStep(BudgetState(), "drained", true)
    }
}
