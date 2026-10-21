// The Deck grid's width, coalesced (DeckViews.swift's AppGrid).
//
// A window zoom or a live resize hands the grid a new width on every display
// frame. Writing that straight into the grid's state rebuilt its columns and
// every cell on each frame — the Deck's zoom stutter, worst on the way back,
// where the window shrinks and the grid re-flows. This collects the widths and
// applies the newest one at most every `interval`, then flushes the last one
// after the animation ends, so the settled layout is exact to the point.

import CoreGraphics
import Foundation

@MainActor
final class WidthDebouncer {
    /// One step per ~3 display frames: invisible to the eye, three times less
    /// layout work than per frame.
    static let interval: TimeInterval = 0.05

    private var pending: CGFloat?
    private var lastApplied = Date.distantPast
    private var timer: Timer?

    /// `update` runs with the coalesced width (bookkeeping, e.g. the column
    /// count); `apply` writes the state the view reads.
    func schedule(_ width: CGFloat, update: @escaping (CGFloat) -> Void,
                  apply: @escaping (CGFloat) -> Void) {
        pending = width
        let elapsed = Date().timeIntervalSince(lastApplied)
        if elapsed >= Self.interval {
            flush(update: update, apply: apply)
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval - elapsed, repeats: false) { _ in
            Task { @MainActor in self.flush(update: update, apply: apply) }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func flush(update: (CGFloat) -> Void, apply: (CGFloat) -> Void) {
        timer?.invalidate()
        timer = nil
        guard let width = pending else { return }
        pending = nil
        lastApplied = Date()
        update(width)
        apply(width)
    }
}
