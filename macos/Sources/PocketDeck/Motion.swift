// The app's effective Reduce Motion (CONV-MAC-22): the system setting, with a
// test-hooks-only override so the e2e VM can prove the fisheye while its
// accessibility preference stays the guest's. One place, so the rail, its ease
// and the fisheye all agree.

import Foundation

enum Motion {
    /// `--debug-motion full` (test hooks only; a release build ignores the
    /// flag, so this stays false there).
    nonisolated(unsafe) static var overrideFull = false

    /// Effective Reduce Motion: the system's, unless the hook overrides it.
    static func reduce(system: Bool) -> Bool {
        system && !overrideFull
    }
}
