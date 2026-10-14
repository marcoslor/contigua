// Who owns the trackpad: the scroll path or the raw-touch path.
//
// Two fingers on a trackpad make AppKit send two independent streams: phased
// scroll events (a two-finger drag) and, to a view that asks for indirect
// touches, the raw fingers. They describe the same gesture, so exactly one of
// them may reach the phone:
//
//   fingers land      -> `undecided`: scroll events are held back
//   fingers travel    -> TwoFingerClassifier says pan or pinch (a few mm)
//   pan               -> the held scroll deltas and the following ones drive a
//                        one-finger drag (ScrollDrag); raw fingers are ignored
//   pinch             -> two pointers from the raw fingers (TrackpadPinch);
//                        scroll, magnify and rotate events are ignored
//   one finger lifts  -> the pointers go up; nothing more until all fingers
//                        are off again
//   three or more     -> cancelled and ignored; macOS keeps them for Spaces,
//                        Mission Control and the like
//
// A Mac whose view never receives raw touches (`touchesAvailable` stays false)
// takes the scroll path straight away, and magnify/rotate events fall back to
// the coarse two-pointer emulation (PointerGesture) kept in InputMapper.
//
// Pure logic: events in, TOUCH events out.

import AppKit

struct TrackpadGestures {
    /// Where a gesture happens: the video's rectangle in view points.
    struct Space {
        var videoRect: CGRect
        var flipped = false

        func normalized(_ point: CGPoint) -> (nx: Float, ny: Float) {
            Letterbox.normalized(point: point, videoRect: videoRect, flipped: flipped)
        }
    }

    struct Output: Equatable {
        /// The event is a wheel notch: map it to a SCROLL frame.
        var wheel = false
        var touches: [TouchEvent] = []
    }

    /// Window points per millimetre of finger travel.
    var pointsPerMillimetre = TrackpadPinch.defaultPointsPerMillimetre

    /// Raw fingers have been seen on this view.
    private(set) var touchesAvailable = false
    private(set) var fingerCount = 0

    private enum Owner { case idle, undecided, pan, pinch, blocked }
    private var owner = Owner.idle

    private var fingers: [TrackpadFinger] = []
    private var landing: [TrackpadFinger] = []
    private var surface = TrackpadSurface.fallback
    private var classifier = TwoFingerClassifier()
    /// The cursor when the second finger landed: where the gesture happens.
    private var anchor = CGPoint.zero
    private var pinch: TrackpadPinch?
    /// The pointers as last sent, normalized.
    private var pinchPointers: [TouchEvent] = []
    private var drag = ScrollDrag()
    /// Scroll deltas that arrived while the fingers were still being classified.
    private var held: (dx: Double, dy: Double)?

    var isPinching: Bool { owner == .pinch }

    /// Set by `cancel()`: the rest of the scroll that was cut off is not a new drag.
    private var ignoreUntilNextScroll = false

    /// Another source (a mouse button, the window losing focus) takes over.
    mutating func cancel() -> [TouchEvent] {
        let busy = drag.isActive || owner == .pan || owner == .undecided || owner == .pinch
        var events = drag.cancel()
        events += releasePinch(as: .cancel)
        held = nil
        owner = fingerCount == 0 ? .idle : .blocked
        if busy { ignoreUntilNextScroll = true }
        return events
    }

    // MARK: Scroll

    mutating func scroll(_ sample: ScrollSample, cursor: CGPoint, space: Space) -> Output {
        if sample.isWheel { return Output(wheel: true) }
        // Android flings by itself after the UP.
        if sample.isMomentum { return Output() }
        if sample.phase.contains(.mayBegin) || sample.phase.contains(.stationary) { return Output() }
        if ignoreUntilNextScroll {
            if sample.phase.contains(.began) {
                ignoreUntilNextScroll = false
            } else {
                if sample.phase.contains(.ended) || sample.phase.contains(.cancelled) { ignoreUntilNextScroll = false }
                return Output()
            }
        }

        switch owner {
        case .pinch, .blocked:
            return Output()
        case .undecided:
            return Output(touches: holdScroll(sample, cursor: cursor, space: space))
        case .idle, .pan:
            let events = dragScroll(sample, cursor: cursor, space: space)
            settle()
            return Output(touches: events)
        }
    }

    /// While the fingers are being classified the scroll deltas wait. A gesture
    /// that ends first and travelled far enough is a scroll: the raw fingers
    /// never contradicted it.
    private mutating func holdScroll(_ sample: ScrollSample, cursor: CGPoint, space: Space) -> [TouchEvent] {
        let previous = held ?? (0, 0)
        held = (previous.dx + sample.deltaX, previous.dy + sample.deltaY)
        guard sample.phase.contains(.ended) || sample.phase.contains(.cancelled) else { return [] }
        let total = held ?? (0, 0)
        held = nil
        guard sample.phase.contains(.ended), hypot(total.dx, total.dy) >= ScrollDrag.minTravel else { return [] }
        owner = .pan
        let flush = ScrollSample(phase: [.began, .ended], deltaX: total.dx, deltaY: total.dy)
        let events = dragScroll(flush, cursor: anchor, space: space)
        settle()
        return events
    }

    private mutating func dragScroll(_ sample: ScrollSample, cursor: CGPoint, space: Space) -> [TouchEvent] {
        let size = space.videoRect.size
        if sample.phase.contains(.cancelled) { return drag.cancel() }
        var events: [TouchEvent] = []
        if sample.phase.contains(.began) || (!drag.isActive && sample.phase.contains(.changed)) {
            events += drag.begin(at: space.normalized(cursor), videoSize: size)
        }
        guard drag.isActive else { return events }
        events += drag.move(deltaX: sample.deltaX, deltaY: sample.deltaY, videoSize: size)
        if sample.phase.contains(.ended) { events += drag.end() }
        return events
    }

    /// A pan is over once its drag has ended and the fingers are off.
    private mutating func settle() {
        if owner == .pan, !drag.isActive, fingerCount < 2 { owner = .idle }
    }

    // MARK: Raw fingers

    /// The fingers now on the trackpad (resting ones already left out).
    mutating func fingersChanged(_ now: [TrackpadFinger], surface: TrackpadSurface,
                                 cursor: CGPoint, space: Space) -> [TouchEvent] {
        touchesAvailable = true
        self.surface = surface
        fingers = now
        fingerCount = now.count

        if now.count >= 3 {
            var events = drag.cancel()
            events += releasePinch(as: .cancel)
            held = nil
            owner = .blocked
            return events
        }
        if now.count < 2 { return fingersLifted() }

        switch owner {
        case .idle:
            anchor = cursor
            landing = now
            classifier.begin(now, surface: surface)
            held = nil
            owner = .undecided
            return []
        case .undecided:
            return decide(space: space)
        case .pinch:
            return movePinch(space: space)
        case .pan, .blocked:
            return []
        }
    }

    private mutating func fingersLifted() -> [TouchEvent] {
        let events = releasePinch(as: .up)
        held = nil
        switch owner {
        case .blocked: if fingerCount == 0 { owner = .idle }
        case .pinch: owner = fingerCount == 0 ? .idle : .blocked
        case .undecided, .idle: owner = .idle
        case .pan: settle()
        }
        return events
    }

    /// AppKit says a pinch is under way; if the raw fingers have not made the
    /// call yet, the pinch is the answer.
    mutating func pinchHinted(space: Space) -> [TouchEvent] {
        guard owner == .undecided else { return [] }
        return startPinch(space: space)
    }

    private mutating func decide(space: Space) -> [TouchEvent] {
        switch classifier.verdict(fingers, surface: surface) {
        case .undecided:
            return []
        case .pan:
            owner = .pan
            guard let pending = held else { return [] }
            held = nil
            // One MOVE for everything held back: DOWN, MOVE, MOVE on the same
            // millisecond would give Android a bogus velocity.
            let sample = ScrollSample(phase: .began, deltaX: pending.dx, deltaY: pending.dy)
            return dragScroll(sample, cursor: anchor, space: space)
        case .pinch:
            return startPinch(space: space)
        }
    }

    // MARK: Pinch

    private mutating func startPinch(space: Space) -> [TouchEvent] {
        // The pointers go down where the fingers landed and then move to where
        // they are, so Android sees the whole spread and not only what came
        // after the verdict.
        guard let start = TrackpadPinch(fingers: landing, surface: surface, anchor: anchor,
                                        flipped: space.flipped, pointsPerMillimetre: pointsPerMillimetre),
              let points = start.pointers(for: landing) else { return [] }
        owner = .pinch
        held = nil
        pinch = start
        pinchPointers = points.map { touch(.down, $0, space) }
        return pinchPointers + movePinch(space: space)
    }

    private mutating func movePinch(space: Space) -> [TouchEvent] {
        guard let pinch, let points = pinch.pointers(for: fingers) else { return [] }
        let moves = points.map { touch(.move, $0, space) }
        let changed = zip(moves, pinchPointers).contains { $0.nx != $1.nx || $0.ny != $1.ny }
        guard changed else { return [] }
        pinchPointers = moves
        return moves
    }

    /// Highest pointer first, like the coarse emulation: up(1), up(0).
    private mutating func releasePinch(as action: TouchAction) -> [TouchEvent] {
        guard pinch != nil else { return [] }
        let last = pinchPointers
        pinch = nil
        pinchPointers = []
        return last.reversed().map { TouchEvent(action: action, pointerId: $0.pointerId, nx: $0.nx, ny: $0.ny) }
    }

    private func touch(_ action: TouchAction, _ pointer: TrackpadPinch.Pointer, _ space: Space) -> TouchEvent {
        let (nx, ny) = space.normalized(pointer.point)
        return TouchEvent(action: action, pointerId: pointer.id, nx: nx, ny: ny)
    }
}
