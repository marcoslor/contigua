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
    static func displayPixels(bounds: CGSize, backingScale: Double,
                              encoder: EncoderSpec? = nil) -> CGSize {
        guard bounds.width > 0, bounds.height > 0 else {
            return CGSize(width: minDimension, height: minDimension)
        }
        if let encoder { return reportedPixels(bounds: bounds, backingScale: backingScale, encoder: encoder) }
        var width = bounds.width * backingScale
        var height = bounds.height * backingScale
        let longest = max(width, height)
        if longest > Double(maxDimension) {
            let factor = Double(maxDimension) / longest
            width *= factor
            height *= factor
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
    /// Aspect ratios closer than this are the same picture when deciding
    /// whether a config answers a request (resizeStillPending). It no longer
    /// decides how the frame is drawn: a difference that is not the window's
    /// own pixels is never stretched (ISS-39).
    static let fillTolerance = 0.02

    /// How the last frame sits in the view. `fit` and `fill` keep the picture's
    /// aspect; `oneToOne` draws it at exactly one video pixel per screen pixel,
    /// anchored to the view's top-left. A frame one alignment step short leaves
    /// the strip on the right and bottom edges, in the window's background.
    enum Placement: Equatable {
        case fit
        case fill
        case oneToOne
    }

    /// The rule: (video, view, resize pending, phone mode) → how the frame is
    /// drawn.
    ///
    /// - The window's own pixels (within one encoder alignment step) are drawn
    ///   1:1: no resampling, and a short frame leaves a strip rather than
    ///   stretching every pixel.
    /// - While a resize is pending the app window crops the last frame to fill
    ///   it, so the drag shows no black bars until the phone answers with a
    ///   frame of the new shape. A settled frame that is far from the view is
    ///   fitted, and so is the over-the-cap case, which is the only time a
    ///   settled picture is scaled.
    /// - The phone window mirrors a fixed screen: its letterbox is never
    ///   cropped, pending or not.
    static func placement(video: CGSize, bounds: CGSize, backingScale: Double = 1,
                          alignment: Int = VideoSize.granularity,
                          resizePending: Bool, phoneMode: Bool) -> Placement {
        guard video.width > 0, video.height > 0, bounds.width > 0, bounds.height > 0 else { return .fit }
        if phoneMode { return .fit }
        let backingWidth = bounds.width * CGFloat(max(backingScale, 1))
        let backingHeight = bounds.height * CGFloat(max(backingScale, 1))
        let step = CGFloat(max(1, alignment))
        if video.width <= backingWidth, video.height <= backingHeight,
           backingWidth - video.width < step, backingHeight - video.height < step {
            return .oneToOne
        }
        if resizePending { return .fill }
        return .fit
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
