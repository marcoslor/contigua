// The Window menu's full-screen item (FullScreenMenu.swift): the standard Fn
// (🌐) shortcut, the title and symbol by state, and AppKit's own view of the
// shortcut (the accessibility attributes are what the menu draws).

import AppKit
import XCTest
@testable import PocketDeck

final class WindowFullScreenItemTests: XCTestCase {
    func testItCarriesTheStandardFnShortcut() {
        let item = WindowFullScreenItem()
        XCTAssertEqual(item.title, "Enter Full Screen")
        XCTAssertEqual(item.keyEquivalent, "f")
        XCTAssertTrue(item.keyEquivalentModifierMask.contains(.function))

        // The menu draws what AppKit's accessibility layer reports: the same
        // modifiers as the system's own full-screen item (24 = Fn, no other).
        XCTAssertEqual(item.accessibilityAttributeValue(.init(rawValue: "AXMenuItemCmdChar")) as? String, "F")
        XCTAssertEqual(item.accessibilityAttributeValue(.init(rawValue: "AXMenuItemCmdModifiers")) as? Int, 24)
    }

    /// The phone window opts out with .fullScreenNone; every other window may.
    @MainActor
    func testOnlyAWindowThatHasNotOptedOutMayGoFullScreen() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        XCTAssertTrue(FullScreenMenu.allowsFullScreen(window))
        window.collectionBehavior = [.fullScreenNone]
        XCTAssertFalse(FullScreenMenu.allowsFullScreen(window))
        XCTAssertFalse(FullScreenMenu.allowsFullScreen(nil))
    }

    func testTheTitleAndSymbolFollowTheKeyWindowsState() {
        let item = WindowFullScreenItem()
        XCTAssertNotNil(item.image)
        item.setState(fullScreen: true)
        XCTAssertEqual(item.title, "Exit Full Screen")
        XCTAssertNotNil(item.image)
        item.setState(fullScreen: false)
        XCTAssertEqual(item.title, "Enter Full Screen")
        XCTAssertNotNil(item.image)
    }
}
