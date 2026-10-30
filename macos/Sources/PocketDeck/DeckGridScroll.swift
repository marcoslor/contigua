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

    private static func find(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let found = find(in: child) { return found }
        }
        return nil
    }
}
