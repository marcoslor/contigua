// AppKit scroll events -> SCROLL wheel units. AppKit's deltas already follow
// the user's natural-scrolling setting, so the vertical sign must pass through
// untouched; horizontal flips because AXIS_HSCROLL is positive to the right.

import AppKit
import XCTest
@testable import PocketDeck

final class ScrollMappingTests: XCTestCase {

    private func map(_ mapping: inout ScrollMapping, dx: Double = 0, dy: Double = 0, precise: Bool = true,
                     phase: NSEvent.Phase = .changed) -> ScrollMapping.Units? {
        mapping.map(deltaX: dx, deltaY: dy, precise: precise, phase: phase)
    }

    func testTrackpadPointsBecomeWheelUnitsWithTheSignKept() {
        var m = ScrollMapping()
        XCTAssertEqual(map(&m, dy: 64), .init(hscroll: 0, vscroll: 1))
        XCTAssertEqual(map(&m, dy: -32), .init(hscroll: 0, vscroll: -0.5))
    }

    func testHorizontalIsInverted() {
        var m = ScrollMapping()
        XCTAssertEqual(map(&m, dx: 64), .init(hscroll: -1, vscroll: 0))
        XCTAssertEqual(map(&m, dx: -64), .init(hscroll: 1, vscroll: 0))
    }

    func testBothAxesInOneEvent() {
        var m = ScrollMapping()
        XCTAssertEqual(map(&m, dx: 32, dy: -64), .init(hscroll: -0.5, vscroll: -1))
    }

    func testSubPointDeltasAccumulateInsteadOfVanishing() {
        var m = ScrollMapping()
        XCTAssertNil(map(&m, dy: 0.4))
        XCTAssertNil(map(&m, dy: 0.4))
        XCTAssertEqual(map(&m, dy: 0.4), .init(hscroll: 0, vscroll: 1.0 / 64))
        // 1.2 pt went in, 1 pt came out; 0.2 pt is carried.
        XCTAssertNil(map(&m, dy: 0.7), "0.9 pt is still below a point")
        XCTAssertEqual(map(&m, dy: 0.2), .init(hscroll: 0, vscroll: 1.0 / 64))
    }

    func testCarryDoesNotLeakIntoTheNextGesture() {
        var m = ScrollMapping()
        XCTAssertNil(map(&m, dy: 0.9))
        XCTAssertNil(map(&m, dy: 0.5, phase: .began))
    }

    func testMomentumIsPassedThrough() {
        var m = ScrollMapping()
        XCTAssertNotNil(map(&m, dy: 12, phase: []))
        XCTAssertNotNil(map(&m, dy: 6, phase: []))
    }

    func testMouseWheelLinesKeepTheirMagnitudeAndSign() {
        var m = ScrollMapping()
        XCTAssertEqual(map(&m, dy: 1, precise: false, phase: []), .init(hscroll: 0, vscroll: 1))
        XCTAssertEqual(map(&m, dy: -3, precise: false, phase: []), .init(hscroll: 0, vscroll: -3))
        XCTAssertEqual(map(&m, dx: 2, precise: false, phase: []), .init(hscroll: -2, vscroll: 0))
        XCTAssertEqual(map(&m, dy: 40, precise: false, phase: []), .init(hscroll: 0, vscroll: 8))
    }

    func testZeroDeltaSendsNothing() {
        var m = ScrollMapping()
        XCTAssertNil(map(&m))
        XCTAssertNil(map(&m, precise: false, phase: []))
    }

    // MARK: Through the mapper, with real NSEvents

    private func scrollEvent(units: CGScrollEventUnit, dy: Int32, dx: Int32 = 0) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2,
                               wheel1: dy, wheel2: dx, wheel3: 0) else { return nil }
        return NSEvent(cgEvent: cg)
    }

    private func sendScroll(_ event: NSEvent) -> [ScrollEvent] {
        let mapper = InputMapper(stream: 1)
        var sent: [ScrollEvent] = []
        mapper.videoRectProvider = { CGRect(x: 0, y: 0, width: 100, height: 200) }
        mapper.locationProvider = { _ in CGPoint(x: 50, y: 100) }
        mapper.send = { command in if case .scroll(let scroll) = command { sent.append(scroll) } }
        mapper.scrollWheel(event)
        return sent
    }

    func testWheelEventUpIsPositiveVscrollAtTheCursor() throws {
        let event = try XCTUnwrap(scrollEvent(units: .line, dy: 2))
        XCTAssertFalse(event.hasPreciseScrollingDeltas)
        let sent = sendScroll(event)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.vscroll, 2)
        XCTAssertEqual(sent.first?.hscroll, 0)
        XCTAssertEqual(sent.first?.nx, 0.5)
        XCTAssertEqual(sent.first?.ny, 0.5)
    }

    func testPixelEventsAreTreatedAsATrackpad() throws {
        let event = try XCTUnwrap(scrollEvent(units: .pixel, dy: -128, dx: 64))
        XCTAssertTrue(event.hasPreciseScrollingDeltas)
        let sent = sendScroll(event)
        XCTAssertEqual(sent.first?.vscroll, -2)
        XCTAssertEqual(sent.first?.hscroll, -1)
    }
}
