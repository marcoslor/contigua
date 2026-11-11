// `deck-scroll DY` (e2e, --debug-control): scrolls the Deck's grid by DY
// points. A quiet e2e run cannot move the real pointer, so the wheel is out;
// moving the clip view is what the scroll bar does, and it goes through the
// same scroll geometry the grid reads. Setup/observation only: the proof is
// the rail's accent (`--debug-deck-grid`) before and after.

import AppKit

@MainActor
enum DeckGridScroll {
    /// Scrolls by `dy` points, clamped to the grid's ends. Nil on success, else
    /// why there was nothing to scroll.
    static func scroll(by dy: CGFloat) -> String? {
        guard let window = DeckWindow.window,
              let scroll = find(in: window.contentView) else {
            return "no grid scroll view"
        }
        let clip = scroll.contentView
        let height = scroll.documentView?.frame.height ?? 0
        let limit = max(0, height - clip.bounds.height)
        let target = min(max(clip.bounds.origin.y + dy, 0), limit)
        guard abs(target - clip.bounds.origin.y) > 0.5 else { return "the grid is already at its end" }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scroll.reflectScrolledClipView(clip)
        return nil
    }

    /// A real continuous wheel event at the grid's centre, the way a person's
    /// wheel or trackpad delivers one: the scroll view's own phase becomes
    /// `.interacting`, which DECK-32 reads to end a click's emphasis. Nil on
    /// success, else why not.
    static func wheel(by dy: CGFloat) -> String? {
        guard let window = DeckWindow.window,
              let scroll = find(in: window.contentView) else {
            return "no grid scroll view"
        }
        let point = scroll.convert(CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for (phase, delta) in [(1, CGFloat(0)), (2, dy), (4, CGFloat(0))] {
            guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                        wheel1: Int32(delta.rounded()), wheel2: 0, wheel3: 0) else {
                return "no wheel event"
            }
            cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
            cgEvent.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(delta))
            cgEvent.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(delta))
            cgEvent.location = CGPoint(x: point.x, y: primaryHeight - point.y)
            guard let event = NSEvent(cgEvent: cgEvent) else { return "no wheel event" }
            scroll.scrollWheel(with: event)
        }
        // Let SwiftUI read the phase and the geometry before the caller dumps.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        return nil
    }

    private static func find(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let found = find(in: child) { return found }
        }
        return nil
    }
}
