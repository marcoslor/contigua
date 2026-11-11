// The notification attachment's app badge (NOTIFY-22, docs/design/notify.md
// § "The attachment's app badge"): a picture cut to a circle with the sender's
// icon at its bottom-right, or the icon alone as a rounded square. Pure
// CoreGraphics: no appearance reads and no AppKit globals, so the same pixels
// are drawn in light and dark.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum NotifyAttachmentComposer {
    /// A picture's attachment side, and the ceiling.
    static let maxSide = 512
    /// The icon-alone attachment's side.
    static let iconSide = 256
    /// The badge's share of the side, inset from the bottom-right corner.
    static let badgeFraction: CGFloat = 0.40
    static let badgeInsetFraction: CGFloat = 0.045
    /// The icon-alone tile's corner, as a share of its side.
    static let iconCornerFraction: CGFloat = 0.22
    /// docs/NFR.md `icon_covered_flat_scale`: the most a render may enlarge its
    /// source (the Deck's and Dock's bound).
    static let maxUpscale = 1.3
    /// A composed attachment is held inside the phone picture's own 200 KiB
    /// budget (NOTIFY-11), and the Mac's `NotifyImageCaps`.
    static let maxBytes = 200 * 1024

    enum Shape: String {
        case circle
        case icon
    }

    /// Why no composed attachment was made. A closed set, so a log line never
    /// carries a string from outside.
    enum Fallback: String {
        case noIcon = "no_icon"
        case overCap = "over_cap"
        case render = "render"
    }

    /// One cached size class of the app's icon: the adaptive layers or the flat
    /// image, exactly what the Deck and Dock render.
    struct IconCandidate {
        var layers: (fg: CGImage, bg: CGImage)?
        var flat: CGImage?
        var sizeClass: IconSizeClass
    }

    struct Icon {
        /// Best first: the Deck's slot before the Dock's.
        var candidates: [IconCandidate]
    }

    struct ComposedAttachment {
        var mime: String
        var side: Int
        var shape: Shape
        var badge: Bool
        var sizeClass: IconSizeClass?
        var data: Data

        /// Facts only (R-PRIV-1): shape, side, badge and the size class.
        var record: String {
            "composed shape=\(shape.rawValue) badge=\(badge ? "yes" : "no")"
                + " side=\(side) class=\(sizeClass?.rawValue ?? "none")"
        }
    }

    struct Outcome {
        var attachment: ComposedAttachment?
        var fallback: Fallback?

        /// The record line's composition facts: the attachment's own, or why
        /// there is none.
        var record: String {
            attachment?.record ?? "composed fallback=\((fallback ?? .render).rawValue)"
        }
    }

    /// The cached icon bytes as an image. ImageIO only, so a caller can decode
    /// without AppKit.
    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The attachment for one post: the picture as a circle with the app's
    /// badge, the icon alone in a rounded square, or `nil` with the reason.
    static func compose(picture: CGImage?, icon: Icon?) -> Outcome {
        guard let picture else {
            guard let (candidate, image) = usable(icon, at: iconSide) else {
                return Outcome(attachment: nil, fallback: .noIcon)
            }
            let side = iconSide
            let rect = CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side))
            guard let png = render(side: side, { context in
                context.saveGState()
                context.addPath(CGPath(roundedRect: rect,
                                       cornerWidth: rect.width * iconCornerFraction,
                                       cornerHeight: rect.height * iconCornerFraction,
                                       transform: nil))
                context.clip()
                context.draw(image, in: bodyFill(rect))
                context.restoreGState()
            }), fits(png, side: side) else {
                return Outcome(attachment: nil, fallback: .overCap)
            }
            return Outcome(attachment: ComposedAttachment(
                mime: "image/png", side: side, shape: .icon, badge: false,
                sizeClass: candidate.sizeClass, data: png,
            ), fallback: nil)
        }
        let side = min(maxSide, max(picture.width, picture.height))
        guard side > 0 else { return Outcome(attachment: nil, fallback: .render) }
        let badgeSide = CGFloat(side) * badgeFraction
        let inset = CGFloat(side) * badgeInsetFraction
        let badge = Int(badgeSide.rounded())
        let picked = usable(icon, at: badge)
        let canvas = CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side))
        guard let png = render(side: side, { context in
            // The picture fills the square and is cut to a circle.
            context.saveGState()
            context.addEllipse(in: canvas)
            context.clip()
            drawCover(picture, in: canvas, context: context)
            context.restoreGState()
            guard let (_, image) = picked else { return }
            // The app's icon on its own, no ring: a circle at the bottom-right.
            let rect = CGRect(x: canvas.maxX - badgeSide - inset, y: inset,
                              width: badgeSide, height: badgeSide)
            context.saveGState()
            context.addEllipse(in: rect)
            context.clip()
            context.draw(image, in: bodyFill(rect))
            context.restoreGState()
        }), fits(png, side: side) else {
            // Over the caps: the caller keeps the phone's picture uncomposed.
            return Outcome(attachment: nil, fallback: .overCap)
        }
        return Outcome(attachment: ComposedAttachment(
            mime: "image/png", side: side, shape: .circle, badge: picked != nil,
            sizeClass: picked?.0.sizeClass, data: png,
        ), fallback: nil)
    }

    // MARK: drawing

    /// The renderer's canvas has the platform's margin around the icon's body;
    /// growing the target by that margin makes the body fill it.
    private static func bodyFill(_ rect: CGRect) -> CGRect {
        let grow = rect.width * (1 / PhoneAppIcon.bodyFraction - 1) / 2
        return rect.insetBy(dx: -grow, dy: -grow)
    }

    private static func drawCover(_ image: CGImage, in rect: CGRect, context: CGContext) {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard width > 0, height > 0 else { return }
        let scale = max(rect.width / width, rect.height / height)
        let size = CGSize(width: width * scale, height: height * scale)
        context.draw(image, in: CGRect(x: rect.midX - size.width / 2,
                                       y: rect.midY - size.height / 2,
                                       width: size.width, height: size.height))
    }

    /// The first candidate that renders at `px` without enlarging its source
    /// more than the Deck's and Dock's bound.
    private static func usable(_ icon: Icon?, at px: Int) -> (IconCandidate, CGImage)? {
        guard px > 0 else { return nil }
        for candidate in icon?.candidates ?? [] {
            guard sourceScale(candidate, at: px) <= maxUpscale else { continue }
            guard let image = PhoneAppIcon.render(layers: candidate.layers, flat: candidate.flat,
                                                 px: px) else { continue }
            return (candidate, image)
        }
        return nil
    }

    /// How much a render at `px` enlarges the cached source. Drawing the body
    /// full cancels the canvas margin, so the factors are the renderer's own:
    /// layers at 1.5× the body, a covered flat's crop, a plate flat at 78 %.
    private static func sourceScale(_ candidate: IconCandidate, at px: Int) -> Double {
        let needed = Double(px)
        if let layers = candidate.layers {
            return 1.5 * needed / Double(layers.fg.width)
        }
        guard let flat = candidate.flat else { return .infinity }
        if let pixels = PhoneAppIcon.bitmap(flat),
           case .cover(let crop) = PhoneAppIcon.flatFit(alpha: pixels.alpha) {
            return needed / (Double(crop.width) * Double(flat.width))
        }
        return Double(PhoneAppIcon.legacyInsetFraction) * needed / Double(flat.width)
    }

    private static func render(side: Int, _ draw: (CGContext) -> Void) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.setShouldAntialias(true)
        draw(context)
        guard let image = context.makeImage() else { return nil }
        return png(image)
    }

    private static func png(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil,
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// The Mac's own caps, plus the 200 KiB composition budget.
    private static func fits(_ png: Data, side: Int) -> Bool {
        guard png.count <= maxBytes else { return false }
        return NotifyImageCaps.refusal(mime: "image/png", width: side, height: side,
                                       decoded: png.count) == nil
    }
}
