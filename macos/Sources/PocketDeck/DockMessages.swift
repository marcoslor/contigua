// The messages between PocketDeck and its Dock apps (docs/design/dock.md). Also
// compiled into the shim binary (Shim/main.swift), so it uses Foundation only.

import Foundation

enum DockMessage {
    /// Shim → host: open or focus this app's window. userInfo: deviceId, pkg, pid.
    static let open = Notification.Name("dev.pocketdeck.dock.open")
    /// Host → shim: the request arrived. userInfo: pid.
    static let opened = Notification.Name("dev.pocketdeck.dock.opened")
    /// Host → shim: the window is gone; the shim exits. userInfo: pid.
    static let closed = Notification.Name("dev.pocketdeck.dock.closed")
    /// Shim → host: the shim is quitting; close its window. userInfo: pid.
    static let quit = Notification.Name("dev.pocketdeck.dock.quit")
    /// Shim → host: while its window is open, is the host still there? The host
    /// answers `opened`; with no answer the shim quits (the host can die without
    /// saying so: a crash posts no `closed`).
    static let ping = Notification.Name("dev.pocketdeck.dock.ping")

    static let deviceIdKey = "deviceId"
    static let pkgKey = "pkg"
    static let pidKey = "pid"

    /// Info.plist keys of a shim bundle.
    static let plistDeviceId = "PDDeviceId"
    static let plistPackage = "PDPackage"
    static let plistProfile = "PDProfile"
    static let plistHostPath = "PDHostPath"

    /// The shim executable inside PocketDeck.app/Contents/MacOS and every shim bundle.
    static let shimExecutable = "PocketDeckShim"
}
