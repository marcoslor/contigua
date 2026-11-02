// The live-resize rule: while the window has asked for a new size and no frame
// at that size has arrived, the last frame fills it (a centred crop) instead of
// letterboxing. The phone window's mirror is never cropped. The drawn rect is
// the same rule the layer uses, so input maps to what is on screen.

import AVFoundation
import XCTest
@testable import PocketDeck

final class VideoFillTests: XCTestCase {
    private let wide = CGSize(width: 1792, height: 1200)
    private let tall = CGSize(width: 1200, height: 2000)

    // MARK: The rule

    func testTallFrameInAWideViewFillsWhileResizeIsPending() {
        let bounds = CGSize(width: 900, height: 400)
        XCTAssertEqual(Letterbox.placement(video: tall, bounds: bounds, resizePending: true, phoneMode: false),
                       .fill)
    }

    func testWideFrameInATallViewFillsWhileResizeIsPending() {
        let bounds = CGSize(width: 400, height: 800)
        XCTAssertEqual(Letterbox.placement(video: wide, bounds: bounds, resizePending: true, phoneMode: false),
                       .fill)
    }

    func testTheQuantisationIsStretchedEvenWhileResizeIsPending() {
        // 1792x1200 in a 900x600 pt view: 4 px short each side, 0.4 % apart.
        XCTAssertEqual(Letterbox.placement(video: wide, bounds: CGSize(width: 900, height: 600),
                                           resizePending: true, phoneMode: false),
                       .stretch)
    }

    func testThePhoneWindowNeverFills() {
        let phone = CGSize(width: 1080, height: 2340)
        let bounds = CGSize(width: 400, height: 700)
        XCTAssertEqual(Letterbox.placement(video: phone, bounds: bounds, resizePending: true, phoneMode: true),
                       .fit)
        XCTAssertEqual(Letterbox.placement(video: phone, bounds: bounds, resizePending: false, phoneMode: true),
                       .fit)
    }

    func testTheTimeoutFallsBackToAspectFit() {
        // The pending flag is gone (2 s after the last ask): today's fit.
        XCTAssertEqual(Letterbox.placement(video: tall, bounds: CGSize(width: 900, height: 400),
                                           resizePending: false, phoneMode: false),
                       .fit)
    }

    func testAnEmptyVideoOrViewIsFit() {
        XCTAssertEqual(Letterbox.placement(video: .zero, bounds: CGSize(width: 900, height: 600),
                                           resizePending: true, phoneMode: false), .fit)
        XCTAssertEqual(Letterbox.placement(video: wide, bounds: .zero,
                                           resizePending: true, phoneMode: false), .fit)
    }

    // MARK: The drawn rect

    func testFillRectIsACentredCropOfTheView() {
        // A tall frame in a wide view: the width matches, the height overflows
        // equally above and below (AppKit's bottom-left origin).
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 400)
        let rect = Letterbox.videoRect(video: tall, in: bounds, placement: .fill)
        XCTAssertEqual(rect.width, 900, accuracy: 0.001)
        XCTAssertEqual(rect.height, 1500, accuracy: 0.001)
        XCTAssertEqual(rect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(rect.midY, bounds.midY, accuracy: 0.001)
        XCTAssertLessThan(rect.minY, bounds.minY)
    }

    func testFillRectOverflowsTheSidesForAWideFrameInATallView() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let rect = Letterbox.videoRect(video: wide, in: bounds, placement: .fill)
        XCTAssertEqual(rect.height, 800, accuracy: 0.001)
        XCTAssertEqual(rect.width, 1194.667, accuracy: 0.01)
        XCTAssertEqual(rect.midX, bounds.midX, accuracy: 0.001)
        XCTAssertLessThan(rect.minX, bounds.minX)
        XCTAssertGreaterThan(rect.maxX, bounds.maxX)
    }

    func testFitRectStaysInsideTheView() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 400)
        let rect = Letterbox.videoRect(video: tall, in: bounds, placement: .fit)
        XCTAssertEqual(rect.height, 400, accuracy: 0.001)
        XCTAssertEqual(rect.width, 240, accuracy: 0.001)
        XCTAssertTrue(bounds.contains(rect))
    }

    func testStretchRectIsTheView() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 600)
        XCTAssertEqual(Letterbox.videoRect(video: wide, in: bounds, placement: .stretch), bounds)
    }

    func testTheLayerGravityMatchesThePlacement() {
        XCTAssertEqual(VideoLayerView.gravity(for: .fit), .resizeAspect)
        XCTAssertEqual(VideoLayerView.gravity(for: .fill), .resizeAspectFill)
        XCTAssertEqual(VideoLayerView.gravity(for: .stretch), .resize)
    }

    // MARK: The config that ends the pending state

    func testAConfigAtTheRequestedSizeAnswersIt() {
        // 900x608 pt at 2x asks for 1792x1216 (floored to 16); the phone's
        // answer may be one step off.
        let request = CGSize(width: 1792, height: 1216)
        XCTAssertTrue(Letterbox.answers(config: CGSize(width: 1792, height: 1200), request: request))
        XCTAssertTrue(Letterbox.answers(config: request, request: request))
    }

    func testWhileResizingAnOldFrameCloseInAspectDoesNotEndTheFill() {
        // 1792x1200 vs a request of 1856x1232: more than one 16 px step on the
        // width, but the aspects agree within the settled tolerance. The
        // settled rule accepts it; a live resize must not (the one letterboxed
        // frame in the zoom, e2e `zoom`).
        let old = CGSize(width: 1792, height: 1200)
        let request = CGSize(width: 1856, height: 1232)
        XCTAssertTrue(Letterbox.answers(config: old, request: request),
                      "the aspect is within the settled tolerance for this request")
        XCTAssertTrue(Letterbox.resizeStillPending(video: old, request: request, liveResizing: true))
        XCTAssertFalse(Letterbox.resizeStillPending(video: old, request: request, liveResizing: false))
    }

    func testWhileResizingAConfigAtTheRequestedSizeEndsTheFill() {
        let request = CGSize(width: 1792, height: 1216)
        XCTAssertFalse(Letterbox.resizeStillPending(video: CGSize(width: 1792, height: 1200), request: request,
                                                    liveResizing: true))
        XCTAssertFalse(Letterbox.resizeStillPending(video: request, request: request, liveResizing: true))
    }

    func testAConfigOfTheOldShapeDoesNotAnswer() {
        XCTAssertFalse(Letterbox.answers(config: wide, request: CGSize(width: 1200, height: 2000)))
        XCTAssertFalse(Letterbox.answers(config: .zero, request: CGSize(width: 1200, height: 2000)))
    }

    // MARK: Input on the crop

    func testACentreClickDuringTheFillIsTheVideoCentre() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let rect = Letterbox.videoRect(video: wide, in: bounds, placement: .fill)
        let mapper = InputMapper(stream: 1)
        mapper.videoRectProvider = { rect }
        let (nx, ny) = mapper.normalized(CGPoint(x: bounds.midX, y: bounds.midY))
        XCTAssertEqual(nx, 0.5, accuracy: 0.0005)
        XCTAssertEqual(ny, 0.5, accuracy: 0.0005)
    }

    func testAClickNearTheEdgeDuringTheFillLandsOnTheCroppedColumn() {
        // The crop shows the middle of the frame: 2 pt in from the view's left
        // edge is not the video's left edge, it is 1/3 of the way across.
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let rect = Letterbox.videoRect(video: wide, in: bounds, placement: .fill)
        let mapper = InputMapper(stream: 1)
        mapper.videoRectProvider = { rect }
        let (nx, ny) = mapper.normalized(CGPoint(x: 2, y: bounds.midY))
        let expectedX = Float((2 - rect.minX) / rect.width)
        XCTAssertEqual(nx, expectedX, accuracy: 0.0005)
        XCTAssertEqual(ny, 0.5, accuracy: 0.0005)
        XCTAssertGreaterThan(nx, 0.3)
        XCTAssertLessThan(nx, 0.34)
    }
}
