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

    // MARK: One video pixel per screen pixel (ISS-39)

    func testTheStreamsOwnPixelsAreDrawnOneToOne() {
        // 1800 x 1200 px is exactly a 900 x 600 pt view at 2x.
        XCTAssertEqual(Letterbox.placement(video: CGSize(width: 1800, height: 1200),
                                           bounds: CGSize(width: 900, height: 600),
                                           backingScale: 2, alignment: 2,
                                           resizePending: false, phoneMode: false),
                       .oneToOne)
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 600)
        XCTAssertEqual(Letterbox.videoRect(video: CGSize(width: 1800, height: 1200), in: bounds,
                                           placement: .oneToOne, backingScale: 2),
                       bounds)
    }

    func testOnePixelShortIsDrawnOneToOneWithATrailingStrip() {
        // An odd 1x window: 1203 x 857 px cannot be all shown at an even
        // alignment. The 1202 x 856 the phone sends sits at the top left; the
        // 1 px strip stays window background on the right and bottom.
        XCTAssertEqual(Letterbox.placement(video: CGSize(width: 1202, height: 856),
                                           bounds: CGSize(width: 1203, height: 857),
                                           backingScale: 1, alignment: 2,
                                           resizePending: false, phoneMode: false),
                       .oneToOne)
        let bounds = CGRect(x: 0, y: 0, width: 1203, height: 857)
        let rect = Letterbox.videoRect(video: CGSize(width: 1202, height: 856), in: bounds,
                                       placement: .oneToOne, backingScale: 1)
        XCTAssertEqual(rect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 857, accuracy: 0.001, "anchored to the top-left")
        XCTAssertEqual(rect.width, 1202, accuracy: 0.001)
        XCTAssertEqual(rect.height, 856, accuracy: 0.001)
    }

    func testAnOldFrameDuringAResizeIsStillFilled() {
        // 1792x1200 in a 900x600 pt view at 1x: far from the view, and a resize
        // is in flight, so it keeps covering the window (WIN-42).
        XCTAssertEqual(Letterbox.placement(video: wide, bounds: CGSize(width: 900, height: 600),
                                           resizePending: true, phoneMode: false),
                       .fill)
    }

    func testAFrameUnderTheWindowsPixelsBecauseOfTheCapIsScaled() {
        // The window is 3000 px wide but the encoder caps the stream at 2560
        // with the aspect kept: it is scaled over the whole view, no bars.
        XCTAssertEqual(Letterbox.placement(video: CGSize(width: 2560, height: 853),
                                           bounds: CGSize(width: 3000, height: 1000),
                                           backingScale: 1, alignment: 2,
                                           resizePending: false, phoneMode: false),
                       .stretch)
    }

    /// The person's report (2026-11-04, real phone): a 1680 x 1022 pt window at
    /// 2x asked for 3360 x 2044 px and the phone answered 3360 x 2032 (rounded
    /// to 16). The settled frame was aspect-fitted, so black bands showed above
    /// and below it. A frame of nearly the view's shape covers the view.
    func testASettledFrameAFewPixelsShortCoversTheWindowWithNoBars() {
        let video = CGSize(width: 3360, height: 2032)
        let bounds = CGRect(x: 0, y: 0, width: 1680, height: 1022)
        let placement = Letterbox.placement(video: video, bounds: bounds.size,
                                            backingScale: 2, alignment: 2,
                                            resizePending: false, phoneMode: false)
        XCTAssertEqual(placement, .stretch)
        XCTAssertEqual(Letterbox.videoRect(video: video, in: bounds, backingScale: 2, alignment: 2),
                       bounds, "no band anywhere: the picture covers the whole view")
    }

    /// The 1:1 strip is at most one pixel: an encoder with a coarser step (4,
    /// 8 or 16 px) covers the view instead of leaving a visible band.
    func testACoarseEncoderStepCoversTheWindowRatherThanLeavingABand() {
        XCTAssertEqual(Letterbox.placement(video: CGSize(width: 1796, height: 1196),
                                           bounds: CGSize(width: 900, height: 600),
                                           backingScale: 2, alignment: 4,
                                           resizePending: false, phoneMode: false),
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

    /// ISS-65: the person saw a black line at the mirror's edge in the glass
    /// style on an even/odd window width. The window's stream area is snapped
    /// to whole points, so at 2x its aspect is up to half a pixel off the
    /// phone's; a phone-mode fit of that mismatch leaves that row or column
    /// unfilled. For every width from the minimum to 600 pt, in both styles,
    /// the picture drawn must leave no uncovered half pixel.
    func testThePhoneMirrorsPictureCoversEveryWidthAtTwoX() {
        let phone = CGSize(width: 1080, height: 2340)
        var width: CGFloat = 240
        while width <= 600 {
            for style in WindowStyle.allCases {
                let window = PhoneChrome.frame(proposed: CGSize(width: width, height: 754),
                                               phone: phone, style: style, edge: .left)
                let area = style.streamSize(window: window)
                // The phone's mirror frame is the window's box floored to
                // 16 px; its picture is the screen fitted into it, at whole
                // pixels (WindowStream's mirror content rect).
                let box = VideoSize.displayPixels(bounds: area, backingScale: 2)
                let scale = min(box.width / phone.width, box.height / phone.height)
                let picture = CGSize(width: (phone.width * scale).rounded(),
                                     height: (phone.height * scale).rounded())
                let bounds = CGRect(origin: .zero, size: area)
                let placement = Letterbox.placement(video: picture, bounds: area, backingScale: 2,
                                                    resizePending: false, phoneMode: true)
                let rect = Letterbox.videoRect(video: picture, in: bounds, placement: placement,
                                               backingScale: 2)
                let uncovered = [rect.minX - bounds.minX, bounds.maxX - rect.maxX,
                                 rect.minY - bounds.minY, bounds.maxY - rect.maxY]
                    .map { max(0, $0) * 2 }
                XCTAssertLessThanOrEqual(uncovered.max() ?? 0, 0.5,
                    "\(style.rawValue) at \(width) pt: the picture leaves \(uncovered) px uncovered")
            }
            width += 0.5
        }
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

    func testOneToOneRectKeepsWholeBackingPixels() {
        let bounds = CGRect(x: 0.4, y: 0, width: 900, height: 600)
        let rect = Letterbox.videoRect(video: CGSize(width: 1800, height: 1200), in: bounds,
                                       placement: .oneToOne, backingScale: 2)
        // Every edge is on a device pixel: 0.4 pt is 0.8 px and snaps.
        XCTAssertEqual(rect.minX * 2, (rect.minX * 2).rounded(), accuracy: 0.0001)
        XCTAssertEqual(rect.width, 900, accuracy: 0.001)
        XCTAssertEqual(rect.height, 600, accuracy: 0.001)
    }

    func testTheLayerGravityMatchesThePlacement() {
        XCTAssertEqual(VideoLayerView.gravity(for: .fit), .resizeAspect)
        XCTAssertEqual(VideoLayerView.gravity(for: .fill), .resizeAspectFill)
        XCTAssertEqual(VideoLayerView.gravity(for: .oneToOne), .resize)
        XCTAssertEqual(VideoLayerView.gravity(for: .stretch), .resize)
    }

    // MARK: The live-resize hold (WIN-6)

    func testTheFillGravityHoldsOverAnExactlySizedPicture() {
        // The drag and the phone's answer are both done; if the settled
        // one-to-one gravity took over now, the layer would re-lay its
        // contents while WindowServer still shows the last drag frame.
        XCTAssertEqual(VideoLayerView.drawnPlacement(.oneToOne, holdsFill: true), .fill)
        XCTAssertEqual(VideoLayerView.drawnPlacement(.stretch, holdsFill: true), .fill)
        // A letterbox is never turned into a crop by the hold.
        XCTAssertEqual(VideoLayerView.drawnPlacement(.fit, holdsFill: true), .fit)
        XCTAssertEqual(VideoLayerView.drawnPlacement(.fill, holdsFill: true), .fill)
        // The hold ends: the settled picture is the one the rules define.
        XCTAssertEqual(VideoLayerView.drawnPlacement(.oneToOne, holdsFill: false), .oneToOne)
        XCTAssertEqual(VideoLayerView.drawnPlacement(.stretch, holdsFill: false), .stretch)
    }

    func testAClickDuringTheSettleFollowsTheHeldFill() {
        // A settled stretch frame one encoder step short of the view: the hold
        // crops its sides. The drawn rect must be that crop, so a click 1 pt in
        // from the window edge is not the video's left edge.
        let video = CGSize(width: 3360, height: 2032)
        let bounds = CGRect(x: 0, y: 0, width: 1680, height: 1022)
        let held = VideoLayerView.drawnPlacement(.stretch, holdsFill: true)
        XCTAssertEqual(held, .fill)
        let rect = Letterbox.videoRect(video: video, in: bounds, placement: held,
                                       backingScale: 2)
        XCTAssertEqual(rect.height, bounds.height, accuracy: 0.001)
        XCTAssertLessThan(rect.minX, bounds.minX, "the hold crops the sides")
        XCTAssertGreaterThan(rect.maxX, bounds.maxX)
        let mapper = InputMapper(stream: 1)
        mapper.videoRectProvider = { rect }
        let (nx, _) = mapper.normalized(CGPoint(x: bounds.minX + 1, y: bounds.midY))
        let expectedX = Float((1 - rect.minX) / rect.width)
        XCTAssertEqual(nx, expectedX, accuracy: 0.0005)
        XCTAssertGreaterThan(nx, 0.001, "1 pt is inside the cropped picture, not its edge")
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
