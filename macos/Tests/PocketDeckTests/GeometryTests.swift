import XCTest
@testable import PocketDeck

final class GeometryTests: XCTestCase {

    // MARK: Virtual-display size

    func testDisplayPixelsFloorToMultipleOfSixteen() {
        let size = VideoSize.displayPixels(bounds: CGSize(width: 900, height: 600), backingScale: 2)
        XCTAssertEqual(size.width, 1792) // 1800 floored to 1792
        XCTAssertEqual(size.height, 1200)
    }

    func testDisplayPixelsScaleWithBackingScale() {
        let size = VideoSize.displayPixels(bounds: CGSize(width: 900, height: 600), backingScale: 1)
        XCTAssertEqual(size.width, 896)
        XCTAssertEqual(size.height, 592)
    }

    func testDisplayPixelsClampToMinimum() {
        let size = VideoSize.displayPixels(bounds: CGSize(width: 100, height: 100), backingScale: 2)
        XCTAssertEqual(size.width, 320)
        XCTAssertEqual(size.height, 320)
    }

    func testDisplayPixelsClampToMaximum() {
        // 4000x3600 would exceed the cap: both axes scale by 0.64, keeping 10:9.
        let size = VideoSize.displayPixels(bounds: CGSize(width: 2000, height: 1800), backingScale: 2)
        XCTAssertEqual(size.width, 2560)
        XCTAssertEqual(size.height, 2304)
    }

    func testDisplayPixelsKeepAspectWhenCapped() {
        // Ultra-wide window: 3200x1000 -> 2560x800 (3.2:1, the window's shape).
        let wide = VideoSize.displayPixels(bounds: CGSize(width: 1600, height: 500), backingScale: 2)
        XCTAssertEqual(wide.width, 2560)
        XCTAssertEqual(wide.height, 800)
        // Tall window stays tall and is not re-shaped by the cap.
        let tall = VideoSize.displayPixels(bounds: CGSize(width: 600, height: 1000), backingScale: 2)
        XCTAssertEqual(tall.width, 1200)
        XCTAssertEqual(tall.height, 2000)
    }

    func testDisplayPixelsClampedValuesStayOnGrid() {
        for width in stride(from: 1.0, through: 3000.0, by: 37.0) {
            let size = VideoSize.displayPixels(bounds: CGSize(width: width, height: width), backingScale: 2)
            XCTAssertEqual(Int(size.width) % 16, 0)
            XCTAssertEqual(Int(size.height) % 16, 0)
            XCTAssertTrue(size.width >= 320 && size.width <= 2560)
        }
    }

    // MARK: The encoder's own limits (ISS-39)

    private let modern = EncoderSpec(widthAlign: 2, heightAlign: 2, maxWidth: 8192, maxHeight: 8192,
                                     maxPixelsAt60: 8192 * 8192)

    func testTheExactWindowPixelsAreAskedForWithAModernEncoder() {
        // 1203 x 693 pt at 2x is 2406 x 1386 px: neither is a multiple of 16,
        // both are even, so a 2 px alignment keeps the window's own pixels.
        let size = VideoSize.displayPixels(bounds: CGSize(width: 1203, height: 693),
                                           backingScale: 2, encoder: modern)
        XCTAssertEqual(size.width, 2406)
        XCTAssertEqual(size.height, 1386)
    }

    func testAnOddBackingSizeRoundsDownToTheEncodersAlignment() {
        // 1x: an odd window's pixels cannot all be shown at an even alignment;
        // the phone gets the even size below it and the Mac leaves the strip.
        let size = VideoSize.displayPixels(bounds: CGSize(width: 1203, height: 857),
                                           backingScale: 1, encoder: modern)
        XCTAssertEqual(size.width, 1202)
        XCTAssertEqual(size.height, 856)
    }

    func testTheReportedCapsScaleTheWindowDownKeepingItsAspect() {
        let spec = EncoderSpec(widthAlign: 2, heightAlign: 2, maxWidth: 2560, maxHeight: 1440,
                               maxPixelsAt60: 2560 * 1440)
        // 3000 x 1000 pt at 2x: the width ceiling scales it by 2560/6000.
        let wide = VideoSize.displayPixels(bounds: CGSize(width: 3000, height: 1000),
                                           backingScale: 2, encoder: spec)
        XCTAssertEqual(wide.width, 2560)
        XCTAssertEqual(wide.height, 852)
    }

    func testTheSixtyFpsPixelCountCapsASquareWindow() {
        let spec = EncoderSpec(widthAlign: 2, heightAlign: 2, maxWidth: 8192, maxHeight: 8192,
                               maxPixelsAt60: 4_000_000)
        let size = VideoSize.displayPixels(bounds: CGSize(width: 3000, height: 3000),
                                           backingScale: 2, encoder: spec)
        XCTAssertLessThanOrEqual(Int(size.width * size.height), 4_000_000)
        XCTAssertEqual(Int(size.width) % 2, 0)
        XCTAssertEqual(Int(size.height) % 2, 0)
        XCTAssertEqual(size.width, size.height, "the aspect is kept")
    }

    func testAPhoneWithoutTheReportKeepsTheSixteenAnd2560Rule() {
        let size = VideoSize.displayPixels(bounds: CGSize(width: 2000, height: 1800),
                                           backingScale: 2, encoder: nil)
        XCTAssertEqual(size.width, 2560)
        XCTAssertEqual(size.height, 2304)
    }

    func testTheDPIOfAnExactTwoXWindowKeepsTheAppsDPSize() {
        let bounds = CGSize(width: 900, height: 600)
        let pixels = VideoSize.displayPixels(bounds: bounds, backingScale: 2, encoder: modern)
        XCTAssertEqual(pixels.width, 1800)
        let dpi = VideoSize.dpi(pixels: pixels, bounds: bounds, density: 1.0)
        XCTAssertEqual(dpi, 320)
        // dp = px / (dpi / 160): the app lays out for the window's own points.
        XCTAssertEqual(Double(pixels.width) / (dpi / 160), 900, accuracy: 0.001)
        // The old floor-to-16 rule kept the same dp width with a lower dpi.
        let oldPixels = VideoSize.displayPixels(bounds: bounds, backingScale: 2, encoder: nil)
        let oldDpi = VideoSize.dpi(pixels: oldPixels, bounds: bounds, density: 1.0)
        XCTAssertEqual(Double(oldPixels.width) / (oldDpi / 160), 900, accuracy: 0.001)
    }

    func testTheWelcomeReportParsesAndAMissingOneIsNil() {
        let spec = EncoderSpec(json: ["widthAlign": 2, "heightAlign": 4, "maxWidth": 4096,
                                      "maxHeight": 2160, "maxPixels60": 8_294_400])
        XCTAssertEqual(spec?.widthAlign, 2)
        XCTAssertEqual(spec?.heightAlign, 4)
        XCTAssertEqual(spec?.maxWidth, 4096)
        XCTAssertEqual(spec?.maxHeight, 2160)
        XCTAssertEqual(spec?.maxPixelsAt60, 8_294_400)
        XCTAssertNil(EncoderSpec(json: nil))
        XCTAssertNil(EncoderSpec(json: ["widthAlign": 2]), "a partial report is no report")
    }

    // MARK: dpi

    func testDPIFormula() {
        let bounds = CGSize(width: 900, height: 600)
        XCTAssertEqual(VideoSize.dpi(pixels: CGSize(width: 1800, height: 1200), bounds: bounds, density: 1.0), 320)
        XCTAssertEqual(VideoSize.dpi(pixels: CGSize(width: 1800, height: 1200), bounds: bounds, density: 1.5), 480)
        XCTAssertEqual(VideoSize.dpi(pixels: CGSize(width: 1800, height: 1200), bounds: bounds, density: 0.75), 240)
        XCTAssertEqual(VideoSize.dpi(pixels: CGSize(width: 900, height: 600), bounds: bounds, density: 1.0), 160)
    }

    func testDPIFollowsACappedPixelSize() {
        let bounds = CGSize(width: 1600, height: 500)
        let pixels = VideoSize.displayPixels(bounds: bounds, backingScale: 2)
        XCTAssertEqual(VideoSize.dpi(pixels: pixels, bounds: bounds, density: 1.0), 256, accuracy: 0.01)
    }

    // MARK: Letterboxing

    func testVideoRectAspectFitsAndCenters() {
        let rect = Letterbox.videoRect(video: CGSize(width: 1920, height: 1080),
                                       in: CGRect(x: 0, y: 0, width: 1000, height: 800))
        XCTAssertEqual(rect.width, 1000, accuracy: 0.001)
        XCTAssertEqual(rect.height, 562.5, accuracy: 0.001)
        XCTAssertEqual(rect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 118.75, accuracy: 0.001)
    }

    func testVideoRectPillarboxes() {
        let rect = Letterbox.videoRect(video: CGSize(width: 1080, height: 1920),
                                       in: CGRect(x: 0, y: 0, width: 1000, height: 800))
        XCTAssertEqual(rect.height, 800, accuracy: 0.001)
        XCTAssertEqual(rect.width, 450, accuracy: 0.001)
        XCTAssertEqual(rect.minX, 275, accuracy: 0.001)
    }

    func testNormalizedCenterIsHalfHalf() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let rect = Letterbox.videoRect(video: CGSize(width: 1920, height: 1080), in: bounds)
        let point = CGPoint(x: bounds.midX, y: bounds.midY)
        let (nx, ny) = Letterbox.normalized(point: point, videoRect: rect, flipped: false)
        XCTAssertEqual(nx, 0.5, accuracy: 0.0005)
        XCTAssertEqual(ny, 0.5, accuracy: 0.0005)
    }

    func testNormalizedTopLeftOfVideo() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let rect = Letterbox.videoRect(video: CGSize(width: 1920, height: 1080), in: bounds)
        // AppKit: top-left of the video is (minX, maxY).
        let (nx, ny) = Letterbox.normalized(point: CGPoint(x: rect.minX, y: rect.maxY),
                                            videoRect: rect, flipped: false)
        XCTAssertEqual(nx, 0, accuracy: 0.0005)
        XCTAssertEqual(ny, 0, accuracy: 0.0005)
    }

    func testNormalizedLetterboxAreaClampsToEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let rect = Letterbox.videoRect(video: CGSize(width: 1920, height: 1080), in: bounds)
        // Above the video (in the top letterbox bar).
        let (nx, ny) = Letterbox.normalized(point: CGPoint(x: 500, y: 790),
                                            videoRect: rect, flipped: false)
        XCTAssertEqual(nx, 0.5, accuracy: 0.0005)
        XCTAssertEqual(ny, 0, accuracy: 0.0005)
        // Below the video (bottom letterbox bar).
        let below = Letterbox.normalized(point: CGPoint(x: 500, y: 10), videoRect: rect, flipped: false)
        XCTAssertEqual(below.ny, 1, accuracy: 0.0005)
    }

    func testNormalizedFlippedView() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let (nx, ny) = Letterbox.normalized(point: CGPoint(x: 0, y: 0), videoRect: rect, flipped: true)
        XCTAssertEqual(nx, 0)
        XCTAssertEqual(ny, 0)
        let bottomRight = Letterbox.normalized(point: CGPoint(x: 100, y: 100), videoRect: rect, flipped: true)
        XCTAssertEqual(bottomRight.nx, 1)
        XCTAssertEqual(bottomRight.ny, 1)
    }

    func testNormalizedQuarterPoints() {
        let rect = CGRect(x: 100, y: 50, width: 400, height: 200)
        let (nx, ny) = Letterbox.normalized(point: CGPoint(x: 200, y: 200), videoRect: rect, flipped: false)
        XCTAssertEqual(nx, 0.25, accuracy: 0.0005)
        XCTAssertEqual(ny, 0.25, accuracy: 0.0005)
    }
}
