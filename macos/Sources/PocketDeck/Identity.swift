// Identity, key storage and logging.
//
// - clientId: stable per-install UUID in the profile's defaults (sent in `hello`).
// - Pair keys: one JSON file, ~/Library/Application Support/<profile folder>/pairkeys.json,
//   mode 0600 in a 0700 folder. Not the Keychain: every re-signed build made
//   macOS ask for the login password. Keychain storage returns with proper
//   code signing before release.
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
    static let input = Logger(subsystem: subsystem, category: "input")
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

/// Pairing keys by device id (hex), protected by file permissions only.
struct PairKeyFile {
    let url: URL

    @discardableResult
    func store(_ secret: Data, account: String) -> Bool {
        var all = readAll()
        all[account] = secret.hexString
        return write(all)
    }

    func load(account: String) -> Data? {
        readAll()[account].flatMap { Data(hexString: $0) }
    }

    func delete(account: String) {
        var all = readAll()
        guard all.removeValue(forKey: account) != nil else { return }
        write(all)
    }

    /// Removes every key of this profile (used by the `--reset-pairing` test hook).
    func deleteAll() {
        try? FileManager.default.removeItem(at: url)
    }

    func accounts() -> [String] {
        readAll().keys.sorted()
    }

    private func readAll() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let all = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return all
    }

    @discardableResult
    private func write(_ all: [String: String]) -> Bool {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            let data = try JSONSerialization.data(withJSONObject: all, options: [.sortedKeys])
            // Created 0600 before any key is written, then renamed over the old file.
            let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
            guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                return false
            }
            guard rename(tmp.path, url.path) == 0 else {
                try? fm.removeItem(at: tmp)
                return false
            }
            return true
        } catch {
            Log.app.error("pair keys not saved: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

/// Pairing keys plus the last device we talked to. The device id normally
/// arrives in the mDNS TXT record; over `--connect` there is no TXT, so the
/// last-known device id is used to pick the right key before `welcome`.
final class PairKeyStore {
    private let defaults: UserDefaults
    private let keys: PairKeyFile
    private let lastDeviceIdKey = "lastDeviceId"

    init(defaults: UserDefaults, keys: PairKeyFile) {
        self.defaults = defaults
        self.keys = keys
    }

    convenience init(profile: Profile) {
        self.init(defaults: profile.defaults, keys: profile.pairKeys)
    }

    var lastDeviceId: String? {
        get { defaults.string(forKey: lastDeviceIdKey) }
        set {
            if let newValue { defaults.set(newValue, forKey: lastDeviceIdKey) }
            else { defaults.removeObject(forKey: lastDeviceIdKey) }
        }
    }

    func key(forDeviceId deviceId: String) -> Data? {
        keys.load(account: deviceId)
    }

    /// The key we should try before `welcome` when the device id is unknown.
    func candidateKey(knownDeviceId: String?) -> (deviceId: String, key: Data)? {
        if let id = knownDeviceId, let key = key(forDeviceId: id) { return (id, key) }
        if let id = lastDeviceId, let key = key(forDeviceId: id) { return (id, key) }
        let accounts = keys.accounts()
        if accounts.count == 1, let key = keys.load(account: accounts[0]) { return (accounts[0], key) }
        return nil
    }

    func store(key: Data, deviceId: String) {
        keys.store(key, account: deviceId)
        lastDeviceId = deviceId
    }

    func forget(deviceId: String) {
        keys.delete(account: deviceId)
        if lastDeviceId == deviceId { lastDeviceId = nil }
    }

    func deleteAll() {
        keys.deleteAll()
    }

    func accounts() -> [String] {
        keys.accounts()
    }
}

enum PairCrypto {
    /// mac = lowercase hex of HMAC-SHA256(key: 32 raw key bytes,
    /// message: UTF-8 bytes of the nonce hex string exactly as sent).
    static func hmacHex(key: Data, nonceHex: String) -> String {
        let auth = CryptoKitHmac.code(key: key, message: Data(nonceHex.utf8))
        return auth.map { String(format: "%02x", $0) }.joined()
    }
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
