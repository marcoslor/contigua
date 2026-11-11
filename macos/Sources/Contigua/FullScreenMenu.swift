// The window's full-screen opt-out.
//
// AppKit places Enter Full Screen last in View and decides its title and
// enablement from the key window itself (MENU-4). The one rule the app shares
// with it and with the e2e's chrome state: a window that opts out with
// .fullScreenNone (the phone window) may not enter native full screen — the
// mirror would be letterboxed or stretched. Every other window may.

import AppKit

@MainActor
enum FullScreenMenu {
    /// Whether `window` may enter native full screen.
    static func allowsFullScreen(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return !window.collectionBehavior.contains(.fullScreenNone)
    }
}
