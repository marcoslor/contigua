package dev.pocketdeck.ui

/**
 * The paired-Mac list as the home screen renders it: the row of the Mac with a
 * live session is marked, so it says "Connected now" instead of a stale time.
 * Pure so the mapping is JVM-testable.
 */
fun pairedRows(paired: List<PairedMacUi>, liveClientId: String?): List<PairedMacUi> =
    paired.map { it.copy(connected = liveClientId != null && it.clientId == liveClientId) }

/** Relative times only change on the minute, so one refresh per minute is enough. */
const val RELATIVE_TICK_MS = 60_000L

/** The next whole minute after [now]; the screen's relative-time ticker wakes then. */
fun nextRelativeTick(now: Long): Long = (now / RELATIVE_TICK_MS + 1) * RELATIVE_TICK_MS
