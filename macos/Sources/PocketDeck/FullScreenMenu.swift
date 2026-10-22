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
    private static var observer: NSObjectProtocol?

    /// Whether `window` may enter native full screen.
    static func allowsFullScreen(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return !window.collectionBehavior.contains(.fullScreenNone)
    }

    /// The Window menu's item follows whichever window is key. A stream window
    /// publishes from its own key callbacks; this covers the rest — the Deck
    /// after a stream window closed, and a window that closed while key, which
    /// would otherwise leave the last stream window's answer behind.
    static func start() {
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            // The window the notification names, not NSApp.keyWindow: at this
            // moment the app's own idea of the key window may still be the old
            // one (or nil), which would disable the item for no reason.
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                let state = StreamMenuState.shared
                state.fullScreen = window.styleMask.contains(.fullScreen)
                state.fullScreenAllowed = allowsFullScreen(window)
            }
        }
    }
}
