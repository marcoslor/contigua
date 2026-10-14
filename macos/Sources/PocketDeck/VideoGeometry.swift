// Display geometry math: virtual-display pixel size, dpi, and normalized
// coordinates with aspect-fit letterboxing. Pure functions so the unit tests
// pin the behaviour the task specifies.

import CoreGraphics
import Foundation

enum VideoSize {
    static let minDimension = 320
    static let maxDimension = 2560
    static let granularity = 16

    /// VD pixels = window content bounds (pt) × backing scale, floored to a
    /// multiple of 16 and clamped to [320, 2560]. When one axis would exceed the
    /// maximum, both are scaled together so the video keeps the window's aspect
    /// ratio: an ultra-wide or very tall window fills the view instead of being
    /// letterboxed by a capped codec size.
    static func displayPixels(bounds: CGSize, backingScale: Double) -> CGSize {
        guard bounds.width > 0, bounds.height > 0 else {
            return CGSize(width: minDimension, height: minDimension)
        }
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

    private static func quantize(_ value: Double) -> Double {
        let floored = (value / Double(granularity)).rounded(.down) * Double(granularity)
        return min(max(floored, Double(minDimension)), Double(maxDimension))
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
    /// Aspect ratios closer than this are the same picture: the virtual display
    /// is the window floored to 16 px, which would otherwise leave thin bars.
    static let fillTolerance = 0.02

    /// True when the video is stretched over the whole of `bounds`.
    static func fills(video: CGSize, bounds: CGSize) -> Bool {
        guard video.width > 0, video.height > 0, bounds.width > 0, bounds.height > 0 else { return false }
        let ratio = (video.width / video.height) / (bounds.width / bounds.height)
        return abs(ratio - 1) <= fillTolerance
    }

    /// Where the video is drawn inside `bounds`: all of it when the aspect
    /// ratios only differ by the 16 px quantisation, else aspect-fit and centred.
    /// Origin is the bottom-left (AppKit view coordinates) because callers pass view bounds.
    static func videoRect(video: CGSize, in bounds: CGRect) -> CGRect {
        guard video.width > 0, video.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        if fills(video: video, bounds: bounds.size) { return bounds }
        let scale = min(bounds.width / video.width, bounds.height / video.height)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
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
