// The Settings sidebar takes the keyboard when the window opens: ↑/↓ move
// between the source list's rows, and Tab leaves it for the detail
// (docs/specs/settings.md, SET-WIN-08). SwiftUI's List is an NSTableView inside
// the split view's first column; AppKit is used only to hand it the focus a
// person's click would give it, so a window opened by ⌘, is navigable at once.

import AppKit

@MainActor
enum SettingsSidebarFocus {

    /// Make the sidebar's table the window's first responder.
    @discardableResult
    static func take(in window: NSWindow) -> Bool {
        guard let content = window.contentView,
              let table = firstTable(in: content),
              table.window === window else { return false }
        return window.makeFirstResponder(table)
    }

    /// The source list is the left column: the first table whose left edge is
    /// in the sidebar's width, so the detail's tables are never taken.
    private static func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView {
            let frame = table.convert(table.bounds, to: nil)
            if frame.minX < SettingsLayout.sidebarWidth + 40 { return table }
        }
        for child in view.subviews {
            if let found = firstTable(in: child) { return found }
        }
        return nil
    }
}
