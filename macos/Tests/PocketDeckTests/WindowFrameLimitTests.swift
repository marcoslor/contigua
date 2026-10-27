// A window never grows past its screen (WindowFrameLimit.swift, CONV-MAC-12):
// the rule as a value, so K2 tests it without a display.

import AppKit
import XCTest
@testable import PocketDeck

@MainActor
final class WindowFrameLimitTests: XCTestCase {
    private let screen = NSSize(width: 1280, height: 770)

    /// An Accessibility resize 4000 pt tall comes back the screen's height.
    func testAnOversizeSizeIsCutToTheScreen() {
        XCTAssertEqual(WindowFrameLimit.size(NSSize(width: 900, height: 4000),
                                             within: screen, minimum: .zero),
                       NSSize(width: 900, height: 770))
    }

    func testBothAxesAreCut() {
        XCTAssertEqual(WindowFrameLimit.size(NSSize(width: 4000, height: 4000),
                                             within: screen, minimum: .zero), screen)
    }

    /// A size already inside the screen is left exactly as it was.
    func testASizeInsideTheScreenIsUntouched() {
        let proposed = NSSize(width: 900, height: 600)
        XCTAssertEqual(WindowFrameLimit.size(proposed, within: screen, minimum: .zero), proposed)
    }

    /// A window's own minimum is kept, but it still never exceeds the screen.
    func testTheWindowsMinimumIsKeptWithinTheScreen() {
        let small = NSSize(width: 100, height: 100)
        XCTAssertEqual(WindowFrameLimit.size(small, within: screen, minimum: NSSize(width: 320, height: 240)),
                       NSSize(width: 320, height: 240))
        XCTAssertEqual(WindowFrameLimit.size(small, within: NSSize(width: 200, height: 200),
                                             minimum: NSSize(width: 320, height: 240)),
                       NSSize(width: 200, height: 200))
    }

    /// The mirror keeps the phone's shape: the screen's limit scales it.
    func testThePhonesAspectIsKeptWhenItIsCut() {
        let fitted = WindowFrameLimit.aspectFitted(NSSize(width: 1204, height: 2637),
                                                   within: screen, minimum: .zero)
        XCTAssertEqual(fitted.height, 770, accuracy: 0.5)
        XCTAssertEqual(fitted.width / fitted.height, 1204.0 / 2637.0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(fitted.width, screen.width)
    }

    /// The rule never moves a window: only the size changes.
    func testFittingLeavesTheWindowsPlaceAlone() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let proposed = NSRect(x: -40, y: 5000, width: 900, height: 4000)
        let fitted = WindowFrameLimit.fitted(proposed, for: window, screen: NSScreen.screens.first)
        XCTAssertEqual(fitted.origin, proposed.origin)
        XCTAssertLessThanOrEqual(fitted.height, NSScreen.screens.first?.visibleFrame.height ?? 0)
    }

    /// The funnel holds every window a person reaches, and leaves the app's
    /// own picture-sized windows, panels and sheets alone.
    func testTheFunnelAppliesToOrdinaryWindowsOnly() {
        let ordinary = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        XCTAssertTrue(WindowFrameLimit.applies(to: ordinary))

        WindowFrameLimit.owns(ordinary)
        XCTAssertFalse(WindowFrameLimit.applies(to: ordinary),
                       "a stream window sizes itself from the phone's picture")

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                            styleMask: [.titled], backing: .buffered, defer: false)
        XCTAssertFalse(WindowFrameLimit.applies(to: panel))
    }
}
