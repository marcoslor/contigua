// The opening cover's machine (docs/UX.md "Opening a window", the L1 design):
// opening -> slow at 5 s -> failed at 20 s, the first frame ending it, the
// phone's refusal failing it at once, and Cancel closing the window. The
// transition is pure, so every edge is pinned with a fake clock.

import AppKit
import XCTest
@testable import PocketDeck

final class OpeningCoverTests: XCTestCase {
    private func transition(_ state: OpeningCover.State, _ event: OpeningCover.Event,
                            startedAt: TimeInterval = 100, now: TimeInterval = 100)
        -> (OpeningCover.State, [OpeningCover.Action]) {
        OpeningCover.transition(state, event, startedAt: startedAt, now: now)
    }

    func testTheCoverMovesThroughItsPhasesAtFiveAndTwentySeconds() {
        let cover = OpeningCover(startedAt: 100)
        XCTAssertEqual(cover.phase(at: 100), .opening)
        XCTAssertEqual(cover.phase(at: 104.9), .opening)
        XCTAssertEqual(cover.phase(at: 105), .slow)
        XCTAssertEqual(cover.phase(at: 119.9), .slow)
        XCTAssertEqual(cover.phase(at: 120), .failed(reason: nil))
        XCTAssertEqual(cover.phase(at: 400), .failed(reason: nil))
        XCTAssertTrue(cover.isUp)
    }

    func testTheFirstFrameEndsTheCoverForGoodAndIsNotedOnce() {
        var cover = OpeningCover(startedAt: 0)
        XCTAssertEqual(cover.handle(.firstFrame, at: 3), [])
        XCTAssertEqual(cover.phase(at: 3), nil)
        XCTAssertNil(cover.handle(.firstFrame, at: 4), "the first frame is noted once")
        XCTAssertNil(cover.phase(at: 30), "no failure once the picture is in")
        XCTAssertNil(cover.handle(.refused("app_disabled"), at: 5), "a refusal cannot reopen a live cover")
        XCTAssertNil(cover.handle(.cancel, at: 6), "Cancel does nothing once the picture is in")
    }

    func testALateFirstFrameEndsTheFailure() {
        var cover = OpeningCover(startedAt: 0)
        XCTAssertEqual(cover.phase(at: 21), .failed(reason: nil))
        XCTAssertEqual(cover.handle(.firstFrame, at: 22), [])
        XCTAssertNil(cover.phase(at: 22), "the phone can still produce the picture after the 20 s mark")
    }

    func testARefusalFailsTheCoverAtOnceWithItsReason() {
        var cover = OpeningCover(startedAt: 0)
        XCTAssertEqual(cover.handle(.refused("app_disabled"), at: 2), [])
        XCTAssertEqual(cover.phase(at: 2), .failed(reason: "The app is disabled on the phone."))
        XCTAssertEqual(cover.phase(at: 60), cover.phase(at: 2),
                       "the refusal stands; the 20 s clock never takes it over")
        XCTAssertNil(cover.handle(.refused("app_missing"), at: 3), "the first refusal is the one shown")
        XCTAssertEqual(cover.phase(at: 3), .failed(reason: "The app is disabled on the phone."))
    }

    func testRefusedCodesMapToTheirReasonLine() {
        XCTAssertEqual(OpeningCover.reason(for: "app_disabled"), "The app is disabled on the phone.")
        XCTAssertEqual(OpeningCover.reason(for: "app_missing"), "The app isn't installed any more.")
        XCTAssertEqual(OpeningCover.reason(for: "not_installed"), "The app isn't installed any more.")
        XCTAssertEqual(OpeningCover.reason(for: "mirror_unavailable"),
                       "This phone can't share its screen with PocketDeck.")
        XCTAssertNil(OpeningCover.reason(for: "launch_failed"))
        XCTAssertNil(OpeningCover.reason(for: "bad_request"))
        XCTAssertNil(OpeningCover.reason(for: "something_new"))
    }

    func testAnUnknownCodeFailsWithoutAReasonLine() {
        var cover = OpeningCover(startedAt: 0)
        cover.handle(.refused("something_new"), at: 1)
        XCTAssertEqual(cover.phase(at: 1), .failed(reason: nil))
    }

    func testCancelClosesTheWindowFromOpeningOrSlowOnly() {
        for state in [OpeningCover.State.opening, .slow] {
            let (next, actions) = transition(state, .cancel)
            XCTAssertEqual(next, .closed)
            XCTAssertEqual(actions, [.closeWindow])
        }
        XCTAssertEqual(transition(.failed(reason: nil), .cancel).1, [], "a failed cover offers Close only")
        XCTAssertEqual(transition(.live, .cancel).1, [], "a live window has no cover to cancel")
    }

    func testIgnoredEventsLeaveTheStateAlone() {
        // A tick after the failure, and a tick in the opening state under 5 s.
        XCTAssertEqual(transition(.failed(reason: nil), .tick(30)).0, .failed(reason: nil))
        XCTAssertEqual(transition(.opening, .tick(1)).0, .opening)
        XCTAssertEqual(transition(.slow, .tick(6)).1, [])
        // A refusal with no state to move.
        XCTAssertEqual(transition(.live, .refused("app_missing")).0, .live)
        XCTAssertEqual(transition(.closed, .tick(1)).0, .closed)
        XCTAssertEqual(transition(.closed, .firstFrame).0, .closed)
        // handle() reports an ignored event as nil, so nothing is logged.
        var cover = OpeningCover(startedAt: 0)
        XCTAssertEqual(cover.handle(.cancel, at: 1), [.closeWindow])
        XCTAssertNil(cover.handle(.cancel, at: 2), "the second Cancel is ignored in .closed")
    }

    func testTheTitlesAndSentencesAreTheDocumentedOnes() {
        XCTAssertEqual(OpeningCover.title(name: "Chrome", phone: "Pixel 9", phoneMode: false),
                       "Chrome — opening on Pixel 9")
        XCTAssertEqual(OpeningCover.title(name: "Pixel 9", phone: "Pixel 9", phoneMode: true),
                       "Phone — opening on Pixel 9")
        XCTAssertEqual(OpeningCover.title(name: "Chrome", phone: "", phoneMode: false),
                       "Chrome — opening on your phone")
        XCTAssertEqual(OpeningCover.lead(name: "Chrome", phone: "Pixel 9", phoneMode: false),
                       "Pixel 9 can't open Chrome.")
        XCTAssertEqual(OpeningCover.lead(name: "Pixel 9", phone: "Pixel 9", phoneMode: true),
                       "Pixel 9 can't open the phone screen.")
    }

    func testTheDisplayFollowsThePhase() {
        let opening = OpeningCover.display(.opening, name: "Chrome", phone: "Pixel 9", phoneMode: false)
        XCTAssertEqual(opening?.secondary, nil)
        XCTAssertEqual(opening?.showsCancel, false)
        XCTAssertEqual(opening?.showsClose, false)
        let slow = OpeningCover.display(.slow, name: "Chrome", phone: "Pixel 9", phoneMode: false)
        XCTAssertEqual(slow?.secondary, "Taking longer than usual")
        XCTAssertEqual(slow?.showsCancel, true)
        let failed = OpeningCover.display(.failed(reason: "The app is disabled on the phone."),
                                          name: "Chrome", phone: "Pixel 9", phoneMode: false)
        XCTAssertEqual(failed?.lead, "Pixel 9 can't open Chrome.")
        XCTAssertEqual(failed?.reason, "The app is disabled on the phone.")
        XCTAssertEqual(failed?.showsClose, true)
        XCTAssertEqual(failed?.showsCancel, false)
        XCTAssertNil(OpeningCover.display(nil, name: "Chrome", phone: "Pixel 9", phoneMode: false))
    }

    /// The failure's sentence is whole at the phone window's width, and Close
    /// alone is centred; the slow phase shows one Cancel and no Close.
    @MainActor
    func testTheFailureAndSlowLayoutsPutTheirButtonsWhereTheDesignDoes() {
        let view = OpeningCoverView(frame: NSRect(x: 0, y: 0, width: 353, height: 793))
        let failed = OpeningCover.display(.failed(reason: "This phone can't share its screen with PocketDeck."),
                                          name: "Pixel 9", phone: "Pixel 9", phoneMode: true)
        view.show(failed, icon: nil)
        view.layout()
        XCTAssertEqual(view.messageText, "Pixel 9 can't open the phone screen.")
        XCTAssertEqual(view.displayedReason, "This phone can't share its screen with PocketDeck.")
        XCTAssertGreaterThan(view.messageFrame.height, 15,
                             "the sentence wraps instead of being clipped at the window's edge")
        XCTAssertLessThanOrEqual(view.messageFrame.maxX, view.bounds.width - 20,
                                 "the sentence stays inside the window")
        XCTAssertEqual(view.visibleButtonFrames.count, 1, "Close only")
        XCTAssertEqual(view.visibleButtonFrames[0].midX, view.bounds.width / 2, accuracy: 1,
                       "Close is centred")
        XCTAssertGreaterThan(view.visibleButtonFrames[0].minY, 0, "the button sits inside the cover")
        XCTAssertLessThan(view.visibleButtonFrames[0].maxY, view.bounds.height)

        let slow = OpeningCover.display(.slow, name: "Pixel 9", phone: "Pixel 9", phoneMode: true)
        view.show(slow, icon: nil)
        view.layout()
        XCTAssertEqual(view.displayedSecondary, "Taking longer than usual")
        XCTAssertEqual(view.visibleButtonFrames.count, 1, "Cancel alone")
        XCTAssertEqual(view.visibleButtonFrames[0].midX, view.bounds.width / 2, accuracy: 1)
        XCTAssertEqual(view.sweepFrame.height, 2, "the accent line is 2 pt")
        XCTAssertEqual(view.sweepFrame.maxY, view.bounds.height, "the line sits under the title bar")
    }

    /// The opening phase has no buttons at all: the person waits, or the phone
    /// answers.
    @MainActor
    func testTheOpeningPhaseHasNoButtons() {
        let view = OpeningCoverView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        view.show(OpeningCover.display(.opening, name: "Chrome", phone: "Pixel 9", phoneMode: false), icon: nil)
        view.layout()
        XCTAssertEqual(view.displayedTitle, "Chrome — opening on Pixel 9")
        XCTAssertTrue(view.visibleButtonFrames.isEmpty)
        XCTAssertTrue(view.displayedSecondary.isEmpty)
        XCTAssertTrue(view.displayedReason.isEmpty)
    }
}
