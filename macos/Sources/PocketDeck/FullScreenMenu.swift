// The Window menu's full-screen rule.
//
// Enter Full Screen is a SwiftUI command item (MenuBar.swift) with ⌃⌘F; this
// is the one rule it shares with the window controllers and the e2e's chrome
// state: a window that opts out with .fullScreenNone (the phone window) may
// not enter native full screen — the mirror would be letterboxed or stretched.
// Every other stream window may.

import AppKit

@MainActor
enum FullScreenMenu {
    /// Whether `window` may enter native full screen.
    static func allowsFullScreen(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return !window.collectionBehavior.contains(.fullScreenNone)
    }
}
