// The Window menu's full-screen rule (FullScreenMenu.swift): a window that
// opts out with .fullScreenNone may not enter native full screen.

import AppKit
import XCTest
@testable import PocketDeck

final class FullScreenMenuTests: XCTestCase {
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
}
