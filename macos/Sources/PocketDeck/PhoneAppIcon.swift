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
    static let version = 1

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

    // MARK: Rendering

    /// The rendered icon at `px` pixels square. Adaptive layers win over the
    /// flat icon; a flat-only app gets the plate. Nil when there is no image.
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

        // The body (and its plate) with the platform's drop shadow.
        context.saveGState()
        let shadow = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                             components: [0, 0, 0, shadowAlpha])
        context.setShadow(offset: CGSize(width: 0, height: -side * shadowOffsetFraction),
                          blur: side * shadowBlurFraction, color: shadow)
        context.addPath(shape)
        context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     components: [1, 1, 1, 1])!)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(shape)
        context.clip()

        if let layers {
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
        guard let cg = render(layers: layerImages(layers), flat: flat.flatMap(cgImage), px: px) else { return nil }
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
