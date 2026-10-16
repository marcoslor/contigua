// Background mode (`--background`, e2e only): the checks run while the person
// keeps typing in another app. The app never becomes the frontmost app, has no
// Dock icon or ⌘-Tab entry, and puts its windows on a display of its own
// (VirtualDisplay.swift) instead of the person's screens. Launch refuses it
// with the default profile, so the installed app never runs this way.

import AppKit

enum BackgroundMode {
    /// Set once at launch, before any window exists.
    static var isOn = false

    @MainActor
    static func start() {
        NSApp.setActivationPolicy(.accessory)
        VirtualDisplay.create()
        NSWindow.keepWindowsOnVirtualDisplay()
        BackgroundKeyWindow.install()
    }

    /// Brings the app forward, except in background mode: there the person's
    /// frontmost app keeps the focus and windows are ordered without it.
    static func activateApp() {
        guard !isOn else { return }
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// An app that is not active has no key window, yet the app behaves by its key
/// window: menu commands and ⌥⌘F act on it, Escape reaches only it, it never
/// pauses. In background mode the window last made key (as the app's own code
/// does when it opens a window, and the scripted input when it focuses one) is
/// reported as the key window, with the usual become/resign notifications,
/// while the app itself stays inactive.
enum BackgroundKeyWindow {
    private static weak var window: NSWindow?

    /// The emulated key window while it is on screen.
    static var current: NSWindow? {
        guard let window, window.isVisible, !window.isMiniaturized else { return nil }
        return window
    }

    @MainActor
    static func install() {
        swap(NSWindow.self, #selector(NSWindow.makeKey), #selector(NSWindow.pd_makeKey))
        swap(NSWindow.self, #selector(NSWindow.makeKeyAndOrderFront(_:)), #selector(NSWindow.pd_makeKeyAndOrderFront(_:)))
        swap(NSWindow.self, #selector(getter: NSWindow.isKeyWindow), #selector(getter: NSWindow.pd_isKeyWindow))
        swap(NSApplication.self, #selector(getter: NSApplication.keyWindow), #selector(getter: NSApplication.pd_keyWindow))
    }

    private static func swap(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let a = class_getInstanceMethod(cls, original), let b = class_getInstanceMethod(cls, replacement) else { return }
        method_exchangeImplementations(a, b)
    }

    fileprivate static func becomeKey(_ next: NSWindow) {
        guard next.canBecomeKey, next !== window else { return }
        let previous = current
        window = next
        if let previous { NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: previous) }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: next)
    }
}

extension NSWindow {
    @objc fileprivate func pd_makeKey() {
        pd_makeKey()
        BackgroundKeyWindow.becomeKey(self)
    }

    @objc fileprivate func pd_makeKeyAndOrderFront(_ sender: Any?) {
        pd_makeKeyAndOrderFront(sender)
        BackgroundKeyWindow.becomeKey(self)
    }

    @objc fileprivate var pd_isKeyWindow: Bool { pd_isKeyWindow || BackgroundKeyWindow.current === self }
}

extension NSApplication {
    @objc fileprivate var pd_keyWindow: NSWindow? { pd_keyWindow ?? BackgroundKeyWindow.current }
}
