package dev.pocketdeck.server

/**
 * A task an app starts itself right after a paste or a drop into one of its
 * windows belongs to that window's display, never to the phone's own screen
 * (WIN-50, ISS-33, ISS-51).
 *
 * A share target may launch its picker with `FLAG_ACTIVITY_NEW_TASK` from an
 * application context; such a task has no calling activity, so the system
 * gives it the phone's display instead of the window's. The window's display
 * is idle at that moment, so the app is still the stream's task; the arrival
 * is the share's and is moved back.
 *
 * Pure: the caller hands in the app windows it streams (with the time each
 * last sent a paste key or offered a drop's SEND), the package of the arriving
 * task and where the system put it. Nothing here reads a clock or a device.
 */
internal object ShareArrivalPolicy {

    /**
     * How long after the paste or the drop the app's own task still counts as
     * the share's. A person sees the picker within a second or two; a task the
     * app starts later is its own and is not moved.
     */
    const val WINDOW_MS = 5_000L

    /** The phone's own display: a share's task landing here is the bug. */
    const val PHONE_DISPLAY = 0

    /** One streamed app window as the decision sees it. */
    data class Window(
        val stream: Int,
        val pkg: String,
        val displayId: Int,
        /** When this window last sent a paste key or offered a drop's SEND; null: none yet. */
        val shareAtMs: Long?,
    )

    sealed class Decision {
        /** Not a share's own task: the ordinary arrival rules decide. */
        object Ignore : Decision()

        /** The task already sits on a window's display: leave it there. */
        object Keep : Decision()

        /** The task landed on the phone's screen: bring it back to this window. */
        data class Move(val stream: Int, val displayId: Int) : Decision()
    }

    fun decide(
        windows: List<Window>,
        arrivalPkg: String?,
        arrivalDisplayId: Int?,
        nowMs: Long,
    ): Decision {
        val display = arrivalDisplayId ?: return Decision.Ignore
        val pkg = arrivalPkg ?: return Decision.Ignore
        if (display < 0) return Decision.Ignore
        val recent = windows.filter { window ->
            val at = window.shareAtMs ?: return@filter false
            val age = nowMs - at
            window.pkg == pkg && window.displayId > PHONE_DISPLAY && age in 0..WINDOW_MS
        }
        if (recent.isEmpty()) return Decision.Ignore
        // A task on any window's display is already where the product wants
        // it; moving it could steal a second window's picker.
        if (display != PHONE_DISPLAY) return Decision.Keep
        // Two windows of one package: the one whose paste or drop was last is
        // the share's own.
        val target = recent.maxByOrNull { it.shareAtMs ?: Long.MIN_VALUE } ?: return Decision.Ignore
        return Decision.Move(target.stream, target.displayId)
    }
}
