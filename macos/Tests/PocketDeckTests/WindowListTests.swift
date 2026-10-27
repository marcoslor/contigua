// The Window menu's list (WindowList.swift): SwiftUI's windows are excluded
// from it by default, which left the list empty and its separator an empty row.
// The rule is the window's identifier; the side effect only clears AppKit's flag.

import AppKit
import XCTest
@testable import PocketDeck

@MainActor
final class WindowListTests: XCTestCase {
    private func window(identifier: String?) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.identifier = identifier.map { NSUserInterfaceItemIdentifier($0) }
        return window
    }

    func testTheDecksAndSettingsWindowsAreTheAppsOwn() {
        XCTAssertTrue(WindowListMenu.isOwn(window(identifier: DeckWindow.id)))
        XCTAssertTrue(WindowListMenu.isOwn(window(identifier: "settings")))
        XCTAssertTrue(WindowListMenu.isOwn(window(identifier: "com_apple_SwiftUI_Settings_window")))
        XCTAssertFalse(WindowListMenu.isOwn(window(identifier: "stream-1")))
        XCTAssertFalse(WindowListMenu.isOwn(window(identifier: nil)))
    }

    /// Clearing the flag is what makes AppKit list the window; a stream window
    /// AppKit already lists is left alone.
    func testIncludingClearsTheExclusionOnlyForTheAppsOwnWindows() {
        let deck = window(identifier: DeckWindow.id)
        deck.isExcludedFromWindowsMenu = true
        XCTAssertTrue(WindowListMenu.include(deck))
        XCTAssertFalse(deck.isExcludedFromWindowsMenu)
        XCTAssertFalse(WindowListMenu.include(deck), "nothing left to do the second time")

        let stream = window(identifier: nil)
        XCTAssertFalse(WindowListMenu.include(stream))
    }
}
