// The one renderer for phone app icons on the Mac (docs/design/dock.md §Icons):
// the Deck tile, the Dock shim's AppIcon.icns and Spotlight thumbnails all use
// its output, so an app looks the same everywhere. Pure CoreGraphics; the only
// AppKit use is converting an NSImage to and from a CGImage.

import AppKit
import CoreGraphics
import ImageIO

enum PhoneAppIcon {
    /// Bumped whenever the rendered look changes. Shim bundles carry it as
    /// `PDIconVersion`; an older one is rebuilt (docs/design/dock.md §Icons).
    /// 2: flat icons cover the tile or sit on a plate tinted from their edge.
    static let version = 2

    // MARK: macOS 26 icon grid

    /// The macOS icon canvas and the body Apple's grid leaves inside it
    /// (100 px margin on every side of a 1024 px canvas).
    static let marginFraction: CGFloat = 100.0 / 1024.0
    static let bodyFraction: CGFloat = 824.0 / 1024.0

    /// The body's continuous squircle: its corner is 22.5 % of the body's side,
    /// the same fraction as the Deck's glass tile (`GlassIcon.cornerFraction`).
    static let cornerFraction: CGFloat = 0.225
    /// A superellipse of this exponent has its 45° point at the same place as a
    /// 22.5 % rounded corner, with continuous curvature along the corner.
    static let cornerExponent: Double = 4.9

    // MARK: Adaptive and legacy content

    /// The visible part of an adaptive icon: the central 72 dp of the 108 dp
    /// layer (the tile's `cropRect`), drawn at 1.5× the body (`zoomFactor`).
    static let layerCropFraction: CGFloat = 2.0 / 3.0
    /// A legacy (flat) icon sits at 78 % on its white plate, as on the phone.
    static let legacyInsetFraction: CGFloat = 0.78

    // MARK: Finish (the only constants that touch the colours)

    /// Soft top light: white 0 → 5.5 % over the body's top 40 %.
    static let topLightAlpha: CGFloat = 0.055
    static let topLightHeightFraction: CGFloat = 0.40
    /// Thin inner specular edge: 8 % white, 1.5 % inside the body.
    static let specularAlpha: CGFloat = 0.08
    static let specularInsetFraction: CGFloat = 0.015
    static let specularWidthFraction: CGFloat = 0.0025

    // MARK: Shadow (inside the margin, so the icon keeps its canvas)

    static let shadowAlpha: CGFloat = 0.30
    static let shadowBlurFraction: CGFloat = 0.024
    static let shadowOffsetFraction: CGFloat = 0.012

    // MARK: Flat fit (the prototype's analysis)

    /// What a flat (legacy) image does inside the body. F0 ignores it and keeps
    /// the plate; F1–F3 ask `flatFit`.
    enum FlatFit: Equatable {
        /// Fill the body with this part of the image (unit coordinates, origin
        /// top-left).
        case cover(crop: CGRect)
        /// The plate, as today.
        case plate
    }

    /// A flat image's alpha, one byte per pixel, origin top-left. The analysis
    /// takes this instead of a `CGImage` so it is pure and testable.
    struct AlphaMap: Equatable {
        let width: Int
        let height: Int
        let values: [UInt8]

        func alpha(x: Int, y: Int) -> UInt8 { values[y * width + x] }
    }

    /// A flat image as 8-bit sRGB RGBA, one row per pixel from the top-left.
    struct IconBitmap: Equatable {
        let width: Int
        let height: Int
        let rgba: [UInt8]

        /// The alpha channel alone, for `flatFit`.
        var alpha: AlphaMap {
            AlphaMap(width: width, height: height,
                     values: stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] })
        }
    }

    /// An sRGB colour, 0...1 per channel.
    struct RGB: Equatable {
        let red: Double
        let green: Double
        let blue: Double
        static let white = RGB(red: 1, green: 1, blue: 1)
    }

    // MARK: Rendering

    /// The rendered icon at `px` pixels square. Adaptive layers win over the
    /// flat icon; a flat icon covers the tile or sits on its tinted plate
    /// (docs/design/dock.md §Icons). The flat analysis runs once per render,
    /// and every caller keeps the render: the Deck's `deckIcons`, the shim's
    /// `.icns` and the Spotlight thumbnail.
    static func render(layers: (fg: CGImage, bg: CGImage)?, flat: CGImage? = nil, px: Int) -> CGImage? {
        guard px > 0, layers != nil || flat != nil else { return nil }
        guard let context = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.setShouldAntialias(true)

        let side = CGFloat(px)
        let body = bodyRect(px: px)
        let shape = path(in: body)

        // The flat icon's shape decides the plate colour and the crop before
        // any drawing.
        var plate = RGB.white
        var cover: (image: CGImage, crop: CGRect)?
        if layers == nil, let flat, let pixels = bitmap(flat) {
            let alpha = pixels.alpha
            if let shape = opaqueShape(alpha) {
                switch fit(shape, alpha: alpha) {
                case .cover(let crop):
                    cover = (flat, crop)
                case .plate:
                    if let tint = plateColour(pixels: pixels, shape: shape) { plate = tint }
                }
            }
        }

        // The body (and its plate) with the platform's drop shadow.
        context.saveGState()
        let shadow = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                             components: [0, 0, 0, shadowAlpha])
        context.setShadow(offset: CGSize(width: 0, height: -side * shadowOffsetFraction),
                          blur: side * shadowBlurFraction, color: shadow)
        context.addPath(shape)
        context.setFillColor(cgColor(plate))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(shape)
        context.clip()

        if let cover {
            // No plate under a cover: the icon fills the body and whatever it
            // leaves transparent stays transparent instead of showing a plate.
            context.clear(body)
            drawCover(cover.image, crop: cover.crop, in: body, context: context)
        } else if let layers {
            // Full opacity, both layers, cropped to the visible 72 dp: no tint,
            // no material over the colours.
            // 1.5× the body, centred: the layer's central 2/3 covers the body.
            let inset = -body.width * (1 / layerCropFraction - 1) / 2
            let layerRect = body.insetBy(dx: inset, dy: inset)
            context.draw(layers.bg, in: layerRect)
            context.draw(layers.fg, in: layerRect)
        } else if let flat {
            let inset = body.width * (1 - legacyInsetFraction) / 2
            context.draw(flat, in: body.insetBy(dx: inset, dy: inset))
        }

        drawFinish(in: body, shape: shape, context: context)
        context.restoreGState()
        return context.makeImage()
    }

    /// The rendered icon as an NSImage at `px` pixels (used by SwiftUI views).
    static func image(layers: AppIconLayers?, flat: NSImage?, px: Int) -> NSImage? {
        guard let cg = render(layers: layerImages(layers), flat: flat.flatMap(cgImage), px: px)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: px, height: px))
    }

    /// The rendered icon from the cached PNG bytes (the IconCache's form).
    static func render(fg: Data?, bg: Data?, flat: Data?, px: Int) -> CGImage? {
        let foreground = fg.flatMap(decoded), background = bg.flatMap(decoded)
        if let foreground, let background {
            return render(layers: (foreground, background), flat: flat.flatMap(decoded), px: px)
        }
        return render(layers: nil, flat: flat.flatMap(decoded), px: px)
    }

    // MARK: Geometry

    static func bodyRect(px: Int) -> CGRect {
        let side = CGFloat(px)
        let margin = side * marginFraction
        let body = side * bodyFraction
        return CGRect(x: margin, y: margin, width: body, height: body)
    }

    static func cornerRadius(px: Int) -> CGFloat {
        bodyRect(px: px).width * cornerFraction
    }

    /// A continuous squircle (superellipse) filling `rect`.
    static func path(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let a = rect.width / 2, b = rect.height / 2
        let steps = 720
        for step in 0...steps {
            let angle = Double(step) / Double(steps) * 2 * .pi
            let cosine = cos(angle), sine = sin(angle)
            let x = rect.midX + a * CGFloat(copysign(pow(abs(cosine), 2 / cornerExponent), cosine))
            let y = rect.midY + b * CGFloat(copysign(pow(abs(sine), 2 / cornerExponent), sine))
            if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        path.closeSubpath()
        return path
    }

    // MARK: Flat-fit analysis

    /// The opaque bounds and the outline runs the analysis needs, gathered in
    /// one pass over the alpha (the analysis runs for every flat icon, so it is
    /// one pass, not eight).
    private struct Shape {
        let minX: Int, minY: Int, maxX: Int, maxY: Int
        let count: Int

        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
    }

    private static func opaqueShape(_ alpha: AlphaMap) -> Shape? {
        guard alpha.width > 1, alpha.height > 1,
              alpha.values.count == alpha.width * alpha.height else { return nil }
        var minX = alpha.width, minY = alpha.height, maxX = -1, maxY = -1
        var count = 0
        alpha.values.withUnsafeBufferPointer { values in
            for y in 0..<alpha.height {
                let base = y * alpha.width
                var first = -1, last = -1, row = 0
                for x in 0..<alpha.width where values[base + x] > 127 {
                    if first < 0 { first = x }
                    last = x
                    row += 1
                }
                if row == 0 { continue }
                count += row
                if first < minX { minX = first }
                if last > maxX { maxX = last }
                if y < minY { minY = y }
                maxY = y
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return Shape(minX: minX, minY: minY, maxX: maxX, maxY: maxY, count: count)
    }

    /// Whether a flat image should fill the tile, and which part of it: cover a
    /// square or a rounded square (trim its alpha, then crop just inside its
    /// own corner rounding so those corners land outside the body's squircle);
    /// keep the plate for anything else — a circle, a logo on transparency, a
    /// shape with a bite out of it.
    static func flatFit(alpha: AlphaMap) -> FlatFit {
        guard let shape = opaqueShape(alpha) else { return .plate }
        return fit(shape, alpha: alpha)
    }

    private static func fit(_ shape: Shape, alpha: AlphaMap) -> FlatFit {
        let width = shape.width, height = shape.height
        let short = min(width, height), long = max(width, height)

        // 1. Near square, and every edge's middle opaque: a shape that stops
        // short of a side is a logo or a circle, not a tile.
        guard Double(long) <= Double(short) * 1.05 else { return .plate }
        func opaque(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < alpha.width && y < alpha.height && alpha.alpha(x: x, y: y) > 127
        }
        let midX = shape.minX + width / 2, midY = shape.minY + height / 2
        let edgeSamples = [(midX, shape.minY), (midX, shape.maxY), (shape.minX, midY), (shape.maxX, midY),
                           (midX - 1, shape.minY), (midX + 1, shape.minY),
                           (midX - 1, shape.maxY), (midX + 1, shape.maxY),
                           (shape.minX, midY - 1), (shape.minX, midY + 1),
                           (shape.maxX, midY - 1), (shape.maxX, midY + 1)]
        guard edgeSamples.allSatisfy({ opaque($0.0, $0.1) }) else { return .plate }

        // 2. Measure the corner radius from the outline: a rounded square's
        // first row is width − 2r, its first column height − 2r. The median of
        // the four sides ignores a stray pixel; four very different sides mean
        // the outline is not a rounded square (a baked soft shadow, a notch in
        // one corner) and the plate stays.
        func run(row y: Int) -> Int {
            var n = 0
            for x in shape.minX...shape.maxX where opaque(x, y) { n += 1 }
            return n
        }
        func run(column x: Int) -> Int {
            var n = 0
            for y in shape.minY...shape.maxY where opaque(x, y) { n += 1 }
            return n
        }
        let radii = [Double(width - run(row: shape.minY)) / 2,
                     Double(width - run(row: shape.maxY)) / 2,
                     Double(height - run(column: shape.minX)) / 2,
                     Double(height - run(column: shape.maxX)) / 2].sorted()
        guard radii[3] - radii[0] <= max(2, 0.06 * Double(short)) else { return .plate }
        let radius = max(0, (radii[1] + radii[2]) / 2)

        // 3. The measured coverage must be the one that radius explains: a
        // rounded square loses (4 − π)·r² of its bounds to its four corners, so
        // a very round square (r 38 % of the side) still covers, while a circle,
        // whose coverage is far below what its outline radius predicts, keeps
        // the plate. 0.03 is the room antialiasing and a slightly uneven outline
        // need; the 0.8 floor rejects a shape that is mostly transparent.
        let coverage = Double(shape.count) / Double(width * height)
        let clamped = min(radius, Double(short) / 2)
        let expected = 1 - (4 - Double.pi) * clamped * clamped / Double(width * height)
        guard coverage >= 0.8, abs(coverage - expected) <= 0.03 else { return .plate }

        // 4. Crop 0.3 × the radius in from the bounds on every side. At that
        // inset the crop's corner sits just inside the icon's own corner arc
        // (0.7r√2 = 0.99r from the arc's centre), so covering the crop pushes
        // that arc outside our squircle and no transparency is left inside it.
        let inset = radius * 0.3
        let cropMinX = CGFloat(shape.minX) + inset, cropMinY = CGFloat(shape.minY) + inset
        let cropMaxX = CGFloat(shape.maxX) + 1 - inset, cropMaxY = CGFloat(shape.maxY) + 1 - inset
        guard cropMaxX - cropMinX >= 1, cropMaxY - cropMinY >= 1 else { return .plate }
        return .cover(crop: CGRect(x: cropMinX / CGFloat(alpha.width), y: cropMinY / CGFloat(alpha.height),
                                   width: (cropMaxX - cropMinX) / CGFloat(alpha.width),
                                   height: (cropMaxY - cropMinY) / CGFloat(alpha.height)))
    }

    /// The plate's colour: the median of the icon's outer opaque ring, unless
    /// that ring is too close to the logo's own mean colour (ΔE < 15) to read as
    /// a plate — then nil, and the plate stays white.
    static func plateColour(pixels: IconBitmap) -> RGB? {
        guard pixels.width > 1, pixels.height > 1,
              pixels.rgba.count == pixels.width * pixels.height * 4,
              let shape = opaqueShape(pixels.alpha) else { return nil }
        return plateColour(pixels: pixels, shape: shape)
    }

    private static func plateColour(pixels: IconBitmap, shape: Shape) -> RGB? {
        // The ring is the outer 5 % of the bounds, at least two pixels thick.
        let ring = max(2, Int((0.05 * Double(min(shape.width, shape.height))).rounded()))
        // Per-channel histograms: the median of a 0…255 ring needs no sort.
        var reds = [Int](repeating: 0, count: 256)
        var greens = [Int](repeating: 0, count: 256)
        var blues = [Int](repeating: 0, count: 256)
        var sum = (0, 0, 0)
        var count = 0, ringCount = 0
        pixels.rgba.withUnsafeBufferPointer { rgba in
            for y in shape.minY...shape.maxY {
                let edgeRow = y - shape.minY < ring || shape.maxY - y < ring
                for x in shape.minX...shape.maxX {
                    let offset = (y * pixels.width + x) * 4
                    let a = Int(rgba[offset + 3])
                    if a <= 127 { continue }
                    // The bitmap is premultiplied; a soft edge must not read
                    // darker than it is.
                    let r = a == 255 ? Int(rgba[offset]) : Int(rgba[offset]) * 255 / a
                    let g = a == 255 ? Int(rgba[offset + 1]) : Int(rgba[offset + 1]) * 255 / a
                    let b = a == 255 ? Int(rgba[offset + 2]) : Int(rgba[offset + 2]) * 255 / a
                    sum.0 += r; sum.1 += g; sum.2 += b
                    count += 1
                    if edgeRow || x - shape.minX < ring || shape.maxX - x < ring {
                        reds[r] += 1; greens[g] += 1; blues[b] += 1
                        ringCount += 1
                    }
                }
            }
        }
        guard count > 0, ringCount > 0 else { return nil }
        func median(_ histogram: [Int]) -> Double {
            let target = ringCount / 2
            var seen = 0
            for value in 0..<256 {
                seen += histogram[value]
                if seen > target { return Double(value) / 255 }
            }
            return 0
        }
        let edge = RGB(red: median(reds), green: median(greens), blue: median(blues))
        let logo = RGB(red: Double(sum.0) / Double(count) / 255, green: Double(sum.1) / Double(count) / 255,
                       blue: Double(sum.2) / Double(count) / 255)
        return deltaE(edge, logo) < 15 ? nil : edge
    }

    /// The flat image as 8-bit sRGB RGBA for the analysis. A bitmap context's
    /// memory starts at the top scanline, so row 0 is the image's top.
    static func bitmap(_ image: CGImage) -> IconBitmap? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        return drawn ? IconBitmap(width: width, height: height, rgba: rgba) : nil
    }

    /// CIE76 ΔE between two sRGB colours: the usual "can a person see it".
    static func deltaE(_ a: RGB, _ b: RGB) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        func lab(_ colour: RGB) -> (Double, Double, Double) {
            let r = linear(colour.red), g = linear(colour.green), bl = linear(colour.blue)
            let x = (0.4124 * r + 0.3576 * g + 0.1805 * bl) / 0.95047
            let y = (0.2126 * r + 0.7152 * g + 0.0722 * bl)
            let z = (0.0193 * r + 0.1192 * g + 0.9505 * bl) / 1.08883
            func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1 / 3) : 7.787 * t + 16 / 116 }
            let fx = f(x), fy = f(y), fz = f(z)
            return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
        }
        let first = lab(a), second = lab(b)
        return sqrt(pow(first.0 - second.0, 2) + pow(first.1 - second.1, 2) + pow(first.2 - second.2, 2))
    }

    // MARK: Drawing

    private static func cgColor(_ colour: RGB) -> CGColor {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGColor(colorSpace: space, components: [colour.red, colour.green, colour.blue, 1])
        else { return CGColor(gray: colour.red, alpha: 1) }
        return cg
    }

    /// Draws `image` so `crop` (unit coordinates, origin top-left) covers
    /// `body`: the crop's shorter side fills the body, the rest is clipped.
    private static func drawCover(_ image: CGImage, crop: CGRect, in body: CGRect, context: CGContext) {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let cropWidth = crop.width * width, cropHeight = crop.height * height
        guard cropWidth > 0, cropHeight > 0 else { return }
        let scale = max(body.width / cropWidth, body.height / cropHeight)
        let size = CGSize(width: width * scale, height: height * scale)
        // CG's origin is bottom-left, the crop's is top-left: the crop's top
        // edge lands where its unit y says.
        let origin = CGPoint(x: body.midX - crop.midX * size.width,
                             y: body.maxY - crop.maxY * size.height)
        context.draw(image, in: CGRect(origin: origin, size: size))
    }

    // MARK: Finish

    private static func drawFinish(in body: CGRect, shape: CGPath, context: CGContext) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let white = CGColor(colorSpace: space, components: [1, 1, 1, 1])!

        // Top light, fading out well above the centre so the colours there are
        // untouched.
        let clear = CGColor(colorSpace: space, components: [1, 1, 1, 0])!
        let light = CGColor(colorSpace: space, components: [1, 1, 1, topLightAlpha])!
        if let gradient = CGGradient(colorsSpace: space, colors: [light, clear] as CFArray, locations: [0, 1]) {
            context.saveGState()
            context.addPath(shape)
            context.clip()
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: body.midX, y: body.maxY),
                                       end: CGPoint(x: body.midX, y: body.maxY - body.height * topLightHeightFraction),
                                       options: [])
            context.restoreGState()
        }

        // Thin inner specular edge.
        let inset = body.width * specularInsetFraction
        let edge = path(in: body.insetBy(dx: inset, dy: inset))
        context.saveGState()
        context.addPath(edge)
        context.setStrokeColor(white.copy(alpha: specularAlpha) ?? white)
        context.setLineWidth(max(body.width * specularWidthFraction, 0.5))
        context.strokePath()
        context.restoreGState()
    }

    // MARK: Images

    private static func layerImages(_ layers: AppIconLayers?) -> (fg: CGImage, bg: CGImage)? {
        guard let layers,
              let fg = cgImage(layers.fg), let bg = cgImage(layers.bg) else { return nil }
        return (fg, bg)
    }

    private static func decoded(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func cgImage(_ image: NSImage) -> CGImage? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
