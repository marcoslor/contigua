// The opening cover's clock (docs/UX.md "Opening a window"): loading, Still
// opening at 5 s, Couldn't open at 20 s, and the first frame ending it. The
// state is pure, so the test pins the edges with a fake clock.

import AppKit
import XCTest
@testable import PocketDeck

final class OpeningCoverTests: XCTestCase {
    func testTheCoverMovesThroughItsPhasesAtFiveAndTwentySeconds() {
        let cover = OpeningCover(startedAt: 100)
        XCTAssertEqual(cover.phase(at: 100), .loading)
        XCTAssertEqual(cover.phase(at: 104.9), .loading)
        XCTAssertEqual(cover.phase(at: 105), .stillLoading)
        XCTAssertEqual(cover.phase(at: 119.9), .stillLoading)
        XCTAssertEqual(cover.phase(at: 120), .failed)
        XCTAssertEqual(cover.phase(at: 400), .failed)
        XCTAssertTrue(cover.isUp)
        XCTAssertFalse(cover.hasFirstFrame)
    }

    func testTheFirstFrameEndsTheCoverForGood() {
        var cover = OpeningCover(startedAt: 0)
        XCTAssertTrue(cover.firstFrame(at: 3))
        XCTAssertTrue(cover.hasFirstFrame)
        XCTAssertFalse(cover.isUp)
        XCTAssertNil(cover.phase(at: 3))
        XCTAssertNil(cover.phase(at: 30), "no failure once the picture is in")
        XCTAssertFalse(cover.firstFrame(at: 4), "the first frame is noted once")
        cover.retry(at: 5)
        XCTAssertNil(cover.phase(at: 6), "a retry after a frame does not bring a cover back")
    }

    func testTryAgainRestartsTheClock() {
        var cover = OpeningCover(startedAt: 0)
        XCTAssertEqual(cover.phase(at: 21), .failed)
        cover.retry(at: 21)
        XCTAssertEqual(cover.phase(at: 21), .loading)
        XCTAssertEqual(cover.phase(at: 26), .stillLoading)
        XCTAssertEqual(cover.phase(at: 41), .failed)
        XCTAssertTrue(cover.isUp)
    }

    func testTheSentencesAreTheDocumentedOnes() {
        XCTAssertEqual(OpeningCover.message(.loading, name: "Chrome", phone: false),
                       "Opening on your phone…")
        XCTAssertEqual(OpeningCover.message(.stillLoading, name: "Chrome", phone: false),
                       "Still opening…")
        XCTAssertEqual(OpeningCover.message(.failed, name: "Chrome", phone: false),
                       "Couldn't open Chrome.")
        XCTAssertEqual(OpeningCover.message(.loading, name: "Pixel", phone: true),
                       "Opening your phone…")
        XCTAssertEqual(OpeningCover.message(.failed, name: "Pixel", phone: true),
                       "Couldn't open your phone.")
    }
}
