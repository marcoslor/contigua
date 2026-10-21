// Icons stay the icons people saw before (docs/NFR.md): the renderer's output
// for the fake phone's adaptive pattern and for a legacy flat icon is compared
// with small committed reference PNGs, and no icon is ever upscaled from a
// smaller source.

import AppKit
import XCTest
@testable import PocketDeck

final class IconReferenceTests: XCTestCase {
    private let side = 128

    private func context(_ side: Int) -> CGContext {
        CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// The fake phone's adaptive fg layer: a blue disc with a white plane
    /// triangle through the centre, on a transparent canvas (fakephone's own
    /// pattern), at the layer size the renderer is asked for.
    private func fakeAdaptiveLayers(size: Int) -> (fg: CGImage, bg: CGImage) {
        let fgContext = context(size)
        fgContext.setFillColor(CGColor(srgbRed: 51 / 255, green: 144 / 255, blue: 236 / 255, alpha: 1))
        let centre = CGFloat(size - 1) / 2
        let radius = CGFloat(size) * 0.32
        fgContext.fillEllipse(in: CGRect(x: centre - radius, y: centre - radius,
                                         width: radius * 2, height: radius * 2))
        fgContext.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        let x0 = CGFloat(size) * 0.34, x1 = CGFloat(size) * 0.63
        let half = CGFloat(size) * 0.16
        fgContext.beginPath()
        fgContext.move(to: CGPoint(x: x0, y: centre - half))
        fgContext.addLine(to: CGPoint(x: x1, y: centre))
        fgContext.addLine(to: CGPoint(x: x0, y: centre + half))
        fgContext.closePath()
        fgContext.fillPath()

        let bgContext = context(size)
        bgContext.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        bgContext.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return (fgContext.makeImage()!, bgContext.makeImage()!)
    }

    /// A legacy flat icon: the phone's 96 px solid colour with a lighter band,
    /// the shape the 2026-10-20 report saw upscaled to 1024.
    private func legacyFlat(size: Int) -> CGImage {
        let context = context(size)
        context.setFillColor(CGColor(srgbRed: 0, green: 82 / 255, blue: 204 / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.75))
        context.fill(CGRect(x: 0, y: size / 3, width: size, height: size / 3))
        return context.makeImage()!
    }

    private var referenceDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("IconReferences", isDirectory: true)
    }

    private func png(_ image: CGImage) -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])!
    }

    /// The mean absolute difference per 8-bit channel, the tolerance NFR.md
    /// names (a few levels: the same drawing on another GPU or macOS build).
    private func meanDifference(_ a: CGImage, _ b: CGImage) -> Double {
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            data.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: image.width,
                                        height: image.height, bitsPerComponent: 8,
                                        bytesPerRow: image.width * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return data
        }
        let first = pixels(a), second = pixels(b)
        XCTAssertEqual(first.count, second.count)
        let total = zip(first, second).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(first.count)
    }

    private func check(_ name: String, _ image: CGImage) {
        let url = referenceDirectory.appendingPathComponent(name)
        let data = png(image)
        if ProcessInfo.processInfo.environment["PD_NFR_WRITE_REFS"] == "1" {
            try? FileManager.default.createDirectory(at: referenceDirectory,
                                                     withIntermediateDirectories: true)
            try? data.write(to: url)
            return
        }
        guard let referenceData = try? Data(contentsOf: url),
              let reference = NSBitmapImageRep(data: referenceData)?.cgImage else {
            return XCTFail("missing reference \(name); regenerate with PD_NFR_WRITE_REFS=1")
        }
        let difference = meanDifference(image, reference)
        let tolerance = NFRTestLimits.shared.double("icon_mean_tolerance")
        XCTAssertLessThanOrEqual(difference, tolerance,
                                 "\(name): mean channel difference \(difference), tolerance \(tolerance)")
    }

    func testTheFakePhonesAdaptiveIconMatchesItsReference() throws {
        let layers = fakeAdaptiveLayers(size: 216)
        let rendered = try XCTUnwrap(PhoneAppIcon.render(layers: layers, px: side))
        check("fake-adaptive.png", rendered)
    }

    func testALegacyIconMatchesItsReference() throws {
        let rendered = try XCTUnwrap(PhoneAppIcon.render(layers: nil, flat: legacyFlat(size: 96), px: side))
        check("legacy-flat.png", rendered)
    }

    func testNoIconIsUpscaled() {
        XCTAssertGreaterThanOrEqual(PhoneAppIcon.version, 1)
        // The shim renders one 1024 px image and cuts every .icns size from it.
        let renderSide = 1024
        XCTAssertLessThanOrEqual(DockShimBuilder.icnsSizes.max() ?? 0, renderSide,
                                 "an .icns size must never be larger than its source render")
        let scale = NFRTestLimits.shared.double("icon_min_source_scale")
        XCTAssertGreaterThanOrEqual(scale, 1.0)
        XCTAssertGreaterThanOrEqual(Double(renderSide) / Double(DockShimBuilder.icnsSizes.max() ?? 1), scale)
    }
}
