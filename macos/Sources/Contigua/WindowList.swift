// The Window menu's list of open windows.
//
// SwiftUI marks the windows it creates — the Deck and Settings — as excluded
// from the Window menu (`isExcludedFromWindowsMenu`), so the list AppKit adds
// below "Bring All to Front" was empty: the person saw the separator that
// introduces the list as an empty row, and no way to reach the Deck from the
// Window menu. Clearing the flag is all AppKit needs: its own window list then
// names the window, the standard way (CONV-MAC-13).
//
// This adds no item and moves none: it only lets AppKit list what is open.

import AppKit

@MainActor
enum WindowListMenu {
    /// Whether `window` is one of the app's own (the Deck, Settings). A stream
    /// window is a plain NSWindow and AppKit already lists it.
    static func isOwn(_ window: NSWindow) -> Bool {
        let id = window.identifier?.rawValue ?? ""
        return id.hasPrefix(DeckWindow.id) || id == "settings" || id == "com_apple_SwiftUI_Settings_window"
    }

    /// Let AppKit list the window. False when it was already listable, so the
    /// caller can tell whether the menu changed.
    @discardableResult
    static func include(_ window: NSWindow?) -> Bool {
        guard let window, isOwn(window), window.isExcludedFromWindowsMenu else { return false }
        window.isExcludedFromWindowsMenu = false
        return true
    }

    /// Every open window of the app that should be listed.
    static func includeAppWindows() {
        for window in NSApp.windows { include(window) }
    }

    private static var observers: [NSObjectProtocol] = []

    /// Follows windows as they appear and re-checks before the menu opens; the
    /// flag is read by AppKit while it builds the list.
    static func start() {
        includeAppWindows()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { note in
                MainActor.assumeIsolated { _ = include(note.object as? NSWindow) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { includeAppWindows() }
        })
    }
}
