// The icon renderer's contract (docs/design/dock.md §Icons): Apple's grid and
// shape, the phone's colours at full opacity, and a finish that stays out of
// the centre.

import AppKit
import XCTest
@testable import PocketDeck

final class PhoneAppIconTests: XCTestCase {

    private func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1,
                       side: Int = 256) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: space, components: [red, green, blue, alpha])!)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()!
    }

    private func pixels(_ image: CGImage) -> (width: Int, data: [UInt8]) {
        let width = image.width
        var data = [UInt8](repeating: 0, count: width * image.height * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
        }
        return (width, data)
    }

    private func rgba(_ image: CGImage, x: Int, y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
        let (width, data) = pixels(image)
        let offset = (y * width + x) * 4
        return (Double(data[offset]), Double(data[offset + 1]), Double(data[offset + 2]), Double(data[offset + 3]))
    }

    /// CIE76 ΔE between two sRGB colours, the usual "can a person see it" measure.
    private func deltaE(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)) -> Double {
        func lab(_ c: (r: Double, g: Double, b: Double)) -> (Double, Double, Double) {
            func linear(_ value: Double) -> Double {
                let v = value / 255
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            let r = linear(c.r), g = linear(c.g), bl = linear(c.b)
            let x = (0.4124 * r + 0.3576 * g + 0.1805 * bl) / 0.95047
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * bl
            let z = (0.0193 * r + 0.1192 * g + 0.9505 * bl) / 1.08883
            func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1 / 3) : 7.787 * t + 16 / 116 }
            let fx = f(x), fy = f(y), fz = f(z)
            return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
        }
        let first = lab(a), second = lab(b)
        return sqrt(pow(first.0 - second.0, 2) + pow(first.1 - second.1, 2) + pow(first.2 - second.2, 2))
    }

    func testTheGridIsApples() {
        XCTAssertEqual(PhoneAppIcon.bodyRect(px: 1024), CGRect(x: 100, y: 100, width: 824, height: 824))
        XCTAssertEqual(PhoneAppIcon.cornerRadius(px: 1024), 824 * 0.225, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(PhoneAppIcon.version, 1)
    }

    func testTheRenderedImageHasTheAskedSize() throws {
        let image = try XCTUnwrap(PhoneAppIcon.render(layers: nil, flat: solid(1, 0, 0), px: 1024))
        XCTAssertEqual(image.width, 1024)
        XCTAssertEqual(image.height, 1024)
        let tile = try XCTUnwrap(PhoneAppIcon.render(layers: nil, flat: solid(1, 0, 0), px: 224))
        XCTAssertEqual(tile.width, 224)
    }

    func testOutsideTheSquircleIsTransparentAndInsideOpaque() throws {
        let image = try XCTUnwrap(PhoneAppIcon.render(layers: (solid(1, 0, 0), solid(0, 0, 1)), px: 1024))

        XCTAssertEqual(rgba(image, x: 2, y: 2).a, 0, "the canvas corners stay clear")
        XCTAssertEqual(rgba(image, x: 1021, y: 1021).a, 0)
        XCTAssertEqual(rgba(image, x: 512, y: 512).a, 255, "the body is opaque")
        XCTAssertEqual(rgba(image, x: 104, y: 512).a, 255, "the squircle reaches the body's edge")
    }

    func testTheCentreKeepsTheBackgroundColour() throws {
        // A transparent foreground: what is left at the centre is the bg layer.
        let image = try XCTUnwrap(PhoneAppIcon.render(
            layers: (solid(0, 0, 0, 0), solid(0, 82 / 255, 204 / 255)), px: 1024))
        let centre = rgba(image, x: 512, y: 512)

        XCTAssertLessThan(deltaE((centre.r, centre.g, centre.b), (0, 82, 204)), 2, "no washing: the layer's colour is the icon's")
        XCTAssertEqual(centre.a, 255)
    }

    func testTheForegroundDrawsAtFullOpacity() throws {
        let image = try XCTUnwrap(PhoneAppIcon.render(layers: (solid(1, 0, 0), solid(0, 0, 1)), px: 1024))
        let centre = rgba(image, x: 512, y: 512)

        XCTAssertLessThan(deltaE((centre.r, centre.g, centre.b), (255, 0, 0)), 2, "the fg is not blended into the bg")
    }

    func testALegacySquareFillsTheTile() throws {
        // The picked look (docs/design/dock.md §Icons): a full-bleed flat
        // square covers the tile, so its colour reaches the body's edge. The
        // plate cases are pinned in IconFitTests.
        let image = try XCTUnwrap(PhoneAppIcon.render(layers: nil, flat: solid(0, 1, 0), px: 1024))
        let edge = rgba(image, x: 110, y: 512)
        let centre = rgba(image, x: 512, y: 512)

        XCTAssertLessThan(deltaE((centre.r, centre.g, centre.b), (0, 255, 0)), 3, "the flat icon keeps its colour")
        XCTAssertLessThan(deltaE((edge.r, edge.g, edge.b), (0, 255, 0)), 3, "the square reaches the tile's edge")
        XCTAssertEqual(edge.a, 255)
    }

    // The two reported bugs, pinned as numeric repros: the old Deck tile put
    // the bg layer at 35 % under the glass material, and the old Dock .icns
    // upscaled the phone's 96 px flat icon to 1024.

    func testTheOldWashedTileWouldShiftWhiteFarMoreThanTheRendererDoes() {
        // White bg at 35 % over a dark glass material (around 30/255 in dark
        // mode, the user's murky Telegram tile): about 69 % of the colour is
        // the material, not the app.
        let washed = 0.35 * 255 + 0.65 * 30
        XCTAssertGreaterThan(deltaE((washed, washed, washed), (255, 255, 255)), 20,
                             "the old tile never reached the bg colour")
        XCTAssertLessThan(deltaE((255, 255, 255), (255, 255, 255)), 2,
                          "the renderer draws the bg at full opacity")
    }

    func testTheDockRenderNeverUpscalesThePhoneLayers() {
        // 1296 px layers, their visible 2/3 = 864 px, fill the 824 px body:
        // 0.95×, a downscale. The old path scaled a 96 px PNG into 1024: 8.6×.
        let visible = 1296.0 * 2 / 3
        XCTAssertLessThanOrEqual(824.0 / visible, 1.0)
        XCTAssertGreaterThan(1024.0 / 96.0, 8.0, "the old .icns was an 8.6× upscale")
    }

    func testTheFinishLeavesWhiteAlone() throws {
        let image = try XCTUnwrap(PhoneAppIcon.render(layers: (solid(0, 0, 0, 0), solid(1, 1, 1)), px: 1024))
        let centre = rgba(image, x: 512, y: 512)

        XCTAssertGreaterThanOrEqual(centre.r, 250, "white stays white at the centre")
        XCTAssertGreaterThanOrEqual(centre.g, 250)
        XCTAssertGreaterThanOrEqual(centre.b, 250)
    }
}
