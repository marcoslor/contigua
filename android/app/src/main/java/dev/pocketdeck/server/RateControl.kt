package dev.pocketdeck.server

/**
 * The rate controller (PATH-47/48): one pure machine for the early, delay-based
 * bitrate signal and the resolution/fps ladder.
 *
 * `Steady` watches the queue-delay windows; a window whose p95 is at or above
 * [HIGH_DELAY_US] and whose newest deep run reads a link under the belief
 * lowers the belief to [HEADROOM] of that reading, before the 250 ms budget has
 * to drop anything. `Pressured` keeps following a lower link at most once per
 * [MIN_LOWER_INTERVAL_MS], and returns to `Steady` after [CALM_MS] of windows
 * whose median is below [CALM_DELAY_US].
 *
 * The same state carries the rung: when the belief has sat at its down-step
 * floor for [stressMs] with a high p95, the rung steps down one level
 * (`full` → `three-quarters` → `half`); after [ladderCalmMs] below the recovery
 * line it steps back up one level, at most one step per [minStepIntervalMs] in
 * either direction. An explicit `window.quality` cancels the rung (`--quality--`),
 * a failed resize reports `--kept--` and leaves the rung where it was.
 *
 * This is the one state machine: the phase, the rung and every timer are fields
 * of [RateControlState]; the transition returns at most one [RateAction], never
 * performs it, and logs every phase/rung change as
 * `ratectl: <phase>/<rung> --<event>--> <phase>/<rung>`.
 */
internal enum class RatePhase(val wire: String) {
    Steady("steady"),
    Pressured("pressured"),
}

internal enum class LadderRung(val wire: String, val scale: Double) {
    Full("full", 1.0),
    ThreeQuarters("three-quarters", 0.75),
    Half("half", 0.5),
    ;

    fun down(): LadderRung = when (this) {
        Full -> ThreeQuarters
        ThreeQuarters -> Half
        Half -> Half
    }

    fun up(): LadderRung = when (this) {
        Full -> Full
        ThreeQuarters -> Full
        Half -> ThreeQuarters
    }
}

internal sealed interface RateControlEvent {
    /**
     * One measurement window. [delayP95Us]/[delayP50Us] are null when the
     * writer had too few samples (a drop episode, a pause): that is not a calm
     * link and is ignored. [early] and [ladder] are the two debug switches;
     * a disabled half is ignored, never fed a fake reading.
     */
    data class Window(
        val nowMs: Long,
        val delayP95Us: Long?,
        val delayP50Us: Long?,
        val linkBps: Int?,
        val believedBps: Int,
        val atFloor: Boolean,
        val early: Boolean = true,
        val ladder: Boolean = true,
    ) : RateControlEvent

    /** The send queue dropped deltas: the drop rule now owns this episode. */
    data class Drop(val nowMs: Long) : RateControlEvent

    /** An explicit `window.quality` (bitrate or fps): the person ends the rung. */
    data object Quality : RateControlEvent

    /** The resize for a rung answered `kept` (WIN-6): stay at [from]. */
    data class RungFailed(
        val from: LadderRung,
        val to: LadderRung,
        val nowMs: Long,
    ) : RateControlEvent

    /** A new stream: every timer and the rung start over. */
    data object Reset : RateControlEvent
}

internal sealed interface RateControlAction {
    /** The belief must come down to this bitrate before the queue overflows. */
    data class LowerTo(val bps: Int) : RateControlAction

    /** Rebuild the stream at [to]; [baseBps] is the believed floor the rung started from. */
    data class Scale(
        val from: LadderRung,
        val to: LadderRung,
        val baseBps: Int,
    ) : RateControlAction

    data object None : RateControlAction
}

internal data class RateControlState(
    val phase: RatePhase = RatePhase.Steady,
    val rung: LadderRung = LadderRung.Full,
    /** The believed bitrate at the moment the rung first left Full. */
    val baseBps: Int = 0,
    val highSinceMs: Long = NO_TIME,
    val calmSinceMs: Long = NO_TIME,
    val stressSinceMs: Long = NO_TIME,
    val ladderCalmSinceMs: Long = NO_TIME,
    val lastLowerAtMs: Long = NO_TIME,
    val lastDropAtMs: Long = NO_TIME,
    val lastStepAtMs: Long = NO_TIME,
    /** Consecutive windows whose deep link reading yields a cap under the belief. */
    val lowLinkWindows: Int = 0,
) {
    /** The transition token, e.g. `pressured/three-quarters`. */
    val token: String get() = "${phase.wire}/${rung.wire}"

    companion object {
        const val NO_TIME = Long.MIN_VALUE
    }
}

internal data class RateControlStep(
    val state: RateControlState,
    val action: RateControlAction = RateControlAction.None,
    val line: String? = null,
)

internal class RateControl(
    private val highDelayUs: Long = HIGH_DELAY_US,
    private val holdMs: Long = HOLD_MS,
    private val calmMs: Long = CALM_MS,
    private val calmDelayUs: Long = CALM_DELAY_US,
    private val minLowerIntervalMs: Long = MIN_LOWER_INTERVAL_MS,
    private val minLowerAfterDropMs: Long = MIN_LOWER_AFTER_DROP_MS,
    private val headroom: Double = HEADROOM,
    private val stressMs: Long = STRESS_MS,
    private val ladderCalmMs: Long = LADDER_CALM_MS,
    private val minStepIntervalMs: Long = MIN_STEP_INTERVAL_MS,
) {

    fun step(state: RateControlState, event: RateControlEvent): RateControlStep =
        when (event) {
            is RateControlEvent.Window -> window(state, event)
            is RateControlEvent.Drop -> drop(state, event)
            RateControlEvent.Quality -> quality(state)
            is RateControlEvent.RungFailed -> failed(state, event)
            RateControlEvent.Reset -> RateControlStep(RateControlState())
        }

    private fun window(state: RateControlState, event: RateControlEvent.Window): RateControlStep {
        val high = event.delayP95Us != null && event.delayP95Us >= highDelayUs
        // Calm is the median, not the tail: a 200 ms stall every 2 s keeps p95
        // high on a link whose standing queue is already gone.
        val calm = event.delayP50Us != null && event.delayP50Us < calmDelayUs

        if (!event.ladder && state.rung != LadderRung.Full) {
            // The debug switch turned the ladder off: put the asked box back.
            val next = state.copy(rung = LadderRung.Full, stressSinceMs = NO_TIME,
                                  ladderCalmSinceMs = NO_TIME)
            val line = "ratectl: ${state.token} --off--> ${next.token}"
            return RateControlStep(
                next,
                RateControlAction.Scale(state.rung, LadderRung.Full, next.baseBps),
                line,
            )
        }
        var next = state
        var line: String? = null
        var action: RateControlAction = RateControlAction.None
        if (event.early) {
            val early = early(next, event, high, calm)
            next = early.state
            line = early.line
            action = early.action
        }
        if (action == RateControlAction.None && event.ladder) {
            val ladder = ladder(next, event, high, calm)
            next = ladder.state
            if (line == null) line = ladder.line
            action = ladder.action
        }
        return RateControlStep(next, action, line)
    }

    private fun early(
        state: RateControlState,
        event: RateControlEvent.Window,
        high: Boolean,
        calm: Boolean,
    ): RateControlStep {
        // A usable cap means the reading is under the belief: that is the run
        // the debounce counts, not a second 90 % test that would block a small
        // correction on an 8 Mbit/s link believed to carry 6.4.
        val cap = capFor(event.linkBps, event.believedBps)
        val lowRun = if (cap != null) state.lowLinkWindows + 1 else 0
        return when (state.phase) {
            RatePhase.Steady -> steady(state, event, high, cap, lowRun)
            RatePhase.Pressured -> pressured(state, event, calm, cap, lowRun)
        }
    }

    private fun steady(
        state: RateControlState,
        event: RateControlEvent.Window,
        high: Boolean,
        cap: Int?,
        lowRun: Int,
    ): RateControlStep {
        if (!high || event.delayP95Us == null) {
            return RateControlStep(
                state.copy(highSinceMs = NO_TIME, calmSinceMs = NO_TIME,
                           lowLinkWindows = lowRun),
            )
        }
        val since = if (state.highSinceMs == NO_TIME) event.nowMs else state.highSinceMs
        if (event.nowMs - since < holdMs) {
            return RateControlStep(state.copy(highSinceMs = since, lowLinkWindows = lowRun))
        }
        val next = state.copy(
            phase = RatePhase.Pressured,
            highSinceMs = since,
            calmSinceMs = NO_TIME,
            lowLinkWindows = lowRun,
        )
        if (cap == null || lowRun < LOW_LINK_WINDOWS || !canLower(state, event.nowMs)) {
            return RateControlStep(
                next,
                line = "ratectl: ${state.token} --hold--> ${next.token}",
            )
        }
        val lowered = next.copy(lastLowerAtMs = event.nowMs, lowLinkWindows = 0)
        val line = "ratectl: ${state.token} --hold--> ${lowered.token}" +
            " (target ${cap / 1000} kbps from delay ${event.delayP95Us / 1000} ms" +
            " link ${event.linkBps!! / 1000} kbps)"
        return RateControlStep(lowered, RateControlAction.LowerTo(cap), line)
    }

    private fun pressured(
        state: RateControlState,
        event: RateControlEvent.Window,
        calm: Boolean,
        cap: Int?,
        lowRun: Int,
    ): RateControlStep {
        if (event.delayP95Us == null || event.delayP50Us == null) {
            // Writes stopped: neither a continued hold nor a recovery.
            return RateControlStep(
                state.copy(highSinceMs = NO_TIME, calmSinceMs = NO_TIME,
                           lowLinkWindows = lowRun),
            )
        }
        if (calm) {
            val since = if (state.calmSinceMs == NO_TIME) event.nowMs else state.calmSinceMs
            if (event.nowMs - since < calmMs) {
                return RateControlStep(
                    state.copy(calmSinceMs = since, highSinceMs = NO_TIME,
                               lowLinkWindows = lowRun),
                )
            }
            val next = state.copy(phase = RatePhase.Steady, calmSinceMs = NO_TIME,
                                  highSinceMs = NO_TIME, lowLinkWindows = lowRun)
            return RateControlStep(
                next,
                line = "ratectl: ${state.token} --calm--> ${next.token}" +
                    " (delay ${event.delayP50Us / 1000} ms)",
            )
        }
        val next = state.copy(calmSinceMs = NO_TIME, lowLinkWindows = lowRun)
        if (cap == null || lowRun < LOW_LINK_WINDOWS || !canLower(state, event.nowMs)) {
            return RateControlStep(next)
        }
        val lowered = next.copy(lastLowerAtMs = event.nowMs, lowLinkWindows = 0)
        val line = "ratectl: ${state.token} --lower--> ${lowered.token}" +
            " (target ${cap / 1000} kbps from delay ${event.delayP95Us / 1000} ms" +
            " link ${event.linkBps!! / 1000} kbps)"
        return RateControlStep(lowered, RateControlAction.LowerTo(cap), line)
    }

    private fun ladder(
        state: RateControlState,
        event: RateControlEvent.Window,
        high: Boolean,
        calm: Boolean,
    ): RateControlStep {
        val canStep = state.lastStepAtMs == NO_TIME ||
            event.nowMs - state.lastStepAtMs >= minStepIntervalMs
        if (high && event.atFloor) {
            val since = if (state.stressSinceMs == NO_TIME) event.nowMs else state.stressSinceMs
            if (event.nowMs - since < stressMs || !canStep) {
                return RateControlStep(
                    state.copy(stressSinceMs = since, ladderCalmSinceMs = NO_TIME),
                )
            }
            val to = state.rung.down()
            if (to == state.rung) {
                // Half is the bottom: keep the stress timer, do nothing.
                return RateControlStep(state.copy(stressSinceMs = since))
            }
            val base = if (state.rung == LadderRung.Full) event.believedBps else state.baseBps
            val next = state.copy(
                rung = to,
                baseBps = base,
                stressSinceMs = NO_TIME,
                ladderCalmSinceMs = NO_TIME,
                lastStepAtMs = event.nowMs,
            )
            val line = "ratectl: ${state.token} --stress--> ${next.token}"
            return RateControlStep(
                next,
                RateControlAction.Scale(state.rung, to, base),
                line,
            )
        }
        var next = if (state.stressSinceMs != NO_TIME) {
            state.copy(stressSinceMs = NO_TIME)
        } else {
            state
        }
        if (calm) {
            val since = if (next.ladderCalmSinceMs == NO_TIME) {
                event.nowMs
            } else {
                next.ladderCalmSinceMs
            }
            if (event.nowMs - since < ladderCalmMs || !canStep) {
                return RateControlStep(next.copy(ladderCalmSinceMs = since))
            }
            val to = next.rung.up()
            if (to == next.rung) {
                return RateControlStep(next.copy(ladderCalmSinceMs = NO_TIME))
            }
            val from = next.rung
            next = next.copy(
                rung = to,
                ladderCalmSinceMs = NO_TIME,
                stressSinceMs = NO_TIME,
                lastStepAtMs = event.nowMs,
            )
            val line = "ratectl: ${state.token} --recover--> ${next.token}"
            return RateControlStep(
                next,
                RateControlAction.Scale(from, to, next.baseBps),
                line,
            )
        }
        if (next.ladderCalmSinceMs != NO_TIME) {
            next = next.copy(ladderCalmSinceMs = NO_TIME)
        }
        return RateControlStep(next)
    }

    private fun drop(state: RateControlState, event: RateControlEvent.Drop): RateControlStep {
        val next = state.copy(
            highSinceMs = NO_TIME,
            calmSinceMs = NO_TIME,
            lastDropAtMs = event.nowMs,
            lowLinkWindows = 0,
            ladderCalmSinceMs = NO_TIME,
        )
        return RateControlStep(
            next,
            line = "ratectl: ${state.token} --drop--> ${next.token}",
        )
    }

    private fun quality(state: RateControlState): RateControlStep {
        val next = RateControlState()
        val line = if (state.rung == LadderRung.Full && state.phase == RatePhase.Steady) {
            null
        } else {
            "ratectl: ${state.token} --quality--> ${next.token}"
        }
        if (state.rung == LadderRung.Full) return RateControlStep(next, line = line)
        return RateControlStep(
            next,
            RateControlAction.Scale(state.rung, LadderRung.Full, state.baseBps),
            line,
        )
    }

    private fun failed(state: RateControlState, event: RateControlEvent.RungFailed): RateControlStep {
        // A newer step (or a cancel) owns the rung now: the old answer is stale.
        if (state.rung != event.to) return RateControlStep(state)
        val next = state.copy(
            rung = event.from,
            stressSinceMs = NO_TIME,
            ladderCalmSinceMs = NO_TIME,
        )
        return RateControlStep(
            next,
            line = "ratectl: ${state.token} --kept--> ${next.token}",
        )
    }

    /** 75 % of the link, or null when the link is unknown or the belief already fits. */
    private fun capFor(linkBps: Int?, believedBps: Int): Int? {
        if (linkBps == null || linkBps <= 0) return null
        val cap = maxOf(MIN_BPS, (linkBps * headroom).toInt())
        if (believedBps <= cap) return null
        return cap
    }

    private fun canLower(state: RateControlState, nowMs: Long): Boolean {
        if (state.lastDropAtMs != NO_TIME && nowMs - state.lastDropAtMs < minLowerAfterDropMs) {
            return false
        }
        return state.lastLowerAtMs == NO_TIME || nowMs - state.lastLowerAtMs >= minLowerIntervalMs
    }

    companion object {
        /** A p95 at or above this is the delay the field logs call a hitch. */
        const val HIGH_DELAY_US = 100_000L
        /** The two-second p95 window is the sustain; no extra hold. */
        const val HOLD_MS = 0L
        /** Five seconds under the line before the recovery clock is free again. */
        const val CALM_MS = 5_000L
        /** The median below which the standing queue is gone (the 100 ms tail is stalls). */
        const val CALM_DELAY_US = 50_000L
        /** A link that keeps reading lower is followed, but not every window. */
        const val MIN_LOWER_INTERVAL_MS = 2_000L
        /** After a drop the drop rule owns the episode; the early signal waits it out. */
        const val MIN_LOWER_AFTER_DROP_MS = 2_000L
        /** One deep reading with a usable cap is enough to lower. */
        const val LOW_LINK_WINDOWS = 1
        /** The early signal leaves a quarter of the measured link for keyframe bursts. */
        const val HEADROOM = 0.75
        /** The encoder's own smallest key (EncoderCorrection.FLOOR_BPS). */
        const val MIN_BPS = 250_000
        /** Five seconds at the floor with a high delay before sending fewer pixels. */
        const val STRESS_MS = 5_000L
        /** Thirty seconds below the lower line before a step back up. */
        const val LADDER_CALM_MS = 30_000L
        /** One rung change per half minute in either direction: no flapping. */
        const val MIN_STEP_INTERVAL_MS = 30_000L

        private const val NO_TIME = RateControlState.NO_TIME
    }
}
