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
    /// multiple of 16, then clamped to [320, 2560].
    static func displayPixels(bounds: CGSize, backingScale: Double) -> CGSize {
        func quantize(_ value: Double) -> Double {
            let scaled = value * backingScale
            let floored = (scaled / Double(granularity)).rounded(.down) * Double(granularity)
            return min(max(floored, Double(minDimension)), Double(maxDimension))
        }
        return CGSize(width: quantize(bounds.width), height: quantize(bounds.height))
    }

    /// dpi = 160 × backing scale × density. `density` is the user's ⌘+/⌘-/⌘0
    /// UI scale in 0.75…1.5 (1.0 default).
    static func dpi(backingScale: Double, density: Double) -> Double {
        160 * backingScale * density
    }
}

enum Letterbox {
    /// Aspect-fit rect of the video inside `bounds`, centered. Origin is the
    /// bottom-left (AppKit view coordinates) because callers pass view bounds.
    static func videoRect(video: CGSize, in bounds: CGRect) -> CGRect {
        guard video.width > 0, video.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
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

    private static func clamp(_ value: CGFloat) -> Float {
        Float(min(max(value, 0), 1))
    }
}
