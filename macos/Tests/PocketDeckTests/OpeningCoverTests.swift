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
        XCTAssertEqual(OpeningCover.message(.unavailable, name: "Pixel", phone: true),
                       "This phone can't share its screen with PocketDeck.")
    }

    /// The phone's `error{mirror_unavailable}` is one sentence with Close only:
    /// the cover is terminal, the 20 s failure never takes it over, and Try
    /// Again cannot ask the phone a second time (MIRROR-2, misses.md M2).
    /// The refusal's sentence is whole at the phone window's width, and Close
    /// alone is centred: the first capture cut it at "PocketDec" and put the
    /// button in the window's corner.
    @MainActor
    func testTheRefusalSentenceWrapsAndCloseIsCentred() {
        let view = OpeningCoverView(frame: NSRect(x: 0, y: 0, width: 353, height: 793))
        view.show(.unavailable, name: "Pixel 9", icon: nil, phone: true)
        view.layout()
        XCTAssertEqual(view.messageText, "This phone can't share its screen with PocketDeck.")
        XCTAssertGreaterThan(view.messageFrame.height, 20,
                             "the sentence wraps instead of being clipped at the window's edge")
        XCTAssertLessThanOrEqual(view.messageFrame.maxX, view.bounds.width - 20,
                                 "the sentence stays inside the window")
        XCTAssertEqual(view.visibleButtonFrames.count, 1, "Close only")
        XCTAssertEqual(view.visibleButtonFrames[0].midX, view.bounds.width / 2, accuracy: 1,
                       "Close is centred")
        XCTAssertGreaterThan(view.visibleButtonFrames[0].minY, 0, "the button sits inside the cover")
        XCTAssertLessThan(view.visibleButtonFrames[0].maxY, view.bounds.height)
        // The 20 s failure keeps both buttons and lays them out together.
        view.show(.failed, name: "Pixel 9", icon: nil, phone: true)
        view.layout()
        XCTAssertEqual(view.visibleButtonFrames.count, 2)
        let frames = view.visibleButtonFrames
        XCTAssertEqual((frames[0].minX + frames[1].maxX) / 2, view.bounds.width / 2, accuracy: 1,
                       "Try Again and Close are centred as one row")
    }

    func testARefusedOpenIsOneSentenceWithCloseOnly() {
        var cover = OpeningCover(startedAt: 0)
        XCTAssertTrue(cover.canRetry)
        XCTAssertTrue(cover.refuse(.mirrorUnavailable))
        XCTAssertEqual(cover.phase(at: 1), .unavailable)
        XCTAssertEqual(cover.phase(at: 60), .unavailable, "no 20 s failure after a refusal")
        XCTAssertFalse(cover.canRetry, "a refused open has no Try Again")
        cover.retry(at: 30)
        XCTAssertEqual(cover.phase(at: 31), .unavailable, "a retry cannot restart a refusal")
        XCTAssertFalse(cover.refuse(.mirrorUnavailable), "a refusal is noted once")
    }

    /// The mapping is the wire code and nothing else: a launch failure stays the
    /// generic failure with Try Again.
    func testOnlyTheMirrorRefusalMapsToTheSentence() {
        XCTAssertEqual(OpeningCover.Refusal(errorCode: "mirror_unavailable"), .mirrorUnavailable)
        XCTAssertNil(OpeningCover.Refusal(errorCode: "launch_failed"))
        XCTAssertNil(OpeningCover.Refusal(errorCode: "bad_request"))
        // A code with no mapping leaves the cover on its clock.
        let cover = OpeningCover(startedAt: 0)
        XCTAssertNil(cover.refusal)
        XCTAssertEqual(cover.phase(at: 21), .failed)
        XCTAssertTrue(cover.canRetry)
    }
}
