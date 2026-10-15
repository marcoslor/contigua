// The Mac's TLS identity for protocol v2 (docs/design/e2ee.md §3) plus the pin
// store the TLS layer pins phones against.
//
// - identity.json one JSON file, <profile>/Application Support/<profile folder>/identity.json,
//   mode 0600 in a 0700 folder (the same treatment pairkeys.json has; Keychain
//   returns with proper code signing).
// - On the first v2 run pairkeys.json is deleted (the forced re-pair — §7):
//   v1 HMAC keys authenticate nothing in v2 and must not be reused as pin data.
//   No reverse path.
// - The pin is NOT the certificate's bytes (Apple re-encodes them), it is
//   SHA-256 over the 65-byte uncompressed EC point, identical on both stacks.
//
// v2 stores live beside the v1 ones and are NOT wired yet (phase-2 step 3+).

import CryptoKit
import Foundation
import SwiftUI

/// The identity.json shape (§3). The 64-hex `pin` is THE paired phone's point
/// fingerprint; `pinVersion` stays 2. The private key lives only in this file
/// and in the TLS stack's memory — never logged, never sent anywhere.
struct DeviceIdentityV2: Codable, Equatable {
    var deviceId: String
    var certPem: String
    var keyP8: String
    var pin: String
    var pinVersion: Int

    static let version = 2

    init(deviceId: String, certPem: String, keyP8: String, pin: String) {
        self.deviceId = deviceId
        self.certPem = certPem
        self.keyP8 = keyP8
        self.pin = pin
        self.pinVersion = DeviceIdentityV2.version
    }

    /// Exactly the five documented keys; nothing else ever enters the file.
    static let keys = Set(["deviceId", "certPem", "keyP8", "pin", "pinVersion"])
}

/// The canonical fingerprint math, shared with Android's `KeyPin` (§4b/§1):
/// SHA-256 over the 65-byte uncompressed point `04||X||Y`. For a CryptoKit
/// P-256 key, `x963Representation` IS `04||X||Y`.
enum PointFingerprint {
    /// The digest of the encoded point.
    static func digest(ofPoint point: Data) -> Data {
        Data(SHA256.hash(data: point))
    }

    /// Lowercase 64-hex `pin` string for a P-256 public key.
    static func hex(ofKey key: P256.Signing.PublicKey) -> String {
        digest(ofPoint: Data(key.x963Representation)).hexString
    }

    /// True when the hex string is a well-formed 64-char lowercase pin.
    static func isWellFormed(pin: String) -> Bool {
        pin.count == 64 && pin.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

/// identity.json reader/writer (0600, atomic rename, 0700 folder).
final class IdentityFileV2 {
    let url: URL

    init(url: URL) { self.url = url }

    /// identity.json in the profile's support folder.
    static func fileUrl(in profile: Profile) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(profile.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("identity.json")
    }

    func load() -> DeviceIdentityV2? {
        guard let data = try? Data(contentsOf: url),
              let identity = try? JSONDecoder().decode(DeviceIdentityV2.self, from: data) else { return nil }
        return identity
    }

    @discardableResult
    func save(_ identity: DeviceIdentityV2) -> Bool {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            let data = try JSONEncoder().encode(identity)
            // Created 0600 before any key material is written, then renamed over.
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
            Log.app.error("identity not saved: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// §3/§7 migration: the first v2 run deletes the v1 pair keys — one forced
/// re-pair, no reverse path.
enum IdentityMigrationV2 {
    @discardableResult
    static func wipePairKeys(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try? FileManager.default.removeItem(at: url)
        return true
    }
}

/// Resets pairing state without touching the Mac identity itself (`--reset-pairing`):
/// clears pins.json and identity.json's §3 mirror pin.
enum DeviceIdentityV2Reset {
    static func resetPairingState(profile: Profile) {
        let identityUrl = IdentityFileV2.fileUrl(in: profile)
        if var identity = IdentityFileV2(url: identityUrl).load() {
            identity.pin = ""
            IdentityFileV2(url: identityUrl).save(identity)
        }
        PhonePinStoreV2(fileUrl: PhonePinStoreV2.fileUrl(in: profile)).clear()
    }
}

/// §7 rate limit: a re-pair sheet may auto-open at most once per address per
/// minute, so a hostile LAN address cannot hold the UI hostage with repeated
/// pin mismatches.
final class PinMismatchTracker: ObservableObject {
    static let window: TimeInterval = 60

    @Published var mismatchedDeviceId: String? = nil

    private var lastAutoOpen: [String: Date] = [:]
    private let lock = NSLock()

    /// Whether a re-pair sheet may auto-open for this device right now.
    func allowAutoOpen(deviceId: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let last = lastAutoOpen[deviceId], now.timeIntervalSince(last) < Self.window {
            return false
        }
        lastAutoOpen[deviceId] = now
        return true
    }

    func note(deviceId: String) {
        DispatchQueue.main.async { [weak self] in
            self?.mismatchedDeviceId = deviceId
        }
    }

    func clear() {
        DispatchQueue.main.async { [weak self] in self?.mismatchedDeviceId = nil }
    }
}

/// The ⚠ "re-pair" hint on a phone row (§7): the stored pin disagrees with the
/// phone's certificate, so the session died with `certificate changed`. Clicking
/// Pair re-runs the code pairing; not wired yet (phase-2 step 3+).
struct RePairHintBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text("re-pair")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help("The phone's key changed ( reinstall or rotation) — pair again to resume.")
        .accessibilityLabel("Re-pair required")
    }
}
