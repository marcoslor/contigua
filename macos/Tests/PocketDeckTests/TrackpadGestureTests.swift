// Trackpad -> TOUCH: a phased scroll becomes a one-finger drag, the wheel stays
// SCROLL, raw fingers become pointers around the cursor, and the two paths
// never both reach the phone.

import AppKit
import XCTest
@testable import PocketDeck

final class ScrollDragTests: XCTestCase {
    /// 400 x 800 pt video, cursor in the middle.
    private let space = TrackpadGestures.Space(videoRect: CGRect(x: 0, y: 0, width: 400, height: 800))
    private let cursor = CGPoint(x: 200, y: 400)

    private func scroll(_ gestures: inout TrackpadGestures, _ phase: NSEvent.Phase, dx: Double = 0, dy: Double = 0,
                        momentum: NSEvent.Phase = [], precise: Bool = true) -> TrackpadGestures.Output {
        gestures.scroll(ScrollSample(phase: phase, momentum: momentum, precise: precise, deltaX: dx, deltaY: dy),
                        cursor: cursor, space: space)
    }

    private func touch(_ action: TouchAction, nx: Float, ny: Float, pointer: UInt8 = 0) -> TouchEvent {
        TouchEvent(action: action, pointerId: pointer, nx: nx, ny: ny)
    }

    func testPhasedScrollIsDownMovesUp() {
        var gestures = TrackpadGestures()
        var sent: [TouchEvent] = []
        sent += scroll(&gestures, .began).touches
        sent += scroll(&gestures, .changed, dy: 40).touches
        sent += scroll(&gestures, .changed, dy: 40).touches
        sent += scroll(&gestures, .changed, dy: 40).touches
        sent += scroll(&gestures, .ended).touches
        XCTAssertEqual(sent, [
            touch(.down, nx: 0.5, ny: 0.5),
            touch(.move, nx: 0.5, ny: 0.55),
            touch(.move, nx: 0.5, ny: 0.6),
            touch(.move, nx: 0.5, ny: 0.65),
            touch(.up, nx: 0.5, ny: 0.65),
        ])
    }

    func testEveryScrollEventIsItsOwnMoveWithTheCursorAsDownPoint() {
        var gestures = TrackpadGestures()
        let cursor = CGPoint(x: 100, y: 600)
        var sent = gestures.scroll(ScrollSample(phase: .began), cursor: cursor, space: space).touches
        for _ in 0..<6 {
            sent += gestures.scroll(ScrollSample(phase: .changed, deltaX: 3, deltaY: -5), cursor: cursor, space: space).touches
        }
        XCTAssertEqual(sent.first, touch(.down, nx: 0.25, ny: 0.25))
        XCTAssertEqual(sent.filter { $0.action == .move }.count, 6, "no coalescing: Android needs the cadence")
    }

    func testDirectionFollowsTheDeltasAsAppKitReportsThem() {
        var gestures = TrackpadGestures()
        _ = scroll(&gestures, .began)
        // Positive deltas: the content moves down and to the right, so the finger does.
        let move = scroll(&gestures, .changed, dx: 20, dy: 80).touches
        XCTAssertEqual(move, [touch(.move, nx: 0.55, ny: 0.6)])
        let back = scroll(&gestures, .changed, dx: -20, dy: -80).touches
        XCTAssertEqual(back, [touch(.move, nx: 0.5, ny: 0.5)])
    }

    func testTheLastDeltaOfTheEndedEventPrecedesTheUp() {
        var gestures = TrackpadGestures()
        _ = scroll(&gestures, .began)
        _ = scroll(&gestures, .changed, dy: 60)
        let ended = scroll(&gestures, .ended, dy: 8).touches
        XCTAssertEqual(ended.map(\.action), [.move, .up])
        XCTAssertEqual(ended[0].ny, ended[1].ny, "UP at the last MOVE's position: no jump at the lift")
    }

    func testAPlainEndedIsAnImmediateUp() {
        var gestures = TrackpadGestures()
        _ = scroll(&gestures, .began)
        _ = scroll(&gestures, .changed, dy: 60)
        XCTAssertEqual(scroll(&gestures, .ended).touches, [touch(.up, nx: 0.5, ny: 0.575)])
    }

    func testMomentumIsDroppedBecauseAndroidFlingsByItself() {
        var gestures = TrackpadGestures()
        _ = scroll(&gestures, .began)
        _ = scroll(&gestures, .changed, dy: 60)
        _ = scroll(&gestures, .ended)
        for phase: NSEvent.Phase in [.began, .changed, .changed, .ended] {
            let out = scroll(&gestures, [], dy: 30, momentum: phase)
            XCTAssertEqual(out, TrackpadGestures.Output(), "momentum \(phase) must reach nobody")
        }
    }

    func testWheelStaysAScrollFrame() {
        var gestures = TrackpadGestures()
        XCTAssertEqual(scroll(&gestures, [], dy: 3, precise: false), TrackpadGestures.Output(wheel: true))
        // A smooth-scrolling wheel reports points but has no gesture phase.
        XCTAssertEqual(scroll(&gestures, [], dy: 12, precise: true), TrackpadGestures.Output(wheel: true))
        // Even a wheel that reports a phase is a wheel when its deltas are lines.
        XCTAssertEqual(scroll(&gestures, .changed, dy: 1, precise: false), TrackpadGestures.Output(wheel: true))
    }

    func testAWheelNotchDuringADragDoesNotDisturbIt() {
        var gestures = TrackpadGestures()
        _ = scroll(&gestures, .began)
        _ = scroll(&gestures, .changed, dy: 40)
        XCTAssertTrue(scroll(&gestures, [], dy: 1, precise: false).wheel)
        XCTAssertEqual(scroll(&gestures, .ended).touches.map(\.action), [.up])
    }

    func testChangedWithoutBeganStartsTheDrag() {
        // The edge-swipe classifier hands over a gesture mid-way.
        var gestures = TrackpadGestures()
        let sent = scroll(&gestures, .changed, dy: 30).touches
        XCTAssertEqual(sent.map(\.action), [.down, .move])
    }

    func testADragTooShortToScrollEndsAsCancelNotATap() {
        var gestures = TrackpadGestures()
        _ = scroll(&gestures, .began)
        _ = scroll(&gestures, .changed, dy: 3)
        XCTAssertEqual(scroll(&gestures, .ended).touches.map(\.action), [.cancel])
    }

    func testCancelledPhaseCancels() {
        var gestures = TrackpadGestures()
        _ = scroll(&gestures, .began)
        _ = scroll(&gestures, .changed, dy: 50)
        XCTAssertEqual(scroll(&gestures, .cancelled).touches.map(\.action), [.cancel])
    }

    func testAClickMidGestureCancelsAndTheRestOfThatScrollIsIgnored() {
        var gestures = TrackpadGestures()
        _ = scroll(&gestures, .began)
        _ = scroll(&gestures, .changed, dy: 50)
        XCTAssertEqual(gestures.cancel().map(\.action), [.cancel])
        XCTAssertEqual(scroll(&gestures, .changed, dy: 50), TrackpadGestures.Output(), "no new finger mid-scroll")
        XCTAssertEqual(scroll(&gestures, .ended), TrackpadGestures.Output())
        // The next scroll is a fresh gesture.
        XCTAssertEqual(scroll(&gestures, .began).touches.map(\.action), [.down])
    }

    func testCancelWithNothingGoingOnIsSilent() {
        var gestures = TrackpadGestures()
        XCTAssertEqual(gestures.cancel(), [])
        XCTAssertEqual(scroll(&gestures, .changed, dy: 30).touches.map(\.action), [.down, .move])
    }

    func testTheFingerStopsAtTheVideoEdgeAndComesBackAtOnce() {
        var gestures = TrackpadGestures()
        _ = scroll(&gestures, .began)
        let pinned = scroll(&gestures, .changed, dy: 2000).touches
        XCTAssertEqual(pinned, [touch(.move, nx: 0.5, ny: 1)])
        let back = scroll(&gestures, .changed, dy: -80).touches
        XCTAssertEqual(back, [touch(.move, nx: 0.5, ny: 0.9)], "no dead zone after the clamp")
    }

    func testZeroDeltasMakeNoMoves() {
        var gestures = TrackpadGestures()
        _ = scroll(&gestures, .began)
        XCTAssertEqual(scroll(&gestures, .changed).touches, [])
    }

    func testMayBeginAndStationaryAreIgnored() {
        var gestures = TrackpadGestures()
        XCTAssertEqual(scroll(&gestures, .mayBegin), TrackpadGestures.Output())
        XCTAssertEqual(scroll(&gestures, .stationary), TrackpadGestures.Output())
    }
}

final class TrackpadPinchTests: XCTestCase {
    private let surface = TrackpadSurface.fallback // 160 x 115 mm
    private let space = TrackpadGestures.Space(videoRect: CGRect(x: 0, y: 0, width: 400, height: 800))
    private let cursor = CGPoint(x: 200, y: 400)

    private func fingers(_ a: (Double, Double), _ b: (Double, Double)) -> [TrackpadFinger] {
        [TrackpadFinger(id: 11, x: a.0, y: a.1), TrackpadFinger(id: 12, x: b.0, y: b.1)]
    }

    func testDeviceSizeIsInPointsOfAnInchOver72() {
        let surface = TrackpadSurface(widthPoints: 72, heightPoints: 144)
        let mm = surface.millimetres(TrackpadFinger(id: 1, x: 1, y: 1))
        XCTAssertEqual(mm.x, 25.4, accuracy: 1e-9)
        XCTAssertEqual(mm.y, 50.8, accuracy: 1e-9)
    }

    func testAnUnreportedSurfaceFallsBackToAMagicTrackpad() {
        let surface = TrackpadSurface(widthPoints: 0, heightPoints: 0)
        XCTAssertEqual(surface.millimetres(TrackpadFinger(id: 1, x: 1, y: 1)).x, 160, accuracy: 1e-9)
        XCTAssertEqual(surface.millimetres(TrackpadFinger(id: 1, x: 1, y: 1)).y, 115, accuracy: 1e-9)
    }

    func testPointersAreTheFingersDisplacementAroundTheCursor() throws {
        // Fingers 32 mm apart in the middle of the pad.
        let start = fingers((0.4, 0.5), (0.6, 0.5))
        let pinch = try XCTUnwrap(TrackpadPinch(fingers: start, surface: surface, anchor: cursor))
        let atStart = try XCTUnwrap(pinch.pointers(for: start))
        // 16 mm either side of the centroid: 64 pt at 4 pt/mm.
        XCTAssertEqual(atStart.map(\.id), [0, 1])
        XCTAssertEqual(atStart[0].point.x, 136, accuracy: 1e-6)
        XCTAssertEqual(atStart[1].point.x, 264, accuracy: 1e-6)
        XCTAssertEqual(atStart[0].point.y, 400, accuracy: 1e-6)
    }

    func testSpreadingScalesThePointersAndKeepsTheirCentre() throws {
        let start = fingers((0.4, 0.5), (0.6, 0.5))
        let pinch = try XCTUnwrap(TrackpadPinch(fingers: start, surface: surface, anchor: cursor))
        let spread = try XCTUnwrap(pinch.pointers(for: fingers((0.3, 0.5), (0.7, 0.5))))
        // 64 mm apart: 32 mm either side = 128 pt.
        XCTAssertEqual(spread[0].point.x, 72, accuracy: 1e-6)
        XCTAssertEqual(spread[1].point.x, 328, accuracy: 1e-6)
        XCTAssertEqual((spread[0].point.x + spread[1].point.x) / 2, 200, accuracy: 1e-6)
    }

    func testTranslatingTheFingersPansThePointers() throws {
        let start = fingers((0.4, 0.5), (0.6, 0.5))
        let pinch = try XCTUnwrap(TrackpadPinch(fingers: start, surface: surface, anchor: cursor))
        // Both fingers 10 mm right and 5 mm up.
        let dx = 10 / 160.0, dy = 5 / 115.0
        let moved = try XCTUnwrap(pinch.pointers(for: fingers((0.4 + dx, 0.5 + dy), (0.6 + dx, 0.5 + dy))))
        XCTAssertEqual(moved[0].point.x, 136 + 40, accuracy: 1e-6)
        XCTAssertEqual(moved[0].point.y, 400 + 20, accuracy: 1e-6, "up on the pad is up in the (unflipped) view")
        XCTAssertEqual(moved[1].point.x - moved[0].point.x, 128, accuracy: 1e-6, "span unchanged")
    }

    func testAFlippedViewInvertsTheVerticalAxis() throws {
        let start = fingers((0.5, 0.4), (0.5, 0.6))
        let pinch = try XCTUnwrap(TrackpadPinch(fingers: start, surface: surface, anchor: cursor, flipped: true))
        let points = try XCTUnwrap(pinch.pointers(for: start))
        XCTAssertGreaterThan(points[0].point.y, points[1].point.y)
    }

    func testRotatingKeepsTheSpanAndTurnsThePair() throws {
        let start = fingers((0.4, 0.5), (0.6, 0.5)) // horizontal, 32 mm apart
        let pinch = try XCTUnwrap(TrackpadPinch(fingers: start, surface: surface, anchor: cursor))
        // A quarter turn counter-clockwise on the pad: left finger goes down, right finger up.
        let r = 16.0
        let cx = 0.5, cy = 0.5
        let turned = fingers((cx, cy - r / 115), (cx, cy + r / 115))
        let points = try XCTUnwrap(pinch.pointers(for: turned))
        XCTAssertEqual(points[0].point.x, 200, accuracy: 1e-6)
        XCTAssertEqual(points[0].point.y, 400 - 64, accuracy: 1e-6)
        XCTAssertEqual(points[1].point.y, 400 + 64, accuracy: 1e-6)
        let span = hypot(points[1].point.x - points[0].point.x, points[1].point.y - points[0].point.y)
        XCTAssertEqual(span, 128, accuracy: 1e-6)
    }

    func testOtherFingersAreNotThisGesture() throws {
        let start = fingers((0.4, 0.5), (0.6, 0.5))
        let pinch = try XCTUnwrap(TrackpadPinch(fingers: start, surface: surface, anchor: cursor))
        XCTAssertNil(pinch.pointers(for: [TrackpadFinger(id: 11, x: 0.4, y: 0.5), TrackpadFinger(id: 99, x: 0.6, y: 0.5)]))
        XCTAssertNil(pinch.pointers(for: [start[0]]))
        XCTAssertNil(TrackpadPinch(fingers: [start[0]], surface: surface, anchor: cursor))
    }

    func testPointsPerMillimetreIsTunable() throws {
        let start = fingers((0.4, 0.5), (0.6, 0.5))
        let pinch = try XCTUnwrap(TrackpadPinch(fingers: start, surface: surface, anchor: cursor, pointsPerMillimetre: 2))
        let points = try XCTUnwrap(pinch.pointers(for: start))
        XCTAssertEqual(points[1].point.x - points[0].point.x, 64, accuracy: 1e-6)
    }

    // MARK: Classifier

    func testParallelFingersArePanOppositeFingersArePinchTurningFingersArePinch() {
        var classifier = TwoFingerClassifier()
        let start = fingers((0.4, 0.5), (0.6, 0.5))
        classifier.begin(start, surface: surface)
        XCTAssertEqual(classifier.verdict(fingers((0.4, 0.502), (0.6, 0.502)), surface: surface), .undecided)
        // 5 mm up together.
        XCTAssertEqual(classifier.verdict(fingers((0.4, 0.5 + 5 / 115), (0.6, 0.5 + 5 / 115)), surface: surface), .pan)
        // 3 mm apart each way.
        XCTAssertEqual(classifier.verdict(fingers((0.4 - 3 / 160, 0.5), (0.6 + 3 / 160, 0.5)), surface: surface), .pinch)
        // A quarter turn.
        XCTAssertEqual(classifier.verdict(fingers((0.5, 0.5 - 16 / 115), (0.5, 0.5 + 16 / 115)), surface: surface), .pinch)
    }

    func testOneFingerMovingWhileTheOtherRestsIsAPinchNotAScroll() {
        var classifier = TwoFingerClassifier()
        classifier.begin(fingers((0.4, 0.5), (0.6, 0.5)), surface: surface)
        XCTAssertEqual(classifier.verdict(fingers((0.4, 0.5), (0.6 + 8 / 160, 0.5)), surface: surface), .pinch)
    }

    // MARK: Arbitration

    private func land(_ g: inout TrackpadGestures, _ f: [TrackpadFinger]) -> [TouchEvent] {
        g.fingersChanged(f, surface: surface, cursor: cursor, space: space)
    }

    private func scroll(_ g: inout TrackpadGestures, _ phase: NSEvent.Phase, dx: Double = 0, dy: Double = 0) -> TrackpadGestures.Output {
        g.scroll(ScrollSample(phase: phase, deltaX: dx, deltaY: dy), cursor: cursor, space: space)
    }

    func testPinchGestureIsTwoPointersAndTheScrollEventsAreIgnored() {
        var g = TrackpadGestures()
        let start = fingers((0.4, 0.5), (0.6, 0.5))
        XCTAssertEqual(land(&g, start), [])
        XCTAssertEqual(scroll(&g, .began), TrackpadGestures.Output())
        // Spread 12 mm: a pinch.
        let sent = land(&g, fingers((0.4 - 6 / 160, 0.5), (0.6 + 6 / 160, 0.5)))
        XCTAssertEqual(sent.map(\.action), [.down, .down, .move, .move])
        XCTAssertEqual(sent.map(\.pointerId), [0, 1, 0, 1])
        XCTAssertTrue(g.isPinching)
        // The OS scroll events of the same gesture do not reach the phone.
        XCTAssertEqual(scroll(&g, .changed, dy: 30), TrackpadGestures.Output())
        // The pointers come down where the fingers landed, then jump to where they are.
        XCTAssertEqual(sent[0].nx, (136.0 / 400).f, accuracy: 1e-5)
        XCTAssertEqual(sent[2].nx, (200 - (16 + 6) * 4.0).f / 400, accuracy: 1e-5)
        XCTAssertEqual(sent[3].nx, (200 + (16 + 6) * 4.0).f / 400, accuracy: 1e-5)
        // Further spreading: one MOVE per pointer.
        let more = land(&g, fingers((0.4 - 10 / 160, 0.5), (0.6 + 10 / 160, 0.5)))
        XCTAssertEqual(more.map(\.action), [.move, .move])
        // The same finger positions again change nothing.
        XCTAssertEqual(land(&g, fingers((0.4 - 10 / 160, 0.5), (0.6 + 10 / 160, 0.5))), [])
        // One finger lifts: both pointers go up, highest first.
        let up = land(&g, [TrackpadFinger(id: 11, x: 0.3, y: 0.5)])
        XCTAssertEqual(up.map(\.action), [.up, .up])
        XCTAssertEqual(up.map(\.pointerId), [1, 0])
        // The tail of the OS gesture is ignored until the fingers are off.
        XCTAssertEqual(scroll(&g, .changed, dy: 30), TrackpadGestures.Output())
        _ = land(&g, [])
        XCTAssertEqual(scroll(&g, .began).touches.map(\.action), [.down])
    }

    func testPanGestureHoldsTheScrollThenFlushesOneMove() {
        var g = TrackpadGestures()
        let start = fingers((0.4, 0.5), (0.6, 0.5))
        _ = land(&g, start)
        // Scroll events come before the fingers have travelled far enough to tell.
        XCTAssertEqual(scroll(&g, .began), TrackpadGestures.Output())
        XCTAssertEqual(scroll(&g, .changed, dy: 6), TrackpadGestures.Output())
        XCTAssertEqual(scroll(&g, .changed, dy: 6), TrackpadGestures.Output())
        // The fingers travel 4 mm together: a pan.
        let dy = 4 / 115.0
        let sent = land(&g, fingers((0.4, 0.5 + dy), (0.6, 0.5 + dy)))
        XCTAssertEqual(sent.map(\.action), [.down, .move], "everything held becomes one MOVE")
        XCTAssertEqual(sent[1].ny, 0.5 + 12.0.f / 800, accuracy: 1e-5)
        // From now on the scroll events drive the drag, one MOVE each.
        XCTAssertEqual(scroll(&g, .changed, dy: 10).touches.map(\.action), [.move])
        XCTAssertEqual(scroll(&g, .ended).touches.map(\.action), [.up])
        // The raw fingers of a pan never make pointers.
        XCTAssertEqual(land(&g, fingers((0.4, 0.5 + 3 * dy), (0.6, 0.5 + 3 * dy))), [])
        _ = land(&g, [])
        // A second pan starts clean after the fingers lift.
        _ = land(&g, start)
        XCTAssertEqual(scroll(&g, .began), TrackpadGestures.Output())
    }

    func testAScrollThatEndsBeforeTheFingersCouldBeClassifiedStillScrolls() {
        var g = TrackpadGestures()
        _ = land(&g, fingers((0.4, 0.5), (0.6, 0.5)))
        _ = scroll(&g, .began)
        _ = scroll(&g, .changed, dy: 30)
        let sent = scroll(&g, .ended).touches
        XCTAssertEqual(sent.map(\.action), [.down, .move, .up])
    }

    func testATinyHeldScrollIsDroppedNotATap() {
        var g = TrackpadGestures()
        _ = land(&g, fingers((0.4, 0.5), (0.6, 0.5)))
        _ = scroll(&g, .began)
        _ = scroll(&g, .changed, dy: 2)
        XCTAssertEqual(scroll(&g, .ended), TrackpadGestures.Output())
    }

    func testThreeFingersAreLeftToTheSystem() {
        var g = TrackpadGestures()
        _ = land(&g, fingers((0.4, 0.5), (0.6, 0.5)))
        _ = land(&g, fingers((0.4 - 6 / 160, 0.5), (0.6 + 6 / 160, 0.5)))
        XCTAssertTrue(g.isPinching)
        let third = land(&g, [TrackpadFinger(id: 11, x: 0.3, y: 0.5), TrackpadFinger(id: 12, x: 0.7, y: 0.5),
                              TrackpadFinger(id: 13, x: 0.5, y: 0.5)])
        XCTAssertEqual(third.map(\.action), [.cancel, .cancel], "the pointers are cancelled, not released")
        XCTAssertFalse(g.isPinching)
        // Nothing the three fingers do reaches the phone, scrolls included.
        XCTAssertEqual(scroll(&g, .changed, dy: 50), TrackpadGestures.Output())
        XCTAssertEqual(land(&g, [TrackpadFinger(id: 11, x: 0.3, y: 0.5), TrackpadFinger(id: 12, x: 0.7, y: 0.5)]), [])
        _ = land(&g, [])
        XCTAssertEqual(scroll(&g, .began).touches.map(\.action), [.down])
    }

    func testAWindowThatLosesFocusCancelsThePointers() {
        var g = TrackpadGestures()
        _ = land(&g, fingers((0.4, 0.5), (0.6, 0.5)))
        _ = land(&g, fingers((0.4 - 6 / 160, 0.5), (0.6 + 6 / 160, 0.5)))
        XCTAssertEqual(g.cancel().map(\.action), [.cancel, .cancel])
        XCTAssertEqual(land(&g, fingers((0.4 - 8 / 160, 0.5), (0.6 + 8 / 160, 0.5))), [], "the rest of that gesture is ignored")
    }

    func testWithoutRawFingersScrollGoesStraightToADrag() {
        var g = TrackpadGestures()
        XCTAssertFalse(g.touchesAvailable)
        XCTAssertEqual(scroll(&g, .began).touches.map(\.action), [.down])
    }

    func testMagnifyBelongsToTheFingersOnceTheyAreOnThePad() {
        var g = TrackpadGestures()
        XCTAssertEqual(g.fingerCount, 0)
        _ = land(&g, fingers((0.4, 0.5), (0.6, 0.5)))
        XCTAssertEqual(g.fingerCount, 2)
        // AppKit says pinch before the fingers travelled far: it is a pinch.
        let sent = g.pinchHinted(space: space)
        XCTAssertEqual(sent.map(\.action), [.down, .down])
        XCTAssertTrue(g.isPinching)
    }

    func testAnOverlappingNewLandingDoesNotInheritAnOldPan() {
        var g = TrackpadGestures()
        let start = fingers((0.4, 0.5), (0.6, 0.5))
        _ = land(&g, start)
        _ = land(&g, fingers((0.4, 0.5 + 4 / 115), (0.6, 0.5 + 4 / 115)))
        _ = scroll(&g, .began)
        _ = scroll(&g, .changed, dy: 20)
        _ = scroll(&g, .ended)
        _ = land(&g, [start[0]])
        _ = land(&g, start)
        // Classified again from scratch: a spread now is a pinch.
        let sent = land(&g, fingers((0.4 - 6 / 160, 0.5), (0.6 + 6 / 160, 0.5)))
        XCTAssertEqual(sent.map(\.action), [.down, .down, .move, .move])
    }
}

private extension Double {
    var f: Float { Float(self) }
}
