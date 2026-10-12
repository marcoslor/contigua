// Reaching a dozing phone without mDNS.
//
// A long-idle locked phone can stop answering mDNS while its server is still
// listening, and after a disconnect discovery may take a while to come back.
// For each paired device we remember the resolved IPv4 address of the last
// successful session (UserDefaults — reachability data, not a secret; pairing
// keys stay in the Keychain) and fall back to it after a short discovery grace.
//
// Discovery always wins over the cache when both are available, and the cached
// address is never trusted blindly: the handshake challenge names the phone, so
// a cached address that now answers with a different device id is dropped.

import Foundation
import Network

struct CachedAddress: Equatable {
    var host: String
    var port: UInt16
}

/// One paired device with a remembered address.
struct CachedDevice: Equatable {
    var deviceId: String
    var address: CachedAddress
}

/// Last successful IPv4 address (and last known name) per paired device id.
final class CachedDeviceStore {
    static let addressesKey = "cachedAddresses"
    static let namesKey = "cachedDeviceNames"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var deviceIds: [String] {
        (defaults.dictionary(forKey: Self.addressesKey) as? [String: String])?.keys.sorted() ?? []
    }

    var devices: [CachedDevice] {
        deviceIds.compactMap { id in address(forDeviceId: id).map { CachedDevice(deviceId: id, address: $0) } }
    }

    func address(forDeviceId deviceId: String) -> CachedAddress? {
        rawAddresses()[deviceId].flatMap(Self.parse)
    }

    func store(_ address: CachedAddress, deviceId: String) {
        guard !deviceId.isEmpty, Self.isIPv4(address.host), address.port > 0 else { return }
        var map = rawAddresses()
        map[deviceId] = Self.encode(address)
        defaults.set(map, forKey: Self.addressesKey)
    }

    func name(forDeviceId deviceId: String) -> String? {
        let names = defaults.dictionary(forKey: Self.namesKey) as? [String: String]
        return names?[deviceId]
    }

    func store(name: String, deviceId: String) {
        guard !deviceId.isEmpty, !name.isEmpty else { return }
        var names = defaults.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:]
        names[deviceId] = name
        defaults.set(names, forKey: Self.namesKey)
    }

    /// Forget everything we remembered about one device (address + name).
    func forget(deviceId: String) {
        var map = rawAddresses()
        map.removeValue(forKey: deviceId)
        defaults.set(map, forKey: Self.addressesKey)
        var names = defaults.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:]
        names.removeValue(forKey: deviceId)
        defaults.set(names, forKey: Self.namesKey)
    }

    func removeAll() {
        defaults.removeObject(forKey: Self.addressesKey)
        defaults.removeObject(forKey: Self.namesKey)
    }

    // MARK: Encoding

    static func encode(_ address: CachedAddress) -> String { "\(address.host):\(address.port)" }

    static func parse(_ raw: String) -> CachedAddress? {
        guard let colon = raw.lastIndex(of: ":") else { return nil }
        let host = String(raw[..<colon])
        guard let port = UInt16(raw[raw.index(after: colon)...]), port > 0, isIPv4(host) else { return nil }
        return CachedAddress(host: host, port: port)
    }

    /// IPv4 literals only: a hostname could resolve somewhere else (or hang)
    /// on the next launch, which is exactly the mDNS failure we are bypassing.
    static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, let value = UInt8(part) else { return false }
            return String(value) == part // rejects "01", "+1", "1e1"
        }
    }

    private func rawAddresses() -> [String: String] {
        defaults.dictionary(forKey: Self.addressesKey) as? [String: String] ?? [:]
    }
}

extension NWEndpoint {
    /// The resolved IPv4 `host:port` of a connected endpoint, when there is one.
    var resolvedIPv4Address: CachedAddress? {
        guard case let .hostPort(host, port) = self else { return nil }
        let literal = "\(host)"
        guard CachedDeviceStore.isIPv4(literal) else { return nil }
        return CachedAddress(host: literal, port: port.rawValue)
    }
}

/// Decides what to connect to: a discovered service endpoint always wins over
/// a cached address; the cache only fills the discovery gap.
struct DirectConnectPolicy {
    /// Give mDNS this long before trusting the cache (~3 s per the task).
    var discoveryGrace: TimeInterval = 3

    enum Decision: Equatable {
        case useDiscovery(deviceId: String)
        case useCached(CachedDevice)
        case none
    }

    /// Launch decision: no session yet.
    ///
    /// - Parameters:
    ///   - discoveredPaired: paired phones currently visible over mDNS, in order.
    ///   - cached: paired devices with a remembered address, most relevant first.
    ///   - activeDeviceId: the device of the current session (nil = none).
    ///   - activeReady: the current session finished the handshake.
    ///   - elapsedSinceLaunch: seconds since discovery started.
    func decide(discoveredPaired: [String],
                cached: [CachedDevice],
                activeDeviceId: String?,
                activeReady: Bool,
                elapsedSinceLaunch: TimeInterval) -> Decision {
        if activeReady { return .none }
        if let first = discoveredPaired.first {
            // Already on it (connecting or retrying); discovery does not restart it.
            if activeDeviceId == first { return .none }
            return .useDiscovery(deviceId: first) // discovery overrides the cache
        }
        guard let candidate = cached.first else { return .none }
        // A session is already retrying its own endpoint; don't replace it.
        if activeDeviceId != nil { return .none }
        guard elapsedSinceLaunch >= discoveryGrace else { return .none }
        return .useCached(candidate)
    }

    /// Decision after the discovery session to `deviceId` failed: the phone may
    /// still be listening on its last known address even though mDNS is gone.
    func failureDecision(deviceId: String?,
                         cached: [CachedDevice],
                         discoveredPaired: [String]) -> Decision {
        if let deviceId, let remembered = cached.first(where: { $0.deviceId == deviceId }) {
            return .useCached(remembered)
        }
        if let first = discoveredPaired.first, first != deviceId {
            return .useDiscovery(deviceId: first)
        }
        return .none
    }
}
