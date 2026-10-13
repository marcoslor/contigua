// Trackpad pinch/rotate -> TOUCH: the pointer geometry (span, rotation
// direction, clamping) and the exact down/move/up sequence the mapper emits.

import AppKit
import XCTest
@testable import PocketDeck

final class PointerGestureTests: XCTestCase {

    private let square = CGSize(width: 1000, height: 1000)
    private let portrait = CGSize(width: 1000, height: 2000)
    private let landscape = CGSize(width: 2000, height: 1000)

    private func gesture(_ video: CGSize, nx: Double = 0.5, ny: Double = 0.5) -> PointerGesture {
        PointerGesture(anchorNx: nx, anchorNy: ny, videoSize: video)
    }

    private func distance(_ gesture: PointerGesture) -> Double {
        let points = gesture.points
        return hypot(Double(points.zero.nx - points.one.nx), Double(points.zero.ny - points.one.ny))
    }

    private func assertPoint(_ point: (nx: Float, ny: Float), _ nx: Double, _ ny: Double,
                             accuracy: Double = 1e-5, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Double(point.nx), nx, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(Double(point.ny), ny, accuracy: accuracy, file: file, line: line)
    }

    private func assertPoint(_ event: TouchEvent, _ nx: Double, _ ny: Double,
                             accuracy: Double = 1e-5, file: StaticString = #filePath, line: UInt = #line) {
        assertPoint((event.nx, event.ny), nx, ny, accuracy: accuracy, file: file, line: line)
    }

    // MARK: Geometry

    func testStartsOnTheShorterAxisHalfASpanOfAnEighthOfThatSide() {
        for video in [square, portrait] {
            let points = gesture(video).points
            assertPoint(points.zero, 0.58, 0.5)
            assertPoint(points.one, 0.42, 0.5)
        }
        let wide = gesture(landscape)
        assertPoint(wide.points.zero, 0.5, 0.58)
        assertPoint(wide.points.one, 0.5, 0.42)
        XCTAssertEqual(distance(wide), 0.16, accuracy: 1e-5)
    }

    func testSpanScalesByTheAccumulatedMagnification() {
        var pinch = gesture(square)
        pinch.add(magnification: 0.25)
        pinch.add(magnification: 0.25)
        assertPoint(pinch.points.zero, 0.62, 0.5)
        assertPoint(pinch.points.one, 0.38, 0.5)
        XCTAssertEqual(distance(pinch), 0.24, accuracy: 1e-6)
    }

    func testPinchInShrinksTheSpan() {
        var pinch = gesture(square)
        pinch.add(magnification: -0.4)
        assertPoint(pinch.points.zero, 0.548, 0.5)
        assertPoint(pinch.points.one, 0.452, 0.5)
        XCTAssertEqual(distance(pinch), 0.096, accuracy: 1e-6)
    }

    func testCounterClockwiseRotationTurnsPointerZeroUpOnScreen() {
        var turn = gesture(square)
        turn.add(rotation: 90)
        assertPoint(turn.points.zero, 0.5, 0.42)
        assertPoint(turn.points.one, 0.5, 0.58)
    }

    func testClockwiseRotationTurnsPointerZeroDownOnScreen() {
        var turn = gesture(square)
        turn.add(rotation: -90)
        assertPoint(turn.points.zero, 0.5, 0.58)
        assertPoint(turn.points.one, 0.5, 0.42)
    }

    func testRotationKeepsTheSpanAndTheAnchor() {
        var turn = gesture(square)
        turn.add(rotation: 33)
        XCTAssertEqual(distance(turn), 0.16, accuracy: 1e-6)
        let points = turn.points
        XCTAssertEqual(Double(points.zero.nx + points.one.nx) / 2, 0.5, accuracy: 1e-6)
        XCTAssertEqual(Double(points.zero.ny + points.one.ny) / 2, 0.5, accuracy: 1e-6)
        // 33 degrees counter-clockwise moves pointer 0 up and to the left.
        XCTAssertLessThan(points.zero.ny, 0.5)
        XCTAssertLessThan(points.zero.nx, 0.58)
        XCTAssertGreaterThan(points.zero.nx, 0.5)
    }

    func testLandscapeStartsVerticalAndRotatesTheSameWay() {
        var turn = gesture(landscape)
        turn.add(rotation: 90)
        // The span is a length on the shorter side, so in a 2:1 video the same
        // 160 px pair reads as 0.08 of nx once it lies on the long axis.
        assertPoint(turn.points.zero, 0.54, 0.5)
        assertPoint(turn.points.one, 0.46, 0.5)
    }

    func testMagnificationAndRotationCombine() {
        var both = gesture(square)
        both.add(magnification: 1.0)
        both.add(rotation: 90)
        assertPoint(both.points.zero, 0.5, 0.34)
        assertPoint(both.points.one, 0.5, 0.66)
        XCTAssertEqual(distance(both), 0.32, accuracy: 1e-6)
    }

    func testPointsClampToTheVideoEdges() {
        var corner = gesture(square, nx: 0.97, ny: 0.97)
        corner.add(magnification: 5)
        assertPoint(corner.points.zero, 1, 0.97)
        assertPoint(corner.points.one, 0.49, 0.97)

        var opposite = gesture(square, nx: 0.03, ny: 0.03)
        opposite.add(magnification: 5)
        opposite.add(rotation: -45)
        assertPoint(opposite.points.zero, 0.3694, 0.3694, accuracy: 1e-4)
        assertPoint(opposite.points.one, 0, 0)

        var diagonal = gesture(square, nx: 0.97, ny: 0.97)
        diagonal.add(magnification: 5)
        diagonal.add(rotation: 45)
        assertPoint(diagonal.points.zero, 1, 0.6306, accuracy: 1e-4)
        assertPoint(diagonal.points.one, 0.6306, 1, accuracy: 1e-4)
    }

    // MARK: Mapper

    private final class Recorder {
        var events: [TouchEvent] = []
        var scheduledMoves: [() -> Void] = []
        var scheduledTaps: [() -> Void] = []
    }

    private let center = CGPoint(x: 50, y: 50)

    private func mapper(video: CGSize = CGSize(width: 1000, height: 1000)) -> (InputMapper, Recorder) {
        let mapper = InputMapper(stream: 1)
        let record = Recorder()
        mapper.videoSizeProvider = { video }
        mapper.videoRectProvider = { CGRect(x: 0, y: 0, width: 100, height: 100) }
        mapper.scheduleGestureMove = { record.scheduledMoves.append($0) }
        mapper.scheduleSecondTap = { record.scheduledTaps.append($0) }
        mapper.send = { command in
            guard case .touch(let event) = command else { return }
            record.events.append(event)
        }
        return (mapper, record)
    }

    func testDownDownMoveMoveUpUpInOrder() {
        let (mapper, record) = mapper()
        mapper.magnify(phase: .began, magnification: 0, at: center)
        mapper.magnify(phase: .changed, magnification: 0.25, at: center)
        mapper.magnify(phase: .changed, magnification: 0.25, at: center)
        mapper.magnify(phase: .ended, magnification: 0, at: center)

        XCTAssertEqual(record.events.map(\.action), [.down, .down, .move, .move, .up, .up])
        XCTAssertEqual(record.events.map(\.pointerId), [0, 1, 0, 1, 1, 0])
        XCTAssertEqual(record.scheduledMoves.count, 1)
        assertPoint(record.events[2], 0.62, 0.5) // move(0) at the final geometry
        assertPoint(record.events[3], 0.38, 0.5) // move(1)
        assertPoint(record.events[4], 0.38, 0.5) // up(1) first
        assertPoint(record.events[5], 0.62, 0.5) // then up(0)
    }

    func testMovesCoalesceToOnePerDisplayRefresh() {
        let (mapper, record) = mapper()
        mapper.magnify(phase: .began, magnification: 0, at: center)
        mapper.magnify(phase: .changed, magnification: 0.1, at: center)
        mapper.magnify(phase: .changed, magnification: 0.1, at: center)
        mapper.magnify(phase: .changed, magnification: 0.1, at: center)

        XCTAssertEqual(record.events.map(\.action), [.down, .down])
        XCTAssertEqual(record.scheduledMoves.count, 1)
        record.scheduledMoves.removeFirst()() // the display refresh arrives
        XCTAssertEqual(record.events.map(\.action), [.down, .down, .move, .move])
        assertPoint(record.events[2], 0.604, 0.5) // all three deltas, one move
        assertPoint(record.events[3], 0.396, 0.5)

        mapper.magnify(phase: .changed, magnification: 0.1, at: center)
        XCTAssertEqual(record.events.count, 4, "no second move inside the same refresh")
        XCTAssertEqual(record.scheduledMoves.count, 1)
    }

    func testCancelledGestureSendsCancelByPointerOneThenZero() {
        let (mapper, record) = mapper()
        mapper.rotate(phase: .began, rotation: 0, at: center)
        mapper.rotate(phase: .changed, rotation: 30, at: center)
        mapper.rotate(phase: .cancelled, rotation: 0, at: center)

        XCTAssertEqual(record.events.map(\.action), [.down, .down, .move, .move, .cancel, .cancel])
        XCTAssertEqual(record.events.map(\.pointerId), [0, 1, 0, 1, 1, 0])
    }

    func testGestureIsIgnoredWhileAMouseButtonIsDown() {
        let (mapper, record) = mapper()
        mapper.mouseButtonIsDown = { true }
        mapper.magnify(phase: .began, magnification: 0, at: center)
        mapper.magnify(phase: .changed, magnification: 0.5, at: center)
        mapper.magnify(phase: .ended, magnification: 0, at: center)
        mapper.rotate(phase: .began, rotation: 0, at: center)
        mapper.rotate(phase: .ended, rotation: 0, at: center)
        XCTAssertTrue(record.events.isEmpty)
        XCTAssertTrue(record.scheduledMoves.isEmpty)
    }

    func testChangedWithoutBeganIsIgnored() {
        let (mapper, record) = mapper()
        mapper.magnify(phase: .changed, magnification: 0.5, at: center)
        mapper.magnify(phase: .ended, magnification: 0, at: center)
        XCTAssertTrue(record.events.isEmpty)
    }

    func testPinchAndRotateShareOnePointerPair() {
        let (mapper, record) = mapper()
        mapper.magnify(phase: .began, magnification: 0, at: center)
        mapper.rotate(phase: .began, rotation: 0, at: center)
        XCTAssertEqual(record.events.map(\.action), [.down, .down], "no second pair for rotate")

        mapper.magnify(phase: .changed, magnification: 1.0, at: center)
        mapper.rotate(phase: .changed, rotation: 90, at: center)
        mapper.magnify(phase: .ended, magnification: 0, at: center)
        XCTAssertEqual(record.events.count, 2, "the gesture continues while rotate is active")

        mapper.rotate(phase: .ended, rotation: 0, at: center)
        XCTAssertEqual(record.events.map(\.action), [.down, .down, .move, .move, .up, .up])
        assertPoint(record.events[2], 0.5, 0.34) // pointer 0: up, and out to 0.16
        assertPoint(record.events[3], 0.5, 0.66)
    }

    func testGestureAnchorIsTheNormalizedCursor() {
        let (mapper, record) = mapper()
        mapper.magnify(phase: .began, magnification: 0, at: CGPoint(x: 50, y: 75))
        XCTAssertEqual(record.events.count, 2)
        assertPoint((record.events[0].nx, record.events[0].ny), 0.58, 0.25)
        assertPoint((record.events[1].nx, record.events[1].ny), 0.42, 0.25)
    }

    func testLandscapeVideoStartsThePairVertical() {
        let (mapper, record) = mapper(video: landscape)
        mapper.rotate(phase: .began, rotation: 0, at: center)
        assertPoint((record.events[0].nx, record.events[0].ny), 0.5, 0.58)
        assertPoint((record.events[1].nx, record.events[1].ny), 0.5, 0.42)
    }

    func testSmartMagnifySendsADoubleTapAtTheCursor() {
        let (mapper, record) = mapper()
        mapper.smartMagnify(at: center)
        XCTAssertEqual(record.events.map(\.action), [.down, .up])
        XCTAssertEqual(record.scheduledTaps.count, 1)
        record.scheduledTaps.removeFirst()() // the second tap a moment later
        XCTAssertEqual(record.events.map(\.action), [.down, .up, .down, .up])
        for event in record.events {
            XCTAssertEqual(event.pointerId, 0)
            XCTAssertEqual(event.nx, 0.5)
            XCTAssertEqual(event.ny, 0.5)
        }
    }
}
