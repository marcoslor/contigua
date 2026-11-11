// The Deck's window delegate (DECK-24, DECK-25). AppKit asks the window's
// delegate how a standard zoom should size it; the Deck answers nothing, so a
// title-bar double-click and the green button take the system's own standard
// frame — the screen's visible frame — and a second zoom returns the frame the
// window came from. The zoom is never computed from the grid's contents, so it
// cannot change the icon size. SwiftUI owns the window's delegate, so this proxy
// forwards every question to it; the one it answers itself is the full-screen
// session's presentation options (DECK-25): without them AppKit pins its own
// toolbar strip over the top of the screen.

import AppKit

@MainActor
final class DeckWindowDelegate: NSObject, NSWindowDelegate {
    /// SwiftUI's own delegate: every question but the presentation options is
    /// its.
    weak var target: NSWindowDelegate?

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (target?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? { target }

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
