// Display geometry math: virtual-display pixel size, dpi, and normalized
// coordinates with aspect-fit letterboxing. Pure functions so the unit tests
// pin the behaviour the task specifies.

import CoreGraphics
import Foundation

/// The encoder's own limits, reported by the phone at welcome (ISS-39). nil on
/// the Mac means the phone sent no report, and [`VideoSize`] keeps the old
/// 16 px / 2560 px rule.
struct EncoderSpec: Equatable {
    var widthAlign: Int
    var heightAlign: Int
    var maxWidth: Int
    var maxHeight: Int
    var maxPixelsAt60: Int

    init(widthAlign: Int, heightAlign: Int, maxWidth: Int, maxHeight: Int, maxPixelsAt60: Int) {
        self.widthAlign = widthAlign
        self.heightAlign = heightAlign
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.maxPixelsAt60 = maxPixelsAt60
    }

    /// `welcome.device.encoder`; a partial or malformed report is no report.
    init?(json: Any?) {
        guard let json = json as? [String: Any],
              let widthAlign = (json["widthAlign"] as? NSNumber)?.intValue,
              let heightAlign = (json["heightAlign"] as? NSNumber)?.intValue,
              let maxWidth = (json["maxWidth"] as? NSNumber)?.intValue,
              let maxHeight = (json["maxHeight"] as? NSNumber)?.intValue,
              let maxPixelsAt60 = (json["maxPixels60"] as? NSNumber)?.intValue,
              widthAlign > 0, heightAlign > 0, maxWidth > 0, maxHeight > 0, maxPixelsAt60 > 0
        else { return nil }
        self.init(widthAlign: widthAlign, heightAlign: heightAlign, maxWidth: maxWidth,
                  maxHeight: maxHeight, maxPixelsAt60: maxPixelsAt60)
    }
}

enum VideoSize {
    static let minDimension = 320
    static let maxDimension = 2560
    static let granularity = 16

    /// VD pixels = window content bounds (pt) × backing scale.
    ///
    /// With an encoder report (ISS-39) that is the window's exact backing
    /// pixels: rounded down to the codec's own alignment, never above its
    /// maximum or its 60 fps pixel count, the aspect kept when it has to scale.
    /// Without one, the old rule: floored to 16 and capped at 2560 px on the
    /// long side.
    ///
    /// `panelFactor` is M2's cap (panel width ÷ display backing width): it
    /// multiplies the backing pixels before the encoder's clamps, so a scaled
    /// display asks for no more than it can show. 1 is today's request.
    static func displayPixels(bounds: CGSize, backingScale: Double,
                              encoder: EncoderSpec? = nil,
                              panelFactor: Double = 1) -> CGSize {
        guard bounds.width > 0, bounds.height > 0 else {
            return CGSize(width: minDimension, height: minDimension)
        }
        let factor = panelFactor > 0 ? panelFactor : 1
        if let encoder {
            return reportedPixels(bounds: bounds, backingScale: backingScale * factor,
                                  encoder: encoder)
        }
        var width = bounds.width * backingScale * factor
        var height = bounds.height * backingScale * factor
        let longest = max(width, height)
        if longest > Double(maxDimension) {
            let scale = Double(maxDimension) / longest
            width *= scale
            height *= scale
        }
        return CGSize(width: quantize(width), height: quantize(height))
    }

    private static func reportedPixels(bounds: CGSize, backingScale: Double,
                                       encoder: EncoderSpec) -> CGSize {
        var width = bounds.width * backingScale
        var height = bounds.height * backingScale
        var factor = min(1, Double(encoder.maxWidth) / width, Double(encoder.maxHeight) / height)
        if encoder.maxPixelsAt60 > 0 {
            factor = min(factor, (Double(encoder.maxPixelsAt60) / (width * height)).squareRoot())
        }
        width *= factor
        height *= factor
        return CGSize(width: quantize(width, step: encoder.widthAlign, maximum: encoder.maxWidth),
                      height: quantize(height, step: encoder.heightAlign, maximum: encoder.maxHeight))
    }

    private static func quantize(_ value: Double, step: Int = granularity,
                                 maximum: Int = maxDimension) -> Double {
        let step = Double(max(1, step))
        let floored = (value / step).rounded(.down) * step
        return min(max(floored, Double(minDimension)), Double(maximum))
    }

    /// dpi = 160 × the VD's effective pixel ratio × density. The ratio comes from
    /// the actual VD size, so a capped size also lowers the density and the app
    /// lays out for exactly the window's dp size.
    static func dpi(pixels: CGSize, bounds: CGSize, density: Double) -> Double {
        guard bounds.width > 0, pixels.width > 0 else { return 160 * density }
        return 160 * Double(pixels.width) / Double(bounds.width) * density
    }
}

enum Letterbox {
    /// Aspect ratios closer than this are the same picture: a config of that
    /// shape answers a request (resizeStillPending), and a settled frame of
    /// that shape that is not the window's own pixels covers the view
    /// (`stretch`) rather than leaving bars.
    static let fillTolerance = 0.02

    /// True when the two shapes are the same picture within `fillTolerance`.
    static func sameShape(video: CGSize, bounds: CGSize) -> Bool {
        guard video.width > 0, video.height > 0, bounds.width > 0, bounds.height > 0 else { return false }
        let ratio = (video.width / video.height) / (bounds.width / bounds.height)
        return abs(ratio - 1) <= fillTolerance
    }

    /// How the last frame sits in the view. `fit` and `fill` keep the picture's
    /// aspect; `oneToOne` draws it at exactly one video pixel per screen pixel,
    /// anchored to the view's top-left; a frame 1 px short (an odd 1x size)
    /// leaves that pixel on the right and bottom edges. `stretch` covers the
    /// view with a settled frame of nearly its shape.
    enum Placement: Equatable {
        case fit
        case fill
        case oneToOne
        /// The whole frame over the whole view: a settled frame of nearly the
        /// view's shape that is not its own pixels (a phone that rounds to a
        /// coarser step, or the cap). No bars, every pixel kept.
        case stretch
    }

    /// The rule: (video, view, resize pending, phone mode) → how the frame is
    /// drawn.
    ///
    /// - The window's own pixels (at most 1 px short) are drawn 1:1: no
    ///   resampling.
    /// - While a resize is pending the app window crops the last frame to fill
    ///   it, so the drag shows no black bars until the phone answers with a
    ///   frame of the new shape.
    /// - A settled frame of nearly the view's shape that is not its own pixels
    ///   (a coarser encoder step, an older phone's 16 px floor, the cap) is
    ///   stretched over the view: no bars, under 2 % off in shape. Only a
    ///   settled frame of a clearly different shape is fitted.
    /// - The phone window mirrors a fixed screen and is never cropped by more
    ///   than a rendering artefact: a whole-point window size can leave the
    ///   fit under a point short at 2×, so a sub-point miss fills (a crop
    ///   under a pixel, ISS-65). Only a clearly different picture is fitted.
    static func placement(video: CGSize, bounds: CGSize, backingScale: Double = 1,
                          alignment: Int = VideoSize.granularity,
                          resizePending: Bool, phoneMode: Bool) -> Placement {
        guard video.width > 0, video.height > 0, bounds.width > 0, bounds.height > 0 else { return .fit }
        if phoneMode { return phonePlacement(video: video, bounds: bounds) }
        let backingWidth = bounds.width * CGFloat(max(backingScale, 1))
        let backingHeight = bounds.height * CGFloat(max(backingScale, 1))
        // The strip a 1:1 frame may leave is under one alignment step and
        // never more than 1 px (an odd 1x size at an even alignment): anything
        // wider shows as a black bar, which the person reported.
        let slack = CGFloat(min(max(1, alignment), 2))
        if video.width <= backingWidth, video.height <= backingHeight,
           backingWidth - video.width < slack, backingHeight - video.height < slack {
            return .oneToOne
        }
        if resizePending { return .fill }
        // Settled, nearly the view's shape, but not its own pixels: a phone
        // that rounds to a coarser step, or the encoder's cap. The frame covers
        // the view (no bars, every pixel kept, < 2 % off in shape).
        if sameShape(video: video, bounds: bounds) { return .stretch }
        return .fit
    }

    /// A phone-mode fit miss under one point is filled: it is the whole-point
    /// window sizing's rounding, not a picture of another shape, and at 2× it
    /// shows as a black row or column (ISS-65). Filling crops under a pixel.
    static let phoneFillSlack: CGFloat = 1

    static func phonePlacement(video: CGSize, bounds: CGSize) -> Placement {
        let slack = fitSlack(video: video, bounds: bounds)
        return max(slack.width, slack.height) < phoneFillSlack ? .fill : .fit
    }

    /// What a fit of `video` leaves uncovered on each axis, in bounds units.
    static func fitSlack(video: CGSize, bounds: CGSize) -> CGSize {
        guard video.width > 0, video.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / video.width, bounds.height / video.height)
        return CGSize(width: bounds.width - video.width * scale,
                      height: bounds.height - video.height * scale)
    }

    /// Where the video is drawn inside `bounds` for a placement. `fill` is
    /// centred and larger than `bounds` on one axis (the crop); `fit` is
    /// centred and inside it; `oneToOne` is the video's own pixel size in
    /// points, anchored to the top-left (the strip is right and bottom). Origin
    /// is the bottom-left (AppKit view coordinates) because callers pass view
    /// bounds.
    static func videoRect(video: CGSize, in bounds: CGRect, placement: Placement,
                          backingScale: Double = 1) -> CGRect {
        guard video.width > 0, video.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        switch placement {
        case .stretch:
            return bounds
        case .oneToOne:
            let scale = CGFloat(max(backingScale, 1))
            func snapped(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
            let size = CGSize(width: snapped(video.width / scale), height: snapped(video.height / scale))
            return CGRect(x: snapped(bounds.minX), y: snapped(bounds.maxY - size.height),
                          width: size.width, height: size.height)
        case .fit:
            let scale = min(bounds.width / video.width, bounds.height / video.height)
            let size = CGSize(width: video.width * scale, height: video.height * scale)
            return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                          width: size.width, height: size.height)
        case .fill:
            let scale = max(bounds.width / video.width, bounds.height / video.height)
            let size = CGSize(width: video.width * scale, height: video.height * scale)
            return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                          width: size.width, height: size.height)
        }
    }

    /// The drawn rect with the outer rule (no resize pending, app window): the
    /// window's own pixels 1:1, a strip when the phone is one alignment step
    /// short, else aspect-fit and centred.
    static func videoRect(video: CGSize, in bounds: CGRect, backingScale: Double = 1,
                          alignment: Int = VideoSize.granularity) -> CGRect {
        let placement = placement(video: video, bounds: bounds.size, backingScale: backingScale,
                                  alignment: alignment, resizePending: false, phoneMode: false)
        return videoRect(video: video, in: bounds, placement: placement, backingScale: backingScale)
    }

    /// Whether the pending fill is still up. While the window is being resized
    /// (a drag or the zoom animation) only a config at the requested size ends
    /// it: an older picture whose aspect is still within `fillTolerance` would
    /// otherwise stop the fill for a frame and flash a letterbox mid-resize.
    /// Settled, the tolerance is the normal rule.
    static func resizeStillPending(video: CGSize, request: CGSize, liveResizing: Bool,
                                   alignment: Int = VideoSize.granularity) -> Bool {
        guard video.width > 0, video.height > 0, request.width > 0, request.height > 0 else {
            return true
        }
        if liveResizing {
            let step = CGFloat(max(1, alignment))
            return !(abs(video.width - request.width) <= step
                     && abs(video.height - request.height) <= step)
        }
        return !answers(config: video, request: request, alignment: alignment)
    }

    /// True when `config` answers `request`: the window asks for its pixels
    /// rounded to the encoder's alignment, and the phone may answer one step
    /// off on each axis, or with the same aspect within `fillTolerance`. Until
    /// it does, a resize is still pending.
    static func answers(config: CGSize, request: CGSize, alignment: Int = VideoSize.granularity) -> Bool {
        guard config.width > 0, config.height > 0, request.width > 0, request.height > 0 else { return false }
        let step = CGFloat(max(1, alignment))
        if abs(config.width - request.width) <= step, abs(config.height - request.height) <= step {
            return true
        }
        let ratio = (config.width / config.height) / (request.width / request.height)
        return abs(ratio - 1) <= fillTolerance
    }

    /// Normalize a point in view coordinates to the video's [0,1] coordinates
    /// with a top-left origin, clamped to 0…1. `flipped` is the view's
    /// `isFlipped` (true = y grows downward).
    static func normalized(point: CGPoint, videoRect: CGRect, flipped: Bool) -> (nx: Float, ny: Float) {
        let w = max(videoRect.width, 1)
        let h = max(videoRect.height, 1)
        let u = (point.x - videoRect.minX) / w
        let rawY = flipped ? (point.y - videoRect.minY) / h : 1 - (point.y - videoRect.minY) / h
        return (clamp(u), clamp(rawY))
    }

    /// The view point of a video-space point (0...1, top-left origin): the
    /// inverse of `normalized`, for drawing at a position the phone knows.
    static func viewPoint(nx: Float, ny: Float, videoRect: CGRect, flipped: Bool) -> CGPoint {
        let x = videoRect.minX + CGFloat(nx) * videoRect.width
        let y = flipped
            ? videoRect.minY + CGFloat(ny) * videoRect.height
            : videoRect.minY + (1 - CGFloat(ny)) * videoRect.height
        return CGPoint(x: x, y: y)
    }

    private static func clamp(_ value: CGFloat) -> Float {
        Float(min(max(value, 0), 1))
    }
}
