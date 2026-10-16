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
    }

    /// Brings the app forward, except in background mode: there the person's
    /// frontmost app keeps the focus and windows are ordered without it.
    static func activateApp() {
        guard !isOn else { return }
        NSApp.activate(ignoringOtherApps: true)
    }
}
