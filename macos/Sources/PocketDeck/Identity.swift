// Identity, key storage and logging.
//
// - clientId: stable per-install UUID in UserDefaults (sent in `hello`).
// - Pair keys: one generic-password item per device id in the login Keychain.
// - Logging: os.Logger only (no `print`); the optional latency log is a file
//   under ~/Library/Logs/PocketDeck because it is sampled by the tests.

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
    static var clientId: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: clientIdKey), !existing.isEmpty { return existing }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: clientIdKey)
        return fresh
    }

    static var name: String { Host.current().localizedName ?? "Mac" }
}

/// Generic-password items for pairing keys. Reads/creates only items this app
/// owns, so the Keychain never prompts during a normal run.
enum Keychain {
    static let service = "dev.pocketdeck.mac"

    private static func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    @discardableResult
    static func store(_ secret: Data, account: String) -> Bool {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = secret
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func load(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    /// Removes every PocketDeck item (used by the `--reset-pairing` test hook).
    static func deleteAll() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
    }

    static func accounts() -> [String] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

/// Pairing keys plus the last device we talked to. The device id normally
/// arrives in the mDNS TXT record; over `--connect` there is no TXT, so the
/// last-known device id is used to pick the right key before `welcome`.
final class PairKeyStore {
    private let defaults: UserDefaults
    private let lastDeviceIdKey = "lastDeviceId"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var lastDeviceId: String? {
        get { defaults.string(forKey: lastDeviceIdKey) }
        set {
            if let newValue { defaults.set(newValue, forKey: lastDeviceIdKey) }
            else { defaults.removeObject(forKey: lastDeviceIdKey) }
        }
    }

    func key(forDeviceId deviceId: String) -> Data? {
        Keychain.load(account: deviceId)
    }

    /// The key we should try before `welcome` when the device id is unknown.
    func candidateKey(knownDeviceId: String?) -> (deviceId: String, key: Data)? {
        if let id = knownDeviceId, let key = key(forDeviceId: id) { return (id, key) }
        if let id = lastDeviceId, let key = key(forDeviceId: id) { return (id, key) }
        let accounts = Keychain.accounts()
        if accounts.count == 1, let key = Keychain.load(account: accounts[0]) { return (accounts[0], key) }
        return nil
    }

    func store(key: Data, deviceId: String) {
        Keychain.store(key, account: deviceId)
        lastDeviceId = deviceId
    }

    func forget(deviceId: String) {
        Keychain.delete(account: deviceId)
        if lastDeviceId == deviceId { lastDeviceId = nil }
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
/// stream. Enabled with `defaults write dev.pocketdeck.mac debugLatency -bool YES`.
final class LatencyLog {
    static let shared = LatencyLog()

    private let enabled: Bool
    private let lock = NSLock()
    private var lastTouchDown: [UInt32: Date] = [:]
    private let url: URL?

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "debugLatency")
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/PocketDeck", isDirectory: true)
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
