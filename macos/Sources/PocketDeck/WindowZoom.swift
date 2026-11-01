// A stream window's zoom toggles between the screen's standard frame and the
// frame it had before. The state is explicit (AGENTS.md: mode-like behaviour
// is one enum and one pure transition) because the app runs the animation
// itself and so has to remember what a second zoom returns to.

import Foundation

enum WindowZoom {
    /// `zoomed` keeps the frame the window had when it went to the standard
    /// frame: the second zoom returns there.
    enum State: Equatable {
        case normal
        case zoomed(from: NSRect)

        var name: String {
            switch self {
            case .normal: return "normal"
            case .zoomed: return "zoomed"
            }
        }
    }

    /// One zoom request on `frame`: the next state and the frame to animate
    /// to. Pure, so the toggle is unit-tested without a window.
    static func onZoom(_ state: State, frame: NSRect, standard: NSRect) -> (State, NSRect) {
        switch state {
        case .normal:
            return (.zoomed(from: frame), standard)
        case .zoomed(let from):
            return (.normal, from)
        }
    }
}
