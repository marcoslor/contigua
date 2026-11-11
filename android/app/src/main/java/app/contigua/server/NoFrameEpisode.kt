package app.contigua.server

import java.util.Locale

/**
 * One structured no-frame episode (WIN-66, ISS-10): ids, counts, durations and
 * closed tokens only. No app name, label, title, path or text ever enters it,
 * and the type deliberately has no String field — every word on the wire or in
 * the log comes from an enum below.
 *
 * The episode is recorded once, [NO_FRAME_AFTER_MS] after the display was
 * created with no encoded frame, then its end (a late first frame, or the
 * stream's close) updates the same record with [outcome] and [waitedMs]. The
 * app keeps the newest 20 in its private storage; the session sends each state
 * once in the stream's `stream.stats` message (docs/PROTOCOL.md).
 */
enum class NoFrameTask(val wire: String) {
    /** The display had no task when the episode was recorded. */
    None("none"),

    /** A task was launched on the stream's display (`window.opened` named one). */
    Launched("launched"),

    /** This phone cannot read its task list. */
    Unknown("unknown"),
}

/** The stream display's own power state (`Display.STATE_*`, closed names). */
enum class NoFrameDisplay(val wire: String) {
    On("on"),
    Off("off"),
    Doze("doze"),
    DozeSuspend("doze-suspend"),
    Vr("vr"),
    OnSuspend("on-suspend"),
    Unknown("unknown"),
}

enum class NoFrameKeyguard(val wire: String) {
    Showing("showing"),
    Hidden("hidden"),
    Unknown("unknown"),
}

/** `PowerManager.isDeviceIdleMode` / `isLightDeviceIdleMode`. */
enum class NoFrameDoze(val wire: String) {
    Active("active"),
    Light("light"),
    Idle("idle"),
    Unknown("unknown"),
}

/** Display 0's screen state, as `state.screen` names it. */
enum class NoFrameScreen(val wire: String) {
    On("on"),
    Off("off"),
    Unknown("unknown"),
}

/** How the episode ended: a late first frame, or the stream's close. */
enum class NoFrameOutcome(val wire: String) {
    Late("late"),
    Closed("closed"),
}

data class NoFrameEpisode(
    /** The process's id for this episode; the ring updates by it. */
    val episode: Int,
    val stream: Int,
    /** Milliseconds from the display's creation to the record. */
    val recordedMs: Long,
    val display: DisplayPhase,
    val encoder: EncoderPhase,
    val paused: Boolean,
    val suspended: Boolean,
    val task: NoFrameTask,
    val displayState: NoFrameDisplay,
    val keyguard: NoFrameKeyguard,
    val doze: NoFrameDoze,
    val screen: NoFrameScreen,
    /** The redraw nudges the stream made: the input-side evidence it has. */
    val nudges: Int,
    val framesOut: Long,
    val keyframesOut: Long,
    val bytesOut: Long,
    /** Null while the episode is open; set when its end is recorded. */
    val outcome: NoFrameOutcome? = null,
    /** Milliseconds from the display's creation to that end. */
    val waitedMs: Long? = null,
) {
    /** The `stream.stats` field (docs/PROTOCOL.md "Stream stats"). */
    fun wire(): Map<String, Any?> {
        val out = linkedMapOf<String, Any?>(
            "ep" to episode,
            "ms" to recordedMs,
            "phase" to encoderToken(EncoderState(phase = encoder, paused = paused, suspended = suspended)),
            "display" to display.wire,
            "task" to task.wire,
            "on" to displayState.wire,
            "keyguard" to keyguard.wire,
            "doze" to doze.wire,
            "screen" to screen.wire,
            "nudge" to nudges,
            "out" to framesOut,
            "kf" to keyframesOut,
            "bytes" to bytesOut,
        )
        val ended = outcome
        val waited = waitedMs
        if (ended != null && waited != null) {
            out["outcome"] = ended.wire
            out["waitedMs"] = waited
        }
        return out
    }

    /** The phone's field log line for the open episode, and the Mac's first line. */
    fun line(): String {
        val phase = encoderToken(EncoderState(phase = encoder, paused = paused, suspended = suspended))
        return "stream $stream: no frame for ${seconds(recordedMs)}s phase=$phase " +
            "display=${display.wire} task=${task.wire} on=${displayState.wire} " +
            "keyguard=${keyguard.wire} doze=${doze.wire} screen=${screen.wire} " +
            "nudge=$nudges out=$framesOut kf=$keyframesOut bytes=$bytesOut"
    }

    /** The same episode's end; the Mac's second line. */
    fun endedLine(): String =
        "stream $stream: no frame ended outcome=${outcome?.wire ?: "-"} after ${waitedMs ?: recordedMs}ms"

    private fun seconds(ms: Long): String = String.format(Locale.US, "%.1f", ms / 1000.0)
}
