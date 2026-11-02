import AppKit
import XCTest
@testable import PocketDeck

final class WindowZoomTests: XCTestCase {
    private let original = NSRect(x: 120, y: 140, width: 900, height: 628)
    private let standard = NSRect(x: 0, y: 0, width: 1440, height: 870)

    func testTheFirstZoomGoesToTheStandardFrameAndKeepsTheFrameItCameFrom() {
        let (state, target) = WindowZoom.onZoom(.normal, frame: original, standard: standard)
        XCTAssertEqual(state, .zoomed(from: original, to: standard))
        XCTAssertEqual(target, standard)
    }

    func testTheSecondZoomReturnsToTheFrameBeforeTheFirst() {
        let (zoomed, _) = WindowZoom.onZoom(.normal, frame: original, standard: standard)
        let (state, target) = WindowZoom.onZoom(zoomed, frame: standard, standard: standard)
        XCTAssertEqual(state, .normal)
        XCTAssertEqual(target, original)
    }

    func testTheToggleIsStableAcrossRounds() {
        var state = WindowZoom.State.normal
        var frame = original
        for round in 0..<3 {
            let (zoomedState, zoomedFrame) = WindowZoom.onZoom(state, frame: frame, standard: standard)
            XCTAssertEqual(zoomedFrame, standard, "round \(round) in")
            let (normalState, normalFrame) = WindowZoom.onZoom(zoomedState, frame: zoomedFrame,
                                                               standard: standard)
            XCTAssertEqual(normalFrame, original, "round \(round) out")
            state = normalState
            frame = normalFrame
        }
        XCTAssertEqual(state, .normal)
    }

    func testAWindowThePersonResizedWhileZoomedZoomsToTheStandardFrameAgain() {
        // As AppKit's zoom: the person drags the zoomed window smaller, and
        // the next zoom fills the screen again, keeping the dragged frame.
        let (zoomed, _) = WindowZoom.onZoom(.normal, frame: original, standard: standard)
        let resized = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let (state, target) = WindowZoom.onZoom(zoomed, frame: resized, standard: standard)
        XCTAssertEqual(state, .zoomed(from: resized, to: standard))
        XCTAssertEqual(target, standard)
    }

    func testAZoomThatSettledOffTheStandardFrameStillReturns() {
        // The window's size rules rounded the standard frame: the frame it
        // settled at is the zoomed one.
        let (zoomed, _) = WindowZoom.onZoom(.normal, frame: original, standard: standard)
        let rounded = NSRect(x: 0, y: 0, width: 1440, height: 864)
        let settled = WindowZoom.settled(zoomed, at: rounded)
        let (state, target) = WindowZoom.onZoom(settled, frame: rounded, standard: standard)
        XCTAssertEqual(state, .normal)
        XCTAssertEqual(target, original)
    }
}
