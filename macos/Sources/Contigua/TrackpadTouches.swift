// Raw trackpad fingers -> Android pointers.
//
// NSTouch reports each finger's normalizedPosition (0...1 across the surface,
// origin bottom-left) and the surface's deviceSize. Physical distance is what
// a pinch is about, so fingers are first converted to millimetres; the pointers
// are then the fingers' displacement from where the two-finger gesture started,
// scaled to window points, around the cursor. The cursor, not the finger
// position on the pad, says where in the app the gesture happens.

import CoreGraphics
import Foundation

/// An NSTouch without the NSTouch: `id` identifies the finger for as long as it
/// touches, x/y are `normalizedPosition`.
struct TrackpadFinger: Equatable {
    var id: Int
    var x: Double
    var y: Double
}

struct TrackpadSurface: Equatable {
    /// NSTouch.deviceSize is in points of 1/72 inch.
    var widthPoints: Double
    var heightPoints: Double

    static let millimetresPerPoint = 25.4 / 72

    /// A Magic Trackpad 2 (160 × 115 mm), for a surface that reports no size.
    static let fallback = TrackpadSurface(widthPoints: 160 / millimetresPerPoint,
                                          heightPoints: 115 / millimetresPerPoint)

    init(widthPoints: Double, heightPoints: Double) {
        self.widthPoints = widthPoints > 0 ? widthPoints : 160 / Self.millimetresPerPoint
        self.heightPoints = heightPoints > 0 ? heightPoints : 115 / Self.millimetresPerPoint
    }

    /// The finger's position on the surface in millimetres, origin bottom-left.
    func millimetres(_ finger: TrackpadFinger) -> CGPoint {
        CGPoint(x: finger.x * widthPoints * Self.millimetresPerPoint,
                y: finger.y * heightPoints * Self.millimetresPerPoint)
    }
}

/// Decides, from the first millimetres of a two-finger gesture, whether it is a
/// pan (the fingers travel together: a scroll) or a pinch/rotate (the fingers
/// travel relative to each other). The two travel scores are compared in
/// millimetres; whichever is larger wins once either passes `commitDistance`.
struct TwoFingerClassifier {
    enum Verdict: Equatable { case undecided, pan, pinch }

    static let commitDistance = 2.0

    private var start: (a: CGPoint, b: CGPoint)?
    private var startIds: (Int, Int)?

    mutating func begin(_ fingers: [TrackpadFinger], surface: TrackpadSurface) {
        guard fingers.count == 2 else { start = nil; return }
        let ordered = fingers.sorted { $0.id < $1.id }
        start = (surface.millimetres(ordered[0]), surface.millimetres(ordered[1]))
        startIds = (ordered[0].id, ordered[1].id)
    }

    func verdict(_ fingers: [TrackpadFinger], surface: TrackpadSurface) -> Verdict {
        guard let start, let startIds, fingers.count == 2 else { return .undecided }
        let ordered = fingers.sorted { $0.id < $1.id }
        guard (ordered[0].id, ordered[1].id) == startIds else { return .undecided }
        let a = surface.millimetres(ordered[0])
        let b = surface.millimetres(ordered[1])
        let pan = hypot((a.x + b.x) / 2 - (start.a.x + start.b.x) / 2,
                        (a.y + b.y) / 2 - (start.a.y + start.b.y) / 2)
        let startSpan = distance(start.a, start.b)
        let span = distance(a, b)
        let spread = abs(span - startSpan)
        // Arc length swept at the fingers' radius: comparable to the others in mm.
        let turned = abs(Self.wrapped(angle(a, b) - angle(start.a, start.b)))
        let arc = turned * startSpan / 2
        let pinch = max(spread, arc)
        guard max(pan, pinch) >= Self.commitDistance else { return .undecided }
        return pinch >= pan ? .pinch : .pan
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
    private func angle(_ a: CGPoint, _ b: CGPoint) -> Double { atan2(b.y - a.y, b.x - a.x) }

    static func wrapped(_ angle: Double) -> Double {
        var value = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if value > .pi { value -= 2 * .pi }
        if value < -.pi { value += 2 * .pi }
        return value
    }
}

/// Two fingers as two Android pointers anchored at the cursor.
struct TrackpadPinch {
    /// About 1 mm of finger travel is 4 window points. A pinch from 20 mm to
    /// 60 mm apart becomes 80 → 240 points on the phone (1 pt is 1 dp), the
    /// spread an Android map wants for a double-zoom. Tunable.
    static let defaultPointsPerMillimetre = 4.0

    struct Pointer: Equatable {
        var id: UInt8
        /// In the video view's coordinates (points).
        var point: CGPoint
    }

    let anchor: CGPoint
    let pointsPerMillimetre: Double
    private let surface: TrackpadSurface
    private let startCentroid: CGPoint
    private let ids: (Int, Int)
    /// A flipped view grows its y downward while the trackpad grows upward.
    private let flipped: Bool

    init?(fingers: [TrackpadFinger], surface: TrackpadSurface, anchor: CGPoint, flipped: Bool = false,
          pointsPerMillimetre: Double = Self.defaultPointsPerMillimetre) {
        guard fingers.count == 2 else { return nil }
        let ordered = fingers.sorted { $0.id < $1.id }
        let a = surface.millimetres(ordered[0])
        let b = surface.millimetres(ordered[1])
        self.anchor = anchor
        self.surface = surface
        self.flipped = flipped
        self.pointsPerMillimetre = pointsPerMillimetre
        self.ids = (ordered[0].id, ordered[1].id)
        self.startCentroid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    /// Pointer 0 and 1 for the current fingers; nil when these are not the
    /// fingers the gesture started with.
    func pointers(for fingers: [TrackpadFinger]) -> [Pointer]? {
        guard fingers.count == 2 else { return nil }
        let ordered = fingers.sorted { $0.id < $1.id }
        guard (ordered[0].id, ordered[1].id) == ids else { return nil }
        return ordered.enumerated().map { index, finger in
            let mm = surface.millimetres(finger)
            let dx = (mm.x - startCentroid.x) * pointsPerMillimetre
            let dy = (mm.y - startCentroid.y) * pointsPerMillimetre
            return Pointer(id: UInt8(index),
                           point: CGPoint(x: anchor.x + dx, y: anchor.y + (flipped ? -dy : dy)))
        }
    }
}
