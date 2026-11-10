// The wide Deck's standard zoom (DECK-24): a title-bar double-click or the
// green button takes the window to the Deck's intrinsic width — the 880 pt grid
// at the person's zoom, 60 pt a side at that zoom, and the rail's 44 pt — and
// the screen's visible height, never wider than the screen.

import AppKit
import XCTest
@testable import PocketDeck

final class DeckWideTests: XCTestCase {

    /// At 100 / 125 / 150 % the intrinsic width is today's 1000 pt window
    /// (880 pt of grid and 60 pt a side) scaled by the zoom, plus the rail.
    func testTheStandardFrameIsTheGridsIntrinsicWidthAtEachZoom() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        let expected: [(zoom: CGFloat, width: CGFloat)] = [(1, 1044), (1.25, 1294), (1.5, 1544)]
        for (zoom, width) in expected {
            XCTAssertEqual(DeckWide.preferredWidth(zoom: zoom), width, accuracy: 0.001, "zoom \(zoom)")
            let frame = DeckWide.standardFrame(visible: screen,
                                               preferredWidth: DeckWide.preferredWidth(zoom: zoom))
            XCTAssertEqual(frame.width, width, accuracy: 0.001, "zoom \(zoom)")
            XCTAssertEqual(frame.height, screen.height, "the screen's visible height")
            XCTAssertEqual(frame.midX, screen.midX, accuracy: 0.001, "centred on the screen")
            XCTAssertEqual(frame.minY, screen.minY, "standing on the visible frame")
            // The grid at that width still fits beside the rail.
            let metrics = DeckGridSize(zoom: zoom)
            let block = DeckWide.block(width: frame.width, metrics: metrics)
            XCTAssertGreaterThanOrEqual(block.originX, 0, "zoom \(zoom)")
            XCTAssertLessThanOrEqual(block.railLeading + DeckWide.railWidth, frame.width + 0.001,
                                     "zoom \(zoom)")
        }
    }

    /// A screen narrower than the intrinsic width keeps its own width, and the
    /// smallest supported screen still gets the whole intrinsic width.
    func testTheStandardFrameNeverExceedsTheScreen() {
        let small = CGRect(x: 100, y: 40, width: 800, height: 600)
        let frame = DeckWide.standardFrame(visible: small,
                                           preferredWidth: DeckWide.preferredWidth(zoom: 1.5))
        XCTAssertEqual(frame.width, small.width, "a narrower screen keeps its own width")
        XCTAssertEqual(frame.minX, small.minX)
        XCTAssertEqual(frame.height, small.height)
        XCTAssertEqual(frame.minY, small.minY)

        let smallest = CGRect(x: 0, y: 0, width: 1280, height: 775)
        let normal = DeckWide.standardFrame(visible: smallest,
                                            preferredWidth: DeckWide.preferredWidth(zoom: 1))
        XCTAssertEqual(normal.width, 1044, "1280 pt holds the intrinsic width at 100 %")
        XCTAssertLessThanOrEqual(normal.width, smallest.width)
    }

    /// DECK-24, pinned 2026-11-10 before the standard-zoom change: the window
    /// delegate answers the standard-frame question with the Deck's intrinsic
    /// frame, which is what a title-bar double-click and the green button take
    /// today. The change to the system's own zoom fails this test first.
    @MainActor
    func testTheZoomDelegateAnswersTheDecksIntrinsicFrameToday() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let proxy = DeckZoomDelegate()
        proxy.preferredWidth = { DeckWide.preferredWidth(zoom: 1) }
        let selector = #selector(NSWindowDelegate.windowWillUseStandardFrame(_:defaultFrame:))
        XCTAssertTrue(proxy.responds(to: selector),
                      "today the Deck answers the standard frame with its own intrinsic width")
        let answer = proxy.windowWillUseStandardFrame(
            window, defaultFrame: CGRect(x: 0, y: 0, width: 1200, height: 900))
        // An unattached window has no screen: the delegate answers for the
        // main screen, the same one the window would open on.
        let visible = NSScreen.main?.visibleFrame ?? .zero
        XCTAssertEqual(answer.width, 1044, accuracy: 0.001)
        XCTAssertEqual(answer.height, visible.height)
        XCTAssertEqual(answer.minY, visible.minY)
        XCTAssertEqual(DeckWide.standardFrame(visible: visible,
                                              preferredWidth: DeckWide.preferredWidth(zoom: 1)),
                       answer)
    }
}
