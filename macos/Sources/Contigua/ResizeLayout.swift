// The live-resize layout phases (WIN-58): a drag, the wait for the phone's
// answer, and one display refresh's worth of settle after it. The picture's
// gravity and the fill's margin follow the phase, so the layer never re-lays
// its contents while the window server is still showing the new size.
//
// Pure: the transitions are unit-tested, and the view logs each one.

import Foundation

enum ResizeLayoutPhase: Equatable {
    case idle
    /// A hand (or the app's zoom) is changing the window's shape.
    case dragging
    /// The drag ended; the window has asked, the phone has not answered.
    case awaitingAnswer
    /// The answer landed; the layer's gravity holds for one beat so its
    /// contents do not re-lay mid-frame.
    case settling
}

enum ResizeLayoutEvent: Equatable {
    case dragBegan
    case dragEnded
    case answered
    case settleElapsed
    case timedOut
}

extension ResizeLayoutPhase {
    /// For the log line; a state, never a person's value.
    var state: String {
        switch self {
        case .idle: return "idle"
        case .dragging: return "dragging"
        case .awaitingAnswer: return "awaitingAnswer"
        case .settling: return "settling"
        }
    }
}

extension ResizeLayoutEvent {
    var kind: String {
        switch self {
        case .dragBegan: return "dragBegan"
        case .dragEnded: return "dragEnded"
        case .answered: return "answered"
        case .settleElapsed: return "settleElapsed"
        case .timedOut: return "timedOut"
        }
    }
}

struct ResizeLayout {
    private(set) var phase: ResizeLayoutPhase = .idle

    /// True while the picture must keep the fill's gravity: from the first
    /// drag event through the answer's settle.
    var holdsFillGravity: Bool { phase != .idle }

    /// The next phase for a phase and an event. An event that does not apply
    /// leaves the phase alone (an answer to an old request during a drag, a
    /// settle tick that arrives early, a drag end in the settle).
    mutating func apply(_ event: ResizeLayoutEvent) {
        switch phase {
        case .idle:
            switch event {
            case .dragBegan: phase = .dragging
            case .dragEnded, .answered, .settleElapsed, .timedOut: break
            }
        case .dragging:
            switch event {
            case .dragEnded: phase = .awaitingAnswer
            case .dragBegan, .answered, .settleElapsed, .timedOut: break
            }
        case .awaitingAnswer:
            switch event {
            case .dragBegan: phase = .dragging
            case .answered: phase = .settling
            case .timedOut: phase = .idle
            case .dragEnded, .settleElapsed: break
            }
        case .settling:
            switch event {
            case .dragBegan: phase = .dragging
            case .settleElapsed: phase = .idle
            case .dragEnded, .answered, .timedOut: break
            }
        }
    }
}
