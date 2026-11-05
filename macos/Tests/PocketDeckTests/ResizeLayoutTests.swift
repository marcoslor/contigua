// The live-resize phases (WIN-6): a drag, the wait for the phone's answer, and
// one beat of settle after it. The gravity holds fill until the settle ends, so
// the layer never re-lays its contents while WindowServer still shows the drag.

import XCTest
@testable import PocketDeck

final class ResizeLayoutTests: XCTestCase {
    func testAFreshLayoutIsIdleAndFits() {
        let layout = ResizeLayout()
        XCTAssertEqual(layout.phase, .idle)
        XCTAssertFalse(layout.holdsFillGravity)
    }

    func testADragEndsInTheWaitForTheAnswer() {
        var layout = ResizeLayout()
        layout.apply(.dragBegan)
        XCTAssertEqual(layout.phase, .dragging)
        layout.apply(.dragEnded)
        XCTAssertEqual(layout.phase, .awaitingAnswer)
        layout.apply(.answered)
        XCTAssertEqual(layout.phase, .settling)
        layout.apply(.settleElapsed)
        XCTAssertEqual(layout.phase, .idle)
    }

    func testTheFillHoldsFromTheFirstDragEventThroughTheSettle() {
        var layout = ResizeLayout()
        XCTAssertFalse(layout.holdsFillGravity)
        layout.apply(.dragBegan)
        XCTAssertTrue(layout.holdsFillGravity)
        layout.apply(.dragEnded)
        XCTAssertTrue(layout.holdsFillGravity)
        layout.apply(.answered)
        XCTAssertTrue(layout.holdsFillGravity)
        layout.apply(.settleElapsed)
        XCTAssertFalse(layout.holdsFillGravity)
    }

    func testATimeoutDuringTheWaitFallsBackToFit() {
        var layout = ResizeLayout()
        layout.apply(.dragBegan)
        layout.apply(.dragEnded)
        layout.apply(.timedOut)
        XCTAssertEqual(layout.phase, .idle)
        XCTAssertFalse(layout.holdsFillGravity)
    }

    func testASecondDragDuringTheSettleHoldsTheFillAgain() {
        var layout = ResizeLayout()
        layout.apply(.dragBegan)
        layout.apply(.dragEnded)
        layout.apply(.answered)
        layout.apply(.dragBegan)
        XCTAssertEqual(layout.phase, .dragging)
        XCTAssertTrue(layout.holdsFillGravity)
    }

    func testAnAnswerToAnOldRequestDuringADragIsIgnored() {
        var layout = ResizeLayout()
        layout.apply(.dragBegan)
        layout.apply(.answered)
        XCTAssertEqual(layout.phase, .dragging)
    }

    func testADragEndDuringTheSettleKeepsTheSettleRunning() {
        var layout = ResizeLayout()
        layout.apply(.dragBegan)
        layout.apply(.dragEnded)
        layout.apply(.answered)
        layout.apply(.dragEnded)
        XCTAssertEqual(layout.phase, .settling)
        layout.apply(.settleElapsed)
        XCTAssertEqual(layout.phase, .idle)
    }

    func testAnEarlySettleTickLeavesTheWaitAlone() {
        var layout = ResizeLayout()
        layout.apply(.dragBegan)
        layout.apply(.dragEnded)
        layout.apply(.settleElapsed)
        XCTAssertEqual(layout.phase, .awaitingAnswer)
        layout.apply(.answered)
        XCTAssertEqual(layout.phase, .settling)
    }
}
