// Identity, key storage and logging.
//
// - clientId: stable per-install UUID in the profile's defaults (sent in `hello`).
// - Identity: the v2 EC key + certificate in
//   ~/Library/Application Support/<profile folder>/identity.json, mode 0600 in
//   a 0700 folder; the phones this Mac has pinned live beside it in pins.json
//   (PhonePinStoreV2). Not the Keychain: every re-signed build made macOS ask
//   for the login password. Keychain storage returns with proper code signing
//   before release. (The v1 pairkeys.json is deleted by IdentityMigrationV2 —
//   v2 pairs from scratch.)
// - Logging: os.Logger only (no `print`); the optional latency log is a file
//   under ~/Library/Logs/<profile folder> because it is sampled by the tests.

import CryptoKit
import Foundation
import os

enum Log {
    private static let subsystem = "dev.pocketdeck.mac"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let session = Logger(subsystem: subsystem, category: "session")
    static let video = Logger(subsystem: subsystem, category: "video")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let input = Logger(subsystem: subsystem, category: "input")
    static let files = Logger(subsystem: subsystem, category: "files")
}

enum ClientIdentity {
    private static let clientIdKey = "clientId"

    /// Stable per-install id; the phone remembers us by this.
    static func clientId(in profile: Profile) -> String {
        let defaults = profile.defaults
        if let existing = defaults.string(forKey: clientIdKey), !existing.isEmpty { return existing }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: clientIdKey)
        return fresh
    }

    static var name: String { Host.current().localizedName ?? "Mac" }
}

/// Thin shim so the rest of the code does not need CryptoKit types in scope.
enum CryptoKitHmac {
    static func code(key: Data, message: Data) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }
}

/// Optional latency sampling: TOUCH down send -> next VIDEO_FRAME for that
/// stream. Enabled with `defaults write dev.pocketdeck.mac debugLatency -bool YES`
/// (for the default profile; other profiles use their own suite).
final class LatencyLog {
    static let shared = LatencyLog(profile: .active)

    private let enabled: Bool
    private let lock = NSLock()
    private var lastTouchDown: [UInt32: Date] = [:]
    private let url: URL?

    private init(profile: Profile) {
        enabled = profile.defaults.bool(forKey: "debugLatency")
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(profile.supportDirectoryName)", isDirectory: true)
        if enabled {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent("latency.log")
        } else {
            url = nil
        }
    }

    func noteTouchDown(stream: UInt32) {
        guard enabled else { return }
        lock.lock(); lastTouchDown[stream] = Date(); lock.unlock()
    }

    func noteVideoFrame(stream: UInt32) {
        guard enabled, let url else { return }
        lock.lock()
        let start = lastTouchDown.removeValue(forKey: stream)
        lock.unlock()
        guard let start else { return }
        let ms = Date().timeIntervalSince(start) * 1000
        Log.app.debug("latency stream=\(stream, privacy: .public) touch->frame \(ms, format: .fixed(precision: 1), privacy: .public)ms")
        guard let line = "stream=\(stream) touch->frame \(String(format: "%.1f", ms))ms\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }
}
