package dev.pocketdeck.server

/**
 * Audio follows the open windows (docs/design/audio.md "follows the window").
 *
 * The session describes each open window as a [CaptureWindow]; [AudioFollow.plan]
 * turns that into the capture mode:
 *
 * - [FollowPlan.Idle] — nothing to capture (no windows, or only windows that
 *   play nothing, e.g. our launcher).
 * - [FollowPlan.PerApp] — one AudioPolicy whose loop-back mix matches the UIDs
 *   of the apps shown in the windows; everything else keeps playing on the
 *   phone speaker.
 * - [FollowPlan.AllAudio] — the whole-phone path (REMOTE_SUBMIX): a phone-mode
 *   window is open ("all audio"), or a window we cannot attribute (fallback
 *   for any window whose app cannot be named or resolved).
 */
sealed interface CaptureWindow {
    /** Phone-mode window (mirror of the whole phone): all audio. */
    data object Phone : CaptureWindow

    /**
     * An app window we cannot attribute yet (a link whose app Android still
     * picks, or a UID lookup failure). Falls back to all audio so the shown
     * window's audio still reaches the Mac.
     */
    data class Unresolved(val why: String) : CaptureWindow

    /** A window that plays nothing worth capturing (our own launcher on top). */
    data object Silent : CaptureWindow

    /** An app window showing this package. */
    data class App(val pkg: String) : CaptureWindow
}

sealed interface FollowPlan {
    data object Idle : FollowPlan

    /** Device-wide REMOTE_SUBMIX capture (today's path). */
    data object AllAudio : FollowPlan

    /** Capture only these UIDs (sorted, distinct), via one uid-filtered loop-back mix. */
    data class PerApp(val uids: List<Int>) : FollowPlan
}

object AudioFollow {

    /**
     * @param windows one entry per open window, in any order
     * @param uidOf package name → app UID, or null when the package cannot be
     *   resolved or it plays nothing the mix should carry (e.g. our own package)
     */
    fun plan(windows: List<CaptureWindow>, uidOf: (String) -> Int?): FollowPlan {
        if (windows.isEmpty()) return FollowPlan.Idle
        if (windows.any { it is CaptureWindow.Phone }) return FollowPlan.AllAudio
        windows.filterIsInstance<CaptureWindow.Unresolved>().firstOrNull()?.let {
            return FollowPlan.AllAudio
        }
        val apps = windows.filterIsInstance<CaptureWindow.App>()
        val uids = apps.mapNotNull { uidOf(it.pkg) }.distinct().sorted()
        // Only resolved UIDs can be mixed; whatever a lookup missed keeps its
        // own playback (that window just does not stream). No capturable UID
        // with windows still open is not "mute the phone": it is idle.
        return if (uids.isEmpty()) FollowPlan.Idle else FollowPlan.PerApp(uids)
    }
}
