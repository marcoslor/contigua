package dev.pocketdeck.server

/**
 * Which task "Continue on Mac" takes (docs/ROADMAP.md #9). Pure, so the
 * exclusion rules are unit-tested without Android.
 *
 * Only the phone's own screen counts (display 0): tasks already on a virtual
 * display are the ones this feature itself opened. Excluded are our own app,
 * the launcher/home, SystemUI — which also draws the keyguard — and anything
 * with no package behind it. The launcher's package varies per build, so the
 * home task is recognized by its TaskInfo flag, not by name.
 */
object ForegroundTaskPicker {

    /**
     * The newest continuable task on the screen's display (the system reports
     * tasks most recently active first), or null when the screen holds only
     * excluded surfaces: the phone then answers `nothing_to_continue`.
     */
    fun pick(tasks: List<SystemTask>, ownPkg: String, screenDisplayId: Int = 0): SystemTask? =
        tasks.firstOrNull { it.displayId == screenDisplayId && isContinuable(it, ownPkg) }

    /** [task] is not one of the surfaces "Continue on Mac" must not take. */
    fun isContinuable(task: SystemTask, ownPkg: String): Boolean =
        task.pkg.isNotEmpty() && task.pkg != ownPkg && !task.isHome && !task.isSystemUi
}
