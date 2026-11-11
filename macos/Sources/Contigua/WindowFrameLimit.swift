// A window never grows past the screen it is on (CONV-MAC-12).
//
// AppKit constrains a person's drag, but an Accessibility resize, a tiler or a
// script sets the size directly, and on the e2e's virtual display the app's own
// frames deliberately win (VirtualDisplay.swift), so a 4000 pt window can stay
// 4000 pt tall. Two hooks hold the rule, and neither moves a window:
// - `constrainFrameRect(_:to:)`, which every new frame passes through, fits
//   the size to the screen (the virtual display's exception now applies only
//   to the app's own picture-sized windows);
// - `setFrame(_:display:)` and `setContentSize(_:)` fit the size as well, for
//   the paths that do not ask AppKit to constrain.
//
// A stream or phone window is exempt from both: the app sizes it from the
// phone's picture (C6's whole-window stream, the phone's turn), and its
// controller limits a person's or a script's resize in `windowWillResize`.
//
// The rule is a value, so K2 tests it without AppKit.

import AppKit

enum WindowFrameLimit {
    /// `proposed` fitted inside `visible`: at most its size, never below the
    /// window's own minimum (itself never larger than the screen).
    static func size(_ proposed: NSSize, within visible: NSSize, minimum: NSSize) -> NSSize {
        var size = NSSize(width: min(proposed.width, visible.width),
                          height: min(proposed.height, visible.height))
        size.width = max(size.width, min(minimum.width, visible.width))
        size.height = max(size.height, min(minimum.height, visible.height))
        return size
    }

    /// `proposed` scaled down with its aspect kept until it fits inside
    /// `visible`, never below `minimum`. A window whose shape is the phone's
    /// picture (the mirror) would be distorted by an independent clamp.
    static func aspectFitted(_ proposed: NSSize, within visible: NSSize, minimum: NSSize) -> NSSize {
        guard proposed.width > 0, proposed.height > 0 else { return proposed }
        let scale = min(1, min(visible.width / proposed.width, visible.height / proposed.height))
        var size = NSSize(width: proposed.width * scale, height: proposed.height * scale)
        size.width = max(size.width, min(minimum.width, visible.width))
        size.height = max(size.height, min(minimum.height, visible.height))
        return size
    }

    /// `size` fitted to `window`'s screen with its aspect kept.
    static func aspectFitted(_ size: NSSize, for window: NSWindow) -> NSSize {
        guard let visible = window.screen?.visibleFrame else { return size }
        return aspectFitted(size, within: visible.size, minimum: window.minSize)
    }

    /// `frame` with its size fitted to `window`'s screen. The origin is left
    /// where it was: this rule never moves a window (opening on screen is
    /// WindowManager.clampedToScreen's job).
    static func fitted(_ frame: NSRect, for window: NSWindow, screen: NSScreen? = nil) -> NSRect {
        guard let visible = (screen ?? window.screen)?.visibleFrame else { return frame }
        return NSRect(origin: frame.origin,
                      size: size(frame.size, within: visible.size, minimum: window.minSize))
    }

    /// The largest size `proposed` may take on `window`'s screen.
    static func size(_ proposed: NSSize, for window: NSWindow) -> NSSize {
        fitted(NSRect(origin: window.frame.origin, size: proposed), for: window).size
    }
}

// MARK: - The windows the app sizes itself

@MainActor
extension WindowFrameLimit {
    /// Windows whose frame the app sets from the phone's picture (a stream's
    /// size, a phone's turn). They are exempt: C6 asks for a window larger than
    /// the e2e's display on purpose, and their controller limits a person's or
    /// a script's resize instead.
    private static let own = NSHashTable<NSWindow>.weakObjects()

    static func owns(_ window: NSWindow) {
        own.add(window)
    }

    /// Installs the funnel for the paths that do not ask AppKit to constrain.
    /// Called once, before any window exists.
    static func start() {
        let pairs: [(Selector, Selector)] = [
            (#selector(NSWindow.setFrame(_:display:)), #selector(NSWindow.pd_setFrame(_:display:))),
            (#selector(NSWindow.setContentSize(_:)), #selector(NSWindow.pd_setContentSize(_:))),
        ]
        for (original, replacement) in pairs {
            guard let a = class_getInstanceMethod(NSWindow.self, original),
                  let b = class_getInstanceMethod(NSWindow.self, replacement) else { continue }
            method_exchangeImplementations(a, b)
        }
    }

    /// Whether the rule applies: a window a person reaches, not the app's own
    /// picture-sized windows, panels, sheets or child windows, and never a
    /// full-screen window: the system sizes that one to the screen's whole
    /// frame, menu-bar band included, and this limit would cut it to the
    /// visible frame and leave the band uncovered (DECK-25).
    static func applies(to window: NSWindow) -> Bool {
        !window.styleMask.contains(.fullScreen)
            && !own.contains(window) && !(window is NSPanel) && window.level == .normal
            && window.sheetParent == nil && window.parent == nil
    }
}

@MainActor
extension NSWindow {
    @objc fileprivate func pd_setFrame(_ frameRect: NSRect, display flag: Bool) {
        guard WindowFrameLimit.applies(to: self) else {
            pd_setFrame(frameRect, display: flag)
            return
        }
        pd_setFrame(WindowFrameLimit.fitted(frameRect, for: self), display: flag)
    }

    @objc fileprivate func pd_setContentSize(_ size: NSSize) {
        guard WindowFrameLimit.applies(to: self) else {
            pd_setContentSize(size)
            return
        }
        pd_setContentSize(WindowFrameLimit.size(size, for: self))
    }
}
