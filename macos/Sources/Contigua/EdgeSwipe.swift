// Trackpad edge gestures. A clearly horizontal two-finger swipe that starts in
// the window's left edge strip is the Android "back" gesture (KEYCODE_BACK on
// the virtual display). Everything else stays normal scrolling: a gesture that
// starts anywhere else is never considered, and one that turns out mostly
// vertical falls through to the app.
//
// Direction is not part of the contract: the sign of a scroll delta flips with
// the user's natural-scrolling setting, and the strip itself is the reserved
// part of the window. The classifier is pure so the unit tests pin the rules;
// the view only feeds it scroll deltas and phases.

import CoreGraphics

struct EdgeSwipeClassifier {
    enum Decision: Equatable {
        /// Not tracking this gesture; forward the event to the app.
        case ignore
        /// Might still become a back gesture; swallow it for now.
        case hold
        /// Recognized: send exactly one `nav back`.
        case trigger
        /// Clearly not a back gesture; forward from here on.
        case passThrough
    }

    /// The reserved strip at the left edge of the content.
    static let edgeWidth: CGFloat = 24
    /// Horizontal travel needed before it counts as a swipe.
    static let triggerDistance: CGFloat = 60
    /// The gesture must stay this horizontal: |vertical| <= ratio * |horizontal|.
    static let verticalRatio: CGFloat = 0.6
    /// Vertical travel that abandons tracking early (a scroll, not a swipe).
    static let verticalGiveUp: CGFloat = 30

    private(set) var isTracking = false
    private(set) var didTrigger = false
    private var horizontal: CGFloat = 0
    private var vertical: CGFloat = 0

    /// `point` is in the view's coordinate system. Returns true while the
    /// gesture should be tracked (and swallowed until it is classified).
    mutating func begin(at point: CGPoint, in bounds: CGRect) -> Bool {
        reset()
        guard bounds.contains(point), point.x <= bounds.minX + Self.edgeWidth else { return false }
        isTracking = true
        return true
    }

    /// Feed one scroll delta (points; the sign follows the system setting).
    mutating func update(horizontal dx: CGFloat, vertical dy: CGFloat) -> Decision {
        guard isTracking else { return .ignore }
        if didTrigger { return .hold }
        horizontal += dx
        vertical += dy
        if abs(horizontal) >= Self.triggerDistance, abs(vertical) <= Self.verticalRatio * abs(horizontal) {
            didTrigger = true
            return .trigger
        }
        if abs(vertical) > Self.verticalGiveUp, abs(vertical) > abs(horizontal) {
            isTracking = false
            return .passThrough
        }
        return .hold
    }

    mutating func end() { reset() }

    private mutating func reset() {
        isTracking = false
        didTrigger = false
        horizontal = 0
        vertical = 0
    }
}
