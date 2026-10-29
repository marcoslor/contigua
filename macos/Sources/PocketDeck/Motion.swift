// The app's effective Reduce Motion (CONV-MAC-22): the system setting, with a
// test-hooks-only override so the e2e VM can prove the fisheye while its
// accessibility preference stays the guest's. One place, so the rail, its ease
// and the fisheye all agree.

import Foundation

enum Motion {
    /// `--debug-motion full` (test hooks only; a release build ignores the
    /// flag, so this stays false there). Initialised from the command line on
    /// first use: a scene body can be evaluated before AppEnvironment exists,
    /// and a flag that is not observable would then never reach the rail.
    nonisolated(unsafe) static var overrideFull =
        LaunchOptions.parse(CommandLine.arguments).debugMotion == "full"

    /// Effective Reduce Motion: the system's, unless the hook overrides it.
    static func reduce(system: Bool) -> Bool {
        system && !overrideFull
    }
}
