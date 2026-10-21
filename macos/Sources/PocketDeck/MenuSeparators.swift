// The bar's separators, after SwiftUI has built the menus.
//
// SwiftUI draws a separator on both sides of a command group it places between
// two of its own. In the Window menu — Enter Full Screen between Zoom and Bring
// All to Front — that leaves two in a row, and neither SwiftUI nor AppKit
// offers a way to say "this group takes no separator". This pass removes the
// duplicate and nothing else: it never adds, hides or reorders an item.
//
// It runs once the menu exists and again when the app activates, which is when
// SwiftUI rebuilds the commands, so a rebuild cannot bring the pair back.

import AppKit

@MainActor
enum MenuSeparators {
    private static var observer: NSObjectProtocol?

    static func start() {
        collapse()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { collapse() }
        }
    }

    /// Drops every separator that directly follows another.
    static func collapse() {
        guard let window = NSApp.mainMenu?.items.first(where: { $0.title == "Window" })?.submenu
        else { return }
        var index = window.items.count - 1
        while index > 0 {
            if window.items[index].isSeparatorItem, window.items[index - 1].isSeparatorItem {
                window.removeItem(at: index)
            }
            index -= 1
        }
    }
}
