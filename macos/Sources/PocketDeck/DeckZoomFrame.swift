// The Deck's standard zoom (DECK-24): a title-bar double-click or the green
// button takes the window to the Deck's intrinsic width — the 880 pt grid plus
// 60 pt a side at the person's zoom, and the rail — and the screen's visible
// height, instead of stretching to the whole screen. AppKit asks the window's
// delegate (`windowWillUseStandardFrame`) and SwiftUI owns that delegate, so
// this proxy answers that one question and forwards every other. It also
// answers the full-screen session's presentation options (DECK-25): without
// it AppKit pins its own toolbar strip over the top of the screen.

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

    /// DECK-25: in native full screen the Deck's header is the window's own
    /// toolbar, not the system's toolbar strip. AppKit pins an
    /// `NSToolbarFullScreenWindow` across the top of the screen for the whole
    /// session unless `.autoHideToolbar` is among the presentation options:
    /// that strip is the band above the Deck (the window opens its session
    /// below it) and it hosts the toolbar items (the connection chip) over the
    /// content instead of in the header. Auto-hidden, it comes and goes with
    /// the menu bar like every full-screen app's; the window fills the screen
    /// and the chip stays in the header it is in in a window.
    func window(_ window: NSWindow,
                willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions)
        -> NSApplication.PresentationOptions {
        var options = proposedOptions
        if let target,
           target.responds(to: #selector(NSWindowDelegate.window(_:willUseFullScreenPresentationOptions:))),
           let inner = target.window?(window, willUseFullScreenPresentationOptions: proposedOptions) {
            options = inner
        }
        return options.union([.fullScreen, .autoHideMenuBar, .autoHideToolbar])
    }
}
