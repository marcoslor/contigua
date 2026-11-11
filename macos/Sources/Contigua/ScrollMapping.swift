// Scroll events -> the SCROLL frame's Android wheel units (docs/PROTOCOL.md).
//
// Direction: AppKit's scrolling deltas already follow the user's natural-
// scrolling setting (it is applied before the event reaches a view), so a
// positive vertical delta always means "content moves down", which is what a
// positive AXIS_VSCROLL means on Android. Passing the sign through is what
// native apps do; nothing here reads the setting. Horizontal is the other
// way round: a positive AppKit delta moves content right, a positive
// AXIS_HSCROLL moves it left.
//
// Scale: a trackpad reports points, and one point is one dp in a stream
// window, so `pointsPerUnit` is the distance one wheel unit scrolls in apps
// (Android's default scroll factor, 64 dp). A mouse wheel reports lines and
// keeps its acceleration: a line is a unit.

import AppKit

struct ScrollMapping {
    static let pointsPerUnit = 64.0
    /// A fast flick of a wheel can report dozens of lines in one event.
    static let maxLineUnits = 8.0

    struct Units: Equatable {
        var hscroll: Float
        var vscroll: Float
    }

    /// Precise deltas smaller than a point would be truncated away by the
    /// app's pixel conversion; they are carried to the next event instead.
    private var carryX = 0.0
    private var carryY = 0.0

    mutating func map(deltaX: Double, deltaY: Double, precise: Bool, phase: NSEvent.Phase) -> Units? {
        if phase.contains(.began) || phase.contains(.mayBegin) {
            carryX = 0
            carryY = 0
        }
        var x = deltaX
        var y = deltaY
        if precise {
            carryX += x
            carryY += y
            x = carryX.rounded(.towardZero)
            y = carryY.rounded(.towardZero)
            carryX -= x
            carryY -= y
            x /= Self.pointsPerUnit
            y /= Self.pointsPerUnit
        } else {
            x = min(max(x, -Self.maxLineUnits), Self.maxLineUnits)
            y = min(max(y, -Self.maxLineUnits), Self.maxLineUnits)
        }
        guard x != 0 || y != 0 else { return nil }
        return Units(hscroll: Float(-x), vscroll: Float(y))
    }
}
