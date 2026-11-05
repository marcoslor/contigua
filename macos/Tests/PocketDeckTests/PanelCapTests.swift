// M2's panel-pixel cap (ISS-40): the panel's native mode, the factor, and the
// capped request the phone answers.

import CoreGraphics
import XCTest
@testable import PocketDeck

final class PanelCapTests: XCTestCase {
    private let modern = EncoderSpec(widthAlign: 2, heightAlign: 2, maxWidth: 8192,
                                     maxHeight: 8192, maxPixelsAt60: 8192 * 8192)

    func testTheNativeFlagWinsOverScaledModes() {
        let modes = [
            DisplayModeSize(pointWidth: 3008, pointHeight: 1692, pixelWidth: 6016,
                            pixelHeight: 3384, isNative: false),
            DisplayModeSize(pointWidth: 3840, pointHeight: 2160, pixelWidth: 3840,
                            pixelHeight: 2160, isNative: true),
            DisplayModeSize(pointWidth: 2560, pointHeight: 1440, pixelWidth: 2560,
                            pixelHeight: 1440, isNative: false),
        ]
        XCTAssertEqual(PanelCap.nativePixelWidth(modes: modes), 3840)
    }

    func testWithoutANativeFlagTheLargestPointModeIsThePanel() {
        // A scaled 3008 pt mode has 6016 px; the panel's own shape is the
        // largest point mode, 3840x2160, and that is the width the panel can
        // really show.
        let modes = [
            DisplayModeSize(pointWidth: 3008, pointHeight: 1692, pixelWidth: 6016,
                            pixelHeight: 3384, isNative: false),
            DisplayModeSize(pointWidth: 3840, pointHeight: 2160, pixelWidth: 3840,
                            pixelHeight: 2160, isNative: false),
        ]
        XCTAssertEqual(PanelCap.nativePixelWidth(modes: modes), 3840)
    }

    func testNoModesHaveNoPanel() {
        XCTAssertNil(PanelCap.nativePixelWidth(modes: []))
    }

    func testTheFactorIsPanelOverBacking() {
        XCTAssertEqual(PanelCap.factor(panelWidth: 3840, backingWidth: 6016),
                       3840.0 / 6016.0, accuracy: 1e-12)
        // The person's main display: 0.638 on each axis.
        XCTAssertEqual(PanelCap.factor(panelWidth: 3840, backingWidth: 6016),
                       0.638, accuracy: 0.001)
    }

    func testAnUnscaledDisplayIsNotCapped() {
        XCTAssertEqual(PanelCap.factor(panelWidth: 1280, backingWidth: 1280), 1)
        XCTAssertEqual(PanelCap.factor(panelWidth: 2560, backingWidth: 2560), 1)
        // A panel narrower than the backing store still caps; a wider one is
        // the display's own pixels and never grows the request.
        XCTAssertEqual(PanelCap.factor(panelWidth: 3840, backingWidth: 2560), 1)
    }

    func testTheCappedRequestForA1203x693Window() {
        let factor = PanelCap.factor(panelWidth: 3840, backingWidth: 6016)
        // 2406x1386 backing pixels x 0.638 = 1535.7x884.7, floored to the
        // encoder's 2 px alignment.
        let request = VideoSize.displayPixels(bounds: CGSize(width: 1203, height: 693),
                                              backingScale: 2, encoder: modern,
                                              panelFactor: factor)
        XCTAssertEqual(request.width, 1534)
        XCTAssertEqual(request.height, 884)
    }

    func testTheCappedRequestWithoutAnEncoderReportFloorsToSixteen() {
        let factor = PanelCap.factor(panelWidth: 3840, backingWidth: 6016)
        let request = VideoSize.displayPixels(bounds: CGSize(width: 1203, height: 693),
                                              backingScale: 2, panelFactor: factor)
        XCTAssertEqual(request.width, 1520)
        XCTAssertEqual(request.height, 880)
    }

    func testTheCappedSizeAnswersTheRequestSoNoFillSticks() {
        let factor = PanelCap.factor(panelWidth: 3840, backingWidth: 6016)
        let request = VideoSize.displayPixels(bounds: CGSize(width: 1203, height: 693),
                                              backingScale: 2, encoder: modern,
                                              panelFactor: factor)
        XCTAssertFalse(Letterbox.resizeStillPending(video: request, request: request,
                                                    liveResizing: false, alignment: 2))
        // The capped picture is the window's shape (within the fill tolerance)
        // but not its backing pixels: it covers the view instead of barring.
        XCTAssertEqual(Letterbox.placement(video: request, bounds: CGSize(width: 1203, height: 693),
                                           backingScale: 2, alignment: 2,
                                           resizePending: false, phoneMode: false), .stretch)
    }

    func testTheFactorOfOneLeavesTheRequestExactlyAsToday() {
        let plain = VideoSize.displayPixels(bounds: CGSize(width: 1203, height: 693),
                                            backingScale: 2, encoder: modern)
        let factored = VideoSize.displayPixels(bounds: CGSize(width: 1203, height: 693),
                                               backingScale: 2, encoder: modern, panelFactor: 1)
        XCTAssertEqual(plain, factored)
        XCTAssertEqual(plain.width, 2406)
        XCTAssertEqual(plain.height, 1386)
    }
}
