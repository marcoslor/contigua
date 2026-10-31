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

    static let deviceIdKey = "deviceId"
    static let pkgKey = "pkg"
    static let pidKey = "pid"
    /// Shim → host: the shim's per-bundle token (sec L-8). The host ignores an
    /// open/quit message whose token is not the one in that shim's Info.plist.
    static let tokenKey = "token"

    /// Info.plist keys of a shim bundle.
    static let plistDeviceId = "PDDeviceId"
    static let plistPackage = "PDPackage"
    static let plistProfile = "PDProfile"
    static let plistHostPath = "PDHostPath"
    /// A random per-bundle token, written when the bundle is built.
    static let plistToken = "PDToken"
    /// Why the bundle exists (docs/design/dock.md §Shortcuts): an array of
    /// `dock`, `manual`, `all`, `window`. Written by every current build.
    static let plistOrigins = "PDOrigins"
    /// The app's label as the phone sent it, so a rebuild that only changes the
    /// origins keeps the name without the phone part.
    static let plistLabel = "PDLabel"
    /// The pre-origins marker ("Add to Dock" = true): read only to migrate a
    /// bundle written before PDOrigins existed.
    static let plistPinned = "PDPinned"
    /// The renderer version the shim's icon was made with (docs/design/dock.md
    /// §Icons): a bundle with an older or missing one is rebuilt.
    static let plistIconVersion = "PDIconVersion"
    /// Whether that icon was drawn from the phone's adaptive layers (true) or
    /// from a flat icon on the plate (false). Layers arriving later make a
    /// plate-built shim stale, so it is rebuilt the next time it is followed.
    static let plistIconLayers = "PDIconLayers"

    /// The shim executable inside PocketDeck.app/Contents/MacOS and every shim bundle.
    static let shimExecutable = "PocketDeckShim"
}

/// The per-shim token (sec L-8): random when the bundle is written, carried in
/// its Info.plist and in every message it posts. The host accepts an open/quit
/// message only when the token equals the one stored for that shim, so a local
/// process that merely knows a package name cannot drive a session.
enum DockToken {
    static let byteCount = 16

    /// 32 lowercase hex characters.
    static func make() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func isWellFormed(_ token: String) -> Bool {
        token.count == byteCount * 2 && token.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Both present, well-formed and equal (compared byte by byte).
    static func matches(message: String?, stored: String?) -> Bool {
        guard let message, let stored,
              isWellFormed(message), isWellFormed(stored) else { return false }
        var diff = 0
        for (a, b) in zip(Array(message.utf8), Array(stored.utf8)) { diff |= Int(a ^ b) }
        return diff == 0
    }
}
