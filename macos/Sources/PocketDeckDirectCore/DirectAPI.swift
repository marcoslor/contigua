#if POCKETDECK_DIRECT
import Foundation

/// The helper's wire vocabulary (docs/design/direct-link.md §2.5). Pure: no
/// sockets, no files, so the request shapes are unit-tested without root.
public enum DirectWireCode: String, Sendable, Equatable, CaseIterable {
    case badRequest = "bad_request"
    case notReady = "not_ready"
    case notConsoleUser = "not_console_user"
    case busy
    case noKey = "no_key"
    case ndpTimeout = "ndp_timeout"
    case ndpRefused = "ndp_refused"
    case connectFailed = "connect_failed"
    case linkUnknown = "link_unknown"
    case tooManyLinks = "too_many_links"
}

public struct DirectPeerSpec: Sendable, Equatable {
    /// The interface the peer was reported on. Informational in the test
    /// round; the helper's own interface comes from its environment.
    public var interface: String
    /// Lowercase `aa:bb:cc:dd:ee:ff`.
    public var mac: String
    /// A link-local IPv6, optionally scoped (`fe80::1%feth0`).
    public var linkLocal: String

    public init(interface: String, mac: String, linkLocal: String) {
        self.interface = interface
        self.mac = mac
        self.linkLocal = linkLocal
    }
}

/// A `dial` request (§2.5). `peer`, `service` and `psk` travel together, or
/// not at all: the latter is the test-only static peer, accepted only with
/// `POCKETDECK_DIRECT_TEST=1`.
public struct DirectDial: Sendable, Equatable {
    /// 32 lowercase hex; the phone's own id is not on the air.
    public var peer: String?
    public var service: String?
    /// The 32-byte NDP key as 64 lowercase hex; never logged or echoed.
    public var psk: String?
    public var port: UInt16

    public init(peer: String?, service: String?, psk: String?, port: UInt16) {
        self.peer = peer
        self.service = service
        self.psk = psk
        self.port = port
    }
}

public enum DirectRequest: Sendable, Equatable {
    case hello(version: Int)
    case probe
    case peer(DirectPeerSpec)
    case discover(service: String, psk: String)
    case dial(DirectDial)
    case close(link: String)
    case links
    /// Test-only: print lwIP's counters to the helper's stderr.
    case stats
    /// Stop the NAN session (its data session, subscription and peer); links
    /// over it are closed. Idempotent.
    case stop
}

public enum DirectRequestError: Error, Sendable, Equatable {
    case notAnObject
    case unknownOp(String)
    case invalidField(String)
    case incompleteDial

    public var code: DirectWireCode { .badRequest }

    public var message: String {
        switch self {
        case .notAnObject: return "request must be a JSON object"
        case .unknownOp(let op): return "unknown op '\(op.prefix(24))'"
        case .invalidField(let field): return "invalid field '\(field.prefix(24))'"
        case .incompleteDial: return "dial needs peer, svc and psk together"
        }
    }
}

/// Fixed caps from §2.5 and the bridge's backpressure rule.
public enum DirectLimits {
    public static let requestBytes = 4096
    public static let replyBytes = 4096
    /// Per direction, per link: above this the helper stops reading (the
    /// socket's own buffer is the second cap) instead of buffering forever.
    public static let linkBufferBytes = 512 * 1024
    public static let readChunkBytes = 64 * 1024
    public static let writeChunkBytes = 32 * 1024
    public static let maxLinks = 8
    public static let dialTimeoutSeconds = 10
}

public enum DirectRequestParser {
    public static func parse(_ line: Data) throws -> DirectRequest {
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let json = object as? [String: Any] else {
            throw DirectRequestError.notAnObject
        }
        guard let op = json["op"] as? String else {
            throw DirectRequestError.invalidField("op")
        }
        switch op {
        case "hello":
            guard let version = integer(json["v"]), version >= 1 else {
                throw DirectRequestError.invalidField("v")
            }
            return .hello(version: version)
        case "probe":
            return .probe
        case "peer":
            guard let name = json["if"] as? String, !name.isEmpty, name.count <= 16,
                  !name.contains("\0") else {
                throw DirectRequestError.invalidField("if")
            }
            guard let mac = json["mac"] as? String, isMAC(mac) else {
                throw DirectRequestError.invalidField("mac")
            }
            guard let ll = json["ll"] as? String, IPv6Address.parse(ll) != nil else {
                throw DirectRequestError.invalidField("ll")
            }
            return .peer(DirectPeerSpec(interface: name, mac: mac, linkLocal: ll))
        case "dial":
            guard let port = integer(json["port"]), port >= 1, port <= 65535 else {
                throw DirectRequestError.invalidField("port")
            }
            // The NAN fields travel together, or not at all (the latter is
            // the test-only static peer). The fields are validated when they
            // are present; a partial request is refused.
            let peer = try optionalText(json["peer"], field: "peer", max: 32)
            let service = try optionalText(json["svc"], field: "svc", max: 64)
            let psk = try optionalText(json["psk"], field: "psk", max: 64)
            if peer != nil || service != nil || psk != nil {
                guard let peer, let service, let psk,
                      isLowerHex(peer, count: 32), isLowerHex(psk, count: 64),
                      !service.isEmpty else {
                    throw DirectRequestError.incompleteDial
                }
                return .dial(DirectDial(peer: peer, service: service, psk: psk,
                                        port: UInt16(port)))
            }
            return .dial(DirectDial(peer: nil, service: nil, psk: nil,
                                    port: UInt16(port)))
        case "discover":
            guard let service = json["svc"] as? String, !service.isEmpty,
                  service.count <= 64, !service.contains("\0") else {
                throw DirectRequestError.invalidField("svc")
            }
            guard let psk = json["psk"] as? String, isLowerHex(psk, count: 64) else {
                throw DirectRequestError.invalidField("psk")
            }
            return .discover(service: service, psk: psk)
        case "stop":
            return .stop
        case "close":
            guard let link = json["link"] as? String, isLowerHex(link, count: 16) else {
                throw DirectRequestError.invalidField("link")
            }
            return .close(link: link)
        case "links":
            return .links
        case "stats":
            return .stats
        default:
            throw DirectRequestError.unknownOp(op)
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        // JSON bools arrive as NSNumber; a bool is not a port.
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, double >= 0, double <= 1_000_000 else { return nil }
        return Int(double)
    }

    private static func optionalText(_ value: Any?, field: String,
                                     max: Int) throws -> String? {
        if value == nil || value is NSNull { return nil }
        guard let text = value as? String, text.count <= max,
              !text.contains("\0") else {
            throw DirectRequestError.invalidField(field)
        }
        return text
    }
}

public struct DirectLinkReport: Sendable, Equatable {
    public var link: String
    public var peer: String
    public var state: String
    public var rttMilliseconds: Int

    public init(link: String, peer: String, state: String, rttMilliseconds: Int = 0) {
        self.link = link
        self.peer = peer
        self.state = state
        self.rttMilliseconds = rttMilliseconds
    }
}

public struct DirectToolkitReport: Sendable, Equatable {
    public var publish: Bool
    public var subscribe: Bool
    public var dataLinks: Int

    public init(publish: Bool, subscribe: Bool, dataLinks: Int) {
        self.publish = publish
        self.subscribe = subscribe
        self.dataLinks = dataLinks
    }
}

public enum DirectReply: Sendable, Equatable {
    case hello(version: Int, toolkit: DirectToolkitReport)
    case probe(ready: Bool, codes: [String], detail: String)
    case dial(link: String, mtu: Int)
    case ok
    case links([DirectLinkReport])
    case error(DirectWireCode, message: String)

    public func encoded() -> Data {
        var object: [String: Any] = ["ok": !isError]
        switch self {
        case .hello(let version, let toolkit):
            object["v"] = version
            object["toolkit"] = ["publish": toolkit.publish,
                                 "subscribe": toolkit.subscribe,
                                 "dataLinks": toolkit.dataLinks]
        case .probe(let ready, let codes, let detail):
            object["ready"] = ready
            object["codes"] = codes
            object["detail"] = detail
        case .dial(let link, let mtu):
            object["link"] = link
            object["mtu"] = mtu
        case .ok:
            break
        case .links(let reports):
            object["links"] = reports.map {
                ["link": $0.link, "peer": $0.peer, "state": $0.state,
                 "rttMs": $0.rttMilliseconds]
            }
        case .error(let code, let message):
            object["code"] = code.rawValue
            object["message"] = String(message.prefix(200))
        }
        let data = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.sortedKeys])) ?? Data("{\"ok\":false,\"code\":\"bad_request\"}".utf8)
        return data
    }

    private var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

/// Line framing for the UNIX socket: one request per `\n`, `\n`-terminated,
/// and a line longer than 4096 bytes is refused instead of buffered.
public struct DirectLineFramer {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            if line.count > DirectLimits.requestBytes {
                throw DirectRequestError.invalidField("line")
            }
            lines.append(Data(line))
            buffer = buffer[buffer.index(after: newline)...]
        }
        if buffer.count > DirectLimits.requestBytes {
            throw DirectRequestError.invalidField("line")
        }
        return lines
    }

    /// Bytes buffered without a newline yet (the daemon closes a peer that
    /// sends more than the cap).
    public var pendingBytes: Int { buffer.count }
}

/// §2.5's access control: the peer's uid must be the console user's.
public func directPeerAllowed(peerUID: UInt32, consoleUID: UInt32) -> Bool {
    peerUID == consoleUID
}

public func isLowerHex(_ text: String, count: Int) -> Bool {
    text.count == count && text.allSatisfy { ($0.isNumber || ("a"..."f").contains($0)) }
}

public func isMAC(_ text: String) -> Bool {
    let parts = text.split(separator: ":", omittingEmptySubsequences: false)
    return parts.count == 6 && parts.allSatisfy {
        $0.count == 2 && $0.allSatisfy { c in ("0"..."9").contains(c) || ("a"..."f").contains(c) }
    }
}

public enum IPv6Address {
    /// Parses `fe80::1` / `fe80::1%feth0` into 16 bytes. Returns nil for
    /// anything that is not a plain (optionally scoped) unicast address.
    public static func parse(_ text: String) -> [UInt8]? {
        let bare = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        guard !bare.isEmpty, bare.count <= 45 else { return nil }
        var groups: [String] = []
        if bare.contains("::") {
            let halves = bare.components(separatedBy: "::")
            guard halves.count == 2 else { return nil }
            let head = halves[0].isEmpty ? [] : halves[0].split(separator: ":").map(String.init)
            let tail = halves[1].isEmpty ? [] : halves[1].split(separator: ":").map(String.init)
            guard head.count + tail.count <= 7 else { return nil }
            groups = head + Array(repeating: "0", count: 8 - head.count - tail.count) + tail
        } else {
            groups = bare.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard groups.count == 8 else { return nil }
        }
        var bytes: [UInt8] = []
        for group in groups {
            guard !group.isEmpty, group.count <= 4,
                  let value = UInt16(group, radix: 16) else { return nil }
            bytes.append(UInt8(value >> 8))
            bytes.append(UInt8(value & 0xff))
        }
        guard bytes.count == 16 else { return nil }
        return bytes
    }

    public static func format(_ bytes: [UInt8]) -> String {
        guard bytes.count == 16 else { return "" }
        var groups: [UInt16] = []
        for index in stride(from: 0, to: 16, by: 2) {
            groups.append((UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1]))
        }
        // Compress the longest run of zeros, as RFC 5952 asks.
        var bestStart = -1
        var bestLength = 0
        var index = 0
        while index < 8 {
            guard groups[index] == 0 else { index += 1; continue }
            var end = index
            while end < 8 && groups[end] == 0 { end += 1 }
            if end - index > bestLength {
                bestStart = index
                bestLength = end - index
            }
            index = end
        }
        var parts: [String] = []
        index = 0
        while index < 8 {
            if index == bestStart {
                parts.append("")
                index += bestLength
                if index == 8 { parts.append("") }
            } else {
                parts.append(String(groups[index], radix: 16))
                index += 1
            }
        }
        return parts.joined(separator: ":")
    }
}
#endif
