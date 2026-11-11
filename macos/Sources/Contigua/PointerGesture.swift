// Pinch/rotate geometry: where the two TOUCH pointers of a trackpad gesture
// sit in the stream's video. Pure math, so the tests pin the scale, the
// rotation direction and the clamping the phone ends up seeing.

import CoreGraphics
import Foundation

/// A two-pointer gesture around a fixed anchor. Pointer 0 and pointer 1 stay
/// symmetric around it; the pair starts on the video's shorter axis, half a
/// span of 0.08 of that side from the anchor. `magnification` and `rotation`
/// accumulate the event deltas (NSEvent reports both as increments).
struct PointerGesture {
    /// Half the start distance between the pointers, in shorter-side units.
    static let initialHalfSpan = 0.08

    let anchorNx: Double
    let anchorNy: Double
    let videoWidth: Double
    let videoHeight: Double

    private(set) var magnification: Double = 0
    private(set) var rotationDegrees: Double = 0

    init(anchorNx: Double, anchorNy: Double, videoSize: CGSize) {
        self.anchorNx = anchorNx
        self.anchorNy = anchorNy
        self.videoWidth = videoSize.width > 0 ? Double(videoSize.width) : 1
        self.videoHeight = videoSize.height > 0 ? Double(videoSize.height) : 1
    }

    mutating func add(magnification delta: Double) {
        magnification += delta
    }

    mutating func add(rotation delta: Double) {
        rotationDegrees += delta
    }

    /// Pointer positions in normalized video coordinates, clamped to the video.
    /// A counter-clockwise rotation on screen (macOS-positive) decreases the
    /// angle in the video's y-down coordinates.
    var points: (zero: (nx: Float, ny: Float), one: (nx: Float, ny: Float)) {
        let halfSpan = Self.initialHalfSpan * min(videoWidth, videoHeight) * (1 + magnification)
        let base = videoWidth > videoHeight ? Double.pi / 2 : 0
        let angle = base - rotationDegrees * .pi / 180
        let dx = cos(angle) * halfSpan
        let dy = sin(angle) * halfSpan
        let cx = anchorNx * videoWidth
        let cy = anchorNy * videoHeight
        return (zero: Self.clamped(x: cx + dx, y: cy + dy, width: videoWidth, height: videoHeight),
                one: Self.clamped(x: cx - dx, y: cy - dy, width: videoWidth, height: videoHeight))
    }

    private static func clamped(x: Double, y: Double, width: Double, height: Double)
        -> (nx: Float, ny: Float) {
        (nx: Float(min(max(x / width, 0), 1)), ny: Float(min(max(y / height, 0), 1)))
    }
}
