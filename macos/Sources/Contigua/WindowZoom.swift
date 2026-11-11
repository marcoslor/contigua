// A stream window's zoom toggles between the screen's standard frame and the
// frame it had before. The state is explicit (AGENTS.md: mode-like behaviour
// is one enum and one pure transition) because the app runs the animation
// itself and so has to remember what a second zoom returns to.

import Foundation

enum WindowZoom {
    /// `zoomed` keeps the frame the window had when it went to the standard
    /// frame (the second zoom returns there) and the frame the zoom settled at
    /// (the window's own size rules may round the standard frame).
    enum State: Equatable {
        case normal
        case zoomed(from: NSRect, to: NSRect)

        var name: String {
            switch self {
            case .normal: return "normal"
            case .zoomed: return "zoomed"
            }
        }
    }

    /// How far the window may sit from the settled zoom frame and still count
    /// as zoomed: AppKit's own zoom uses a small tolerance the same way.
    static let tolerance: CGFloat = 1

    /// One zoom request on `frame`: the next state and the frame to animate
    /// to. Pure, so the toggle is unit-tested without a window. As AppKit's
    /// zoom does, a window the person moved or resized since its zoom goes to
    /// the standard frame again rather than back to the frame before.
    static func onZoom(_ state: State, frame: NSRect, standard: NSRect) -> (State, NSRect) {
        if case .zoomed(let from, let to) = state, near(frame, to) {
            return (.normal, from)
        }
        return (.zoomed(from: frame, to: standard), standard)
    }

    /// The zoom animation ended at `frame`: that is the zoomed frame now.
    static func settled(_ state: State, at frame: NSRect) -> State {
        guard case .zoomed(let from, _) = state else { return state }
        return .zoomed(from: from, to: frame)
    }

    static func near(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
