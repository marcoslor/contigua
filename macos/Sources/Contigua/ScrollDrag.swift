// A phased trackpad scroll as one finger dragging on the phone.
//
// The wheel path (SCROLL frames) makes Android scroll by a distance. A finger
// makes Android's own touch machinery run: slop, drag, overscroll glow and the
// fling that follows the lift. So a two-finger trackpad scroll is sent as
// DOWN at the cursor, one MOVE per scroll event and an UP, with the fling left
// to Android. AppKit's momentum events are dropped for that reason.
//
// Pure logic: scroll samples in, TOUCH events out. The phone stamps events when
// they arrive, so the cadence of the Mac's scroll events is the cadence Android
// computes its velocity from: nothing here delays, merges or reorders them.

import AppKit

/// What one NSEvent scroll wheel event carries, without the NSEvent.
struct ScrollSample: Equatable {
    var phase: NSEvent.Phase
    var momentum: NSEvent.Phase
    var precise: Bool
    var deltaX: Double
    var deltaY: Double

    init(phase: NSEvent.Phase, momentum: NSEvent.Phase = [], precise: Bool = true,
         deltaX: Double = 0, deltaY: Double = 0) {
        self.phase = phase
        self.momentum = momentum
        self.precise = precise
        self.deltaX = deltaX
        self.deltaY = deltaY
    }

    /// A mouse wheel: line units, or no gesture phase at all. It stays a SCROLL frame.
    var isWheel: Bool { !precise || (phase.isEmpty && momentum.isEmpty) }
    var isMomentum: Bool { phase.isEmpty && !momentum.isEmpty }
}

struct ScrollDrag {
    /// A drag that moved less than this (view points) is released as CANCEL:
    /// Android would read DOWN + UP inside its touch slop as a tap.
    static let minTravel: CGFloat = 12

    private(set) var isActive = false
    private var nx: Double = 0
    private var ny: Double = 0
    private var startNx: Double = 0
    private var startNy: Double = 0
    private var travelX: CGFloat = 0
    private var travelY: CGFloat = 0
    private var size = CGSize(width: 1, height: 1)

    /// Where the pointer is now (normalized video coordinates).
    var position: (nx: Float, ny: Float) { (Float(nx), Float(ny)) }

    /// DOWN at the cursor. `videoSize` is the video's size in view points; a
    /// scroll delta of 1 pt moves the finger 1 pt, which is 1 dp on the phone.
    mutating func begin(at start: (nx: Float, ny: Float), videoSize: CGSize) -> [TouchEvent] {
        var events: [TouchEvent] = []
        if isActive { events += cancel() }
        isActive = true
        nx = Double(start.nx)
        ny = Double(start.ny)
        startNx = nx
        startNy = ny
        travelX = 0
        travelY = 0
        size = Self.usable(videoSize)
        events.append(TouchEvent(action: .down, pointerId: 0, nx: start.nx, ny: start.ny))
        return events
    }

    /// One MOVE for the scroll event; nothing for a zero delta. AppKit's deltas
    /// already follow the user's natural-scrolling setting: a positive vertical
    /// delta means the content moves down, so the finger moves down (ny grows).
    mutating func move(deltaX: Double, deltaY: Double, videoSize: CGSize) -> [TouchEvent] {
        guard isActive, deltaX != 0 || deltaY != 0 else { return [] }
        size = Self.usable(videoSize)
        nx = min(max(nx + deltaX / Double(size.width), 0), 1)
        ny = min(max(ny + deltaY / Double(size.height), 0), 1)
        travelX = CGFloat((nx - startNx)) * size.width
        travelY = CGFloat((ny - startNy)) * size.height
        return [moveEvent()]
    }

    /// The fingers lifted: UP at the last position, or CANCEL for a drag too
    /// short to be a scroll.
    mutating func end() -> [TouchEvent] {
        guard isActive else { return [] }
        isActive = false
        let travelled = hypot(travelX, travelY)
        return [TouchEvent(action: travelled >= Self.minTravel ? .up : .cancel, pointerId: 0,
                           nx: Float(nx), ny: Float(ny))]
    }

    mutating func cancel() -> [TouchEvent] {
        guard isActive else { return [] }
        isActive = false
        return [TouchEvent(action: .cancel, pointerId: 0, nx: Float(nx), ny: Float(ny))]
    }

    private func moveEvent() -> TouchEvent {
        TouchEvent(action: .move, pointerId: 0, nx: Float(nx), ny: Float(ny))
    }

    private static func usable(_ size: CGSize) -> CGSize {
        CGSize(width: max(size.width, 1), height: max(size.height, 1))
    }
}
