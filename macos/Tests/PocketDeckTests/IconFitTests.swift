// How a flat (legacy) icon is drawn in the Deck tile (docs/design/dock.md
// §Icons): a square or a rounded square covers the tile, anything else sits on
// a plate tinted from its own edge. Pinned on synthetic alpha maps (K2), plus
// the tile invariants — nothing transparent inside the squircle for a cover —
// and, when the person's copied icons are present, the evidence sheets.

import AppKit
import XCTest
@testable import PocketDeck

final class IconFitTests: XCTestCase {

    // MARK: Synthetic alpha

    /// An alpha map of `side` pixels: `inside` says which pixels are opaque.
    private func alphaMap(_ side: Int = 200, _ inside: (Int, Int) -> Bool) -> PhoneAppIcon.AlphaMap {
        var values = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side where inside(x, y) { values[y * side + x] = 255 }
        }
        return PhoneAppIcon.AlphaMap(width: side, height: side, values: values)
    }

    /// A rounded square inside `margin`, its corners `radius` pixels.
    private func roundedSquareAlpha(_ side: Int = 200, margin: Int = 20,
                                    radius: Int) -> PhoneAppIcon.AlphaMap {
        alphaMap(side) { x, y in
            let minX = margin, maxX = side - margin - 1
            let minY = margin, maxY = side - margin - 1
            guard x >= minX, x <= maxX, y >= minY, y <= maxY else { return false }
            let cx = x < minX + radius ? minX + radius : (x > maxX - radius ? maxX - radius : x)
            let cy = y < minY + radius ? minY + radius : (y > maxY - radius ? maxY - radius : y)
            return (x - cx) * (x - cx) + (y - cy) * (y - cy) <= radius * radius
        }
    }

    // MARK: Synthetic images

    private func context(_ side: Int) -> CGContext {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setShouldAntialias(true)
        return context
    }

    private func colour(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat,
                        _ alpha: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                components: [red, green, blue, alpha])!
    }

    private func roundedSquareImage(side: Int = 200, margin: Int = 20, radius: Int,
                                    colour fill: CGColor) -> CGImage {
        let context = context(side)
        let rect = CGRect(x: margin, y: margin, width: side - 2 * margin, height: side - 2 * margin)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: CGFloat(radius), cornerHeight: CGFloat(radius),
                               transform: nil))
        context.setFillColor(fill)
        context.fillPath()
        return context.makeImage()!
    }

    private func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, side: Int = 200) -> CGImage {
        let context = context(side)
        context.setFillColor(colour(red, green, blue))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()!
    }

    /// A disc of `radius` pixels, `fill` coloured, on transparency.
    private func discImage(side: Int = 200, radius: CGFloat, fill: CGColor) -> CGImage {
        let context = context(side)
        let inset = CGFloat(side) / 2 - radius
        context.setFillColor(fill)
        context.fillEllipse(in: CGRect(x: inset, y: inset, width: radius * 2, height: radius * 2))
        return context.makeImage()!
    }

    private func pixels(_ image: CGImage) -> (width: Int, height: Int, data: [UInt8]) {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (width, height, data)
    }

    /// Pixels inside the body whose alpha is below opaque, counting from the
    /// bitmap's top row (the image's top).
    private func holes(_ image: CGImage, side: Int = 224) -> Int {
        let body = PhoneAppIcon.bodyRect(px: side)
        let inside = PhoneAppIcon.path(in: body.insetBy(dx: 1, dy: 1))
        let (width, _, data) = pixels(image)
        var count = 0
        for y in 0..<side {
            for x in 0..<side where inside.contains(CGPoint(x: Double(x) + 0.5,
                                                           y: Double(side) - Double(y) - 0.5)) {
                if data[(y * width + x) * 4 + 3] < 252 { count += 1 }
            }
        }
        return count
    }

    // MARK: flatFit

    func testAFullOpaqueSquareCoversTheWholeImage() {
        let fit = PhoneAppIcon.flatFit(alpha: alphaMap { _, _ in true })
        guard case .cover(let crop) = fit else { return XCTFail("a full square covers: \(fit)") }
        XCTAssertEqual(crop.minX, 0, accuracy: 0.0001)
        XCTAssertEqual(crop.minY, 0, accuracy: 0.0001)
        XCTAssertEqual(crop.width, 1, accuracy: 0.0001)
        XCTAssertEqual(crop.height, 1, accuracy: 0.0001)
    }

    func testARoundedSquareWithAMarginCropsInsideTheMarginAndPastTheCorners() {
        // 10 % margin (20 px), 20 % corner radius of the opaque square (32 px).
        let fit = PhoneAppIcon.flatFit(alpha: roundedSquareAlpha(radius: 32))
        guard case .cover(let crop) = fit else { return XCTFail("a rounded square covers: \(fit)") }
        XCTAssertGreaterThan(crop.minX, 0.10, "the crop starts inside the transparent margin")
        XCTAssertGreaterThan(crop.minY, 0.10)
        XCTAssertLessThan(crop.minX, 0.10 + 0.2 * 0.8, "the crop reaches past the icon's own corners")
        XCTAssertLessThan(crop.minY, 0.10 + 0.2 * 0.8)
        XCTAssertEqual(crop.midX, 0.5, accuracy: 0.01)
        XCTAssertEqual(crop.midY, 0.5, accuracy: 0.01)
        // 0.3 × 32 px in from each side of the 160 px square.
        XCTAssertEqual(crop.width, (160 - 2 * 9.6) / 200, accuracy: 0.01)
    }

    func testASecureFolderShapedRoundedSquareCovers() {
        // The person's app: a very round square, a 42 % corner radius of a
        // 96 px icon, coverage about 0.85 — under the old 0.9 floor, so it sat
        // on the plate. The radius explains the missing area, so it covers.
        let fit = PhoneAppIcon.flatFit(alpha: roundedSquareAlpha(96, margin: 0, radius: 40))
        guard case .cover(let crop) = fit else { return XCTFail("a 42 % rounded square covers: \(fit)") }
        XCTAssertEqual(crop.midX, 0.5, accuracy: 0.01)
        // 0.3 × 40 px in from each side of the 96 px icon.
        XCTAssertEqual(crop.width, 72.0 / 96.0, accuracy: 0.02)
    }

    func testACircleKeepsThePlate() {
        let fit = PhoneAppIcon.flatFit(alpha: alphaMap { x, y in
            let dx = Double(x) - 100, dy = Double(y) - 100
            return dx * dx + dy * dy <= 80 * 80
        })
        XCTAssertEqual(fit, .plate, "a circle would lose its edges to a cover")
    }

    func testAnIrregularLogoKeepsThePlate() {
        // An opaque triangle on transparency.
        let fit = PhoneAppIcon.flatFit(alpha: alphaMap { x, y in
            x >= 20 && x <= 180 && y >= 20 && y <= 180 && Double(y - 20) >= Double(abs(x - 100)) * 1.6
        })
        XCTAssertEqual(fit, .plate, "a triangle is not a tile")
    }

    func testASquareWithOneTransparentCornerNotchKeepsThePlate() {
        // Coverage stays high and the edge midpoints are opaque, so the corner
        // measurement is what tells this from a rounded square: the four
        // corners disagree (0, 0, 20, 20 px), and a notch would leave a hole
        // inside the squircle.
        let notch = 40
        let fit = PhoneAppIcon.flatFit(alpha: alphaMap { x, y in
            !(x < notch && y < notch)
        })
        XCTAssertEqual(fit, .plate)
    }

    func testAnImageWhoseTopHalfIsOpaqueDecodesTopDown() throws {
        // The analysis' row 0 must be the image's top row (a bitmap context's
        // memory starts at the top scanline), or every crop is upside down.
        let context = context(40)
        context.setFillColor(colour(1, 1, 1))
        context.fill(CGRect(x: 0, y: 20, width: 40, height: 20))
        let image = try XCTUnwrap(context.makeImage())
        let map = try XCTUnwrap(PhoneAppIcon.bitmap(image)).alpha
        XCTAssertEqual(map.alpha(x: 20, y: 0), 255, "row 0 is the image's top")
        XCTAssertEqual(map.alpha(x: 20, y: 39), 0)
    }

    // MARK: The tile

    func testEveryCoverLeavesNoTransparentPixelInsideTheSquircle() throws {
        // The person's cases: a full square, a rounded square with a 10 %
        // margin, a rounded square without one, and a very round square.
        let covers: [(String, CGImage)] = [
            ("full square", solid(0.10, 0.62, 0.32)),
            ("rounded square with a margin", roundedSquareImage(radius: 32, colour: colour(0.10, 0.62, 0.32))),
            ("rounded square, no margin", roundedSquareImage(margin: 0, radius: 15, colour: colour(0.2, 0.4, 0.9))),
            ("very round square", roundedSquareImage(side: 96, margin: 0, radius: 40,
                                                     colour: colour(0.15, 0.36, 1.0))),
        ]
        for (name, image) in covers {
            let rendered = try XCTUnwrap(PhoneAppIcon.render(layers: nil, flat: image, px: 224))
            XCTAssertEqual(holes(rendered), 0, "\(name): the plate shows inside the squircle")
        }
    }

    func testTheCropIsWhatKeepsACoverOpaque() throws {
        // The control for the check above: drawn without flatFit's crop, the
        // same rounded square leaves its margin inside the squircle, so the
        // invariant above can fail.
        let image = roundedSquareImage(radius: 32, colour: colour(0.10, 0.62, 0.32))
        let side = 224
        let context = context(side)
        let body = PhoneAppIcon.bodyRect(px: side)
        context.addPath(PhoneAppIcon.path(in: body))
        context.clip()
        context.draw(image, in: body)
        let drawn = try XCTUnwrap(context.makeImage())
        XCTAssertGreaterThan(holes(drawn), 100, "an uncropped cover leaves the margin showing")
    }

    func testAFullSquareFillsTheTileAndACircleKeepsItsPlate() throws {
        // Inside the body's left edge, at its middle: a covered icon shows its
        // own colour there; a plated one shows the white plate.
        let covered = try XCTUnwrap(PhoneAppIcon.render(layers: nil, flat: solid(1, 0, 0), px: 1024))
        let plate = try XCTUnwrap(PhoneAppIcon.render(layers: nil, flat: discImage(side: 200, radius: 80,
                                                                                   fill: colour(1, 0, 0)),
                                                      px: 1024))
        let coveredPixel = pixels(covered).data
        let platePixel = pixels(plate).data
        let offset = (512 * 1024 + 110) * 4
        XCTAssertGreaterThanOrEqual(coveredPixel[offset], 250, "the square fills the tile with its colour")
        XCTAssertLessThanOrEqual(coveredPixel[offset + 1], 5)
        XCTAssertGreaterThanOrEqual(platePixel[offset], 250, "the circle keeps the white plate")
        XCTAssertGreaterThanOrEqual(platePixel[offset + 1], 250)
        XCTAssertGreaterThanOrEqual(platePixel[offset + 2], 250)
    }

    func testAdaptiveIconsAreTheSameWithAFlatFallbackAttached() throws {
        // Adaptive layers win: the flat image, and therefore the analysis, is
        // never drawn when both layers arrived.
        let layers = (solid(1, 0, 0), solid(0, 0, 1))
        let withFlat = try XCTUnwrap(PhoneAppIcon.render(layers: layers, flat: solid(0, 1, 0), px: 224))
        let without = try XCTUnwrap(PhoneAppIcon.render(layers: layers, px: 224))
        XCTAssertEqual(pixels(withFlat).data, pixels(without).data)
    }

    func testTheVersionBumpRebuildsTheShims() {
        // The flat look changed, so every shim built by an older renderer must
        // be rebuilt (docs/design/dock.md §Icons).
        XCTAssertGreaterThanOrEqual(PhoneAppIcon.version, 2)
    }

    // MARK: The plate colour

    func testATintedPlateComesFromTheOpaqueRing() throws {
        // A dark ring around a light logo: the ring is far enough from the
        // logo's mean to be a plate.
        let dark = colour(0.05, 0.05, 0.08)
        let light = colour(0.95, 0.95, 0.95)
        let context = context(96)
        context.setFillColor(dark)
        context.fillEllipse(in: CGRect(x: 8, y: 8, width: 80, height: 80))
        context.setFillColor(light)
        context.fillEllipse(in: CGRect(x: 30, y: 30, width: 36, height: 36))
        let image = try XCTUnwrap(context.makeImage())
        let bitmap = try XCTUnwrap(PhoneAppIcon.bitmap(image))
        let tint = try XCTUnwrap(PhoneAppIcon.plateColour(pixels: bitmap), "the ring contrasts with the logo")
        XCTAssertLessThan(tint.red, 0.2)
        XCTAssertLessThan(tint.green, 0.2)
        XCTAssertLessThan(tint.blue, 0.2)

        // And the render puts that colour behind a plate icon.
        let rendered = try XCTUnwrap(PhoneAppIcon.render(layers: nil, flat: image, px: 1024))
        let data = pixels(rendered).data
        let offset = (512 * 1024 + 110) * 4
        XCTAssertLessThan(data[offset], 60, "the plate is the ring's colour, not white")
    }

    func testAPlateColourTooCloseToTheLogoFallsBackToWhite() throws {
        // A uniformly red disc: its ring is its own colour, so a tint would
        // just be more of the same and the plate stays white.
        let red = colour(0.80, 0.12, 0.14)
        let image = discImage(radius: 80, fill: red)
        let bitmap = try XCTUnwrap(PhoneAppIcon.bitmap(image))
        XCTAssertNil(PhoneAppIcon.plateColour(pixels: bitmap))

        let rendered = try XCTUnwrap(PhoneAppIcon.render(layers: nil, flat: image, px: 1024))
        let data = pixels(rendered).data
        let offset = (512 * 1024 + 110) * 4
        XCTAssertGreaterThanOrEqual(data[offset], 250, "the plate falls back to white")
    }

    // MARK: Evidence (not part of the product)

    /// Renders the review sheets from the real renderer: the Deck's tile and
    /// the Dock's 1024 px icon for the person's copied icons. `PD_ICONFIT_SRC`
    /// is their folder (manifest.json + the PNGs), `PD_ICONFIT_OUT` where the
    /// sheets go. Skipped when the icons are not there — they are never
    /// committed.
    func testEvidenceSheets() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let source = environment["PD_ICONFIT_SRC"], let output = environment["PD_ICONFIT_OUT"]
        else { throw XCTSkip("PD_ICONFIT_SRC/PD_ICONFIT_OUT not set: no copied icons to render") }

        struct Entry: Decodable {
            let pkg: String
            let short: String
            let kind: String
            let flat: String?
            let flat288: String?
            let fg: String?
            let bg: String?
        }
        struct Manifest: Decodable {
            let apps: [Entry]
            let dock: [String]
        }
        let manifestURL = URL(fileURLWithPath: source).appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        XCTAssertEqual(manifest.apps.filter { $0.kind == "flat" }.count, 16, "16 legacy icons")
        XCTAssertEqual(manifest.apps.filter { $0.kind == "adaptive" }.count, 4, "4 adaptive controls")
        XCTAssertEqual(manifest.dock.count, 6, "6 icons at the Dock size")

        func image(_ path: String?) -> CGImage? {
            guard let path else { return nil }
            let url = URL(fileURLWithPath: source).appendingPathComponent(path)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }

        func render(_ entry: Entry, px: Int) -> CGImage? {
            let fg = image(entry.fg), bg = image(entry.bg)
            let layers = fg.flatMap { fg in bg.map { (fg: fg, bg: $0) } }
            return PhoneAppIcon.render(layers: layers, flat: image(entry.flat288 ?? entry.flat), px: px)
        }

        // The Deck's grid sits on the window's own background.
        func background(_ name: NSAppearance.Name) -> NSColor {
            var resolved = NSColor.windowBackgroundColor
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                resolved = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .windowBackgroundColor
            }
            return resolved
        }

        func sheet(name: String, dark: Bool) throws {
            let deck: CGFloat = 112
            let dock: CGFloat = 96
            let gap = 12.0, label = 60.0, header = 40.0, footer = 26.0, caption = 18.0
            let columns = CGFloat(manifest.apps.count)
            let dockEntries = manifest.apps.filter { manifest.dock.contains($0.pkg) }
            let width = Int(label + columns * (deck + gap) + gap)
            let height = Int(header + (deck + caption + gap) + 20 + (dock + caption + gap) + footer)
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                                     bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            defer { NSGraphicsContext.restoreGraphicsState() }
            guard let context = NSGraphicsContext.current?.cgContext else { return XCTFail("no sheet context") }

            background(dark ? .darkAqua : .aqua).setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            let ink: NSColor = dark ? .white : .black
            let quiet = ink.withAlphaComponent(0.62)
            func text(_ string: String, _ x: Double, _ top: Double, _ size: Double, _ tint: NSColor) {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: size, weight: .regular), .foregroundColor: tint,
                ]
                (string as NSString).draw(at: NSPoint(x: x, y: Double(height) - top - size - 2),
                                          withAttributes: attributes)
            }
            // CG draws from the bottom; `top` is measured from the sheet's top.
            func draw(_ image: CGImage, _ x: Double, _ top: Double, _ cell: CGFloat) {
                context.draw(image, in: CGRect(x: x, y: Double(height) - top - cell, width: cell, height: cell))
            }

            text("Deck tile, 224 px render — \(dark ? "dark" : "light")", 12, 8, 11, quiet)
            for (column, entry) in manifest.apps.enumerated() {
                let x = label + Double(column) * (deck + gap)
                text(entry.short, x + 2, header - 14, 9, quiet)
                if let rendered = render(entry, px: 224) { draw(rendered, x, header, deck) }
            }

            let dockTop = header + Double(deck) + Double(caption) + 20
            text("Dock icon, 1024 px render, shown at 96", 12, dockTop - 24, 11, quiet)
            for (column, entry) in dockEntries.enumerated() {
                let x = label + Double(column) * (deck + gap)
                text(entry.short, x + 2, dockTop - 14, 9, quiet)
                if let rendered = render(entry, px: 1024) { draw(rendered, x, dockTop + 6, dock) }
            }
            text("flat: cover, or plate tinted from the icon's edge · adaptive: the phone's layers",
                 12, Double(height) - footer, 10, quiet)

            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
        }

        try sheet(name: "build-dark.png", dark: true)
        try sheet(name: "build-light.png", dark: false)

        // The same invariant as the synthetic K2 test, on the person's own
        // icons through the real renderer.
        for entry in manifest.apps where entry.kind == "flat" {
            guard let flat = image(entry.flat288 ?? entry.flat),
                  let rendered = PhoneAppIcon.render(layers: nil, flat: flat, px: 224)
            else { continue }
            XCTAssertEqual(holes(rendered), 0, "\(entry.short): the plate shows inside the squircle")
        }
    }

    func testTheGridProbeReadsTheTilesEdgeAsDrawn() throws {
        // The e2e's flat-icon step reads this value: a cover fills the body's
        // leading edge with the icon, a plate shows the plate there.
        let covered = try XCTUnwrap(PhoneAppIcon.render(layers: nil, flat: solid(0, 128 / 255, 96 / 255), px: 224))
        XCTAssertEqual(DeckGridProbe.edgeInk(NSImage(cgImage: covered, size: NSSize(width: 224, height: 224))),
                       "0,128,96", "a covered tile's edge is the icon's own colour")
        let plated = try XCTUnwrap(PhoneAppIcon.render(layers: nil, flat: discImage(radius: 80,
                                                                                  fill: colour(0.78, 0.24, 0.24)),
                                                      px: 224))
        XCTAssertEqual(DeckGridProbe.edgeInk(NSImage(cgImage: plated, size: NSSize(width: 224, height: 224))),
                       "255,255,255", "a plated tile's edge is its white plate")
    }
}
