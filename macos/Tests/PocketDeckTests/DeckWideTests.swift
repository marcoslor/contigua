// The Deck's standard zoom (DECK-24): a title-bar double-click or the green
// button takes the system's own standard frame — the screen's visible frame —
// and a second zoom returns the frame the window came from. The Deck no longer
// computes a frame from its grid, so the zoom cannot change the icon size.

import AppKit
import XCTest
@testable import PocketDeck

@MainActor
final class DeckWideTests: XCTestCase {
    private let standardFrameSelector =
        #selector(NSWindowDelegate.windowWillUseStandardFrame(_:defaultFrame:))

    /// The Deck's window delegate leaves the standard frame to AppKit: it does
    /// not answer the question itself, so `NSWindow.zoom` uses the system's
    /// standard frame (the screen's visible frame), not a width computed from
    /// the 880 pt grid.
    func testTheDeckLeavesTheStandardZoomToTheSystem() {
        let proxy = DeckWindowDelegate()
        XCTAssertFalse(proxy.responds(to: standardFrameSelector),
                       """
                       the Deck must not answer the standard-frame question: a frame computed from \
                       the grid made a title-bar double-click change the icon size (DECK-24)
                       """)
    }

    /// SwiftUI's delegate keeps every question but the full-screen options:
    /// the proxy forwards a standard frame if SwiftUI ever asks for one, so
    /// AppKit's own zoom stays in charge of the answer.
    func testTheProxyForwardsEveryOtherDelegateQuestion() {
        final class Stub: NSObject, NSWindowDelegate {
            func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
                newFrame
            }
        }
        let stub = Stub()
        let proxy = DeckWindowDelegate()
        proxy.target = stub
        XCTAssertTrue(proxy.responds(to: standardFrameSelector),
                      "a question the proxy does not answer goes to SwiftUI's delegate")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let delegate: NSWindowDelegate = proxy
        let answer = delegate.windowWillUseStandardFrame?(window, defaultFrame: frame)
        XCTAssertEqual(answer, frame, "the forwarded answer is the delegate's own")
    }
}
