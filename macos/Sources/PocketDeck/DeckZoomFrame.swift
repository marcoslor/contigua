// The Deck's standard zoom (DECK-24): a title-bar double-click or the green
// button takes the window to the Deck's intrinsic width — the 880 pt grid plus
// 60 pt a side at the person's zoom, and the rail — and the screen's visible
// height, instead of stretching to the whole screen. AppKit asks the window's
// delegate (`windowWillUseStandardFrame`) and SwiftUI owns that delegate, so
// this proxy answers that one question and forwards every other.

import AppKit

@MainActor
final class DeckZoomDelegate: NSObject, NSWindowDelegate {
    /// SwiftUI's own delegate: every question but the standard frame is its.
    weak var target: NSWindowDelegate?
    /// The intrinsic width, read at the moment of the zoom (the person may
    /// have changed the zoom since the window opened).
    var preferredWidth: () -> CGFloat = { DeckWide.preferredWidth(zoom: 1) }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (target?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? { target }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? newFrame
        return DeckWide.standardFrame(visible: visible, preferredWidth: preferredWidth())
    }
}
