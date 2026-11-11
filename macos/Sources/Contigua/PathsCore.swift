// The paths layer's pure core (docs/design/paths.md §3, §5, §8,
// docs/specs/transport.md PATH-4/10/19, docs/PROTOCOL.md § "Paths"): the
// RELIABLE/ACK codec, the replay buffer with credit, the reorder window, the
// ids and the protocol version.
//
// Nothing here touches a socket or a clock: the session machine drives it. The
// phone's `Paths.kt` mirrors these shapes and their golden vectors.

import Foundation

// MARK: - Version (PATH-1, PATH-2)

enum PathVersion {
    /// `hello.v` and `welcome`'s protocol (docs/PROTOCOL.md "Versioning").
    static let current = 4

    /// True when a peer's `v` (nil = a v3 peer that sends none) is not ours.
    static func refused(_ peer: Int?) -> Bool { peer != current }

    /// The Mac's sentence for a phone that refused it (PATH-1): the phone's `v`
    /// below ours, or absent, means the phone is the older app.
    static func macSentence(peer: Int?) -> String {
        if let peer, peer > current { return "Update Contigua on this Mac." }
        return "Update Contigua on your phone."
    }

    /// The phone's sentence for a Mac whose `hello` carried another `v`.
    static func phoneSentence(mac: Int?) -> String {
        if let mac, mac > current { return "Update Contigua on your phone." }
        return "Update Contigua on this Mac."
    }

    /// The `error version` frame both sides send; `v` is the refusing side's own.
    static func refusal(own: Int = current) -> Frame {
        Frame(type: .json, stream: 0, payload: JSONFrame.payload(["t": "error", "code": "version", "v": own]))
    }
}

/// PATH-2: there is no reduced transport. The session layer is the only one a
/// protocol-4 session has, and a version mismatch is a refusal, never a retry
/// as a single connection.
enum NoFallback {
    static let sessionLayerAlwaysOn = true

    static func isRefusedAsAVersionMismatch(code: String) -> Bool { code == "version" }
}

// MARK: - Ids (PATH-3, PATH-19)

enum PathIds {
    /// 128 random bits as 32 lowercase hex. Never derived from a device or a peer.
    static func sessionId() -> String { randomHex(bytes: 16) }

    /// 8 lowercase hex, unique among `live` (the session's live path ids).
    static func pathId(among live: Set<String>,
                       using generator: inout some RandomNumberGenerator) -> String {
        while true {
            let candidate = randomHex(bytes: 4, using: &generator)
            if !live.contains(candidate) { return candidate }
        }
    }

    static func pathId(among live: Set<String>) -> String {
        var generator = SystemRandomNumberGenerator()
        return pathId(among: live, using: &generator)
    }

    static func randomHex(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return randomHex(bytes: count, using: &generator)
    }

    static func randomHex(bytes count: Int, using generator: inout some RandomNumberGenerator) -> String {
        var out = ""
        out.reserveCapacity(count * 2)
        for _ in 0..<count {
            out += String(format: "%02x", UInt8.random(in: 0...255, using: &generator))
        }
        return out
    }
}

// MARK: - Codec (PATH-4, PATH-9)

enum PathCodecError: Error, Equatable {
    /// The inner payload cannot be wrapped: the wire's max is 8 MiB.
    case frameTooLarge(Int)
    /// The wrapped type is not a reliable type.
    case notReliable(UInt8)
    /// The outer `stream` disagreed with `innerStream`.
    case streamMismatch(outer: UInt32, inner: UInt32)
    case malformed
}

enum PathCodec {
    static let reliableType: UInt8 = 0x30
    static let ackType: UInt8 = 0x31

    /// One RELIABLE payload is 8 (seq) + 1 (type) + 4 (stream) + n.
    static let wrapperBytes = 18
    /// The largest inner payload the 8 MiB frame cap can carry.
    static let maxInnerPayload = Int(maxFrameSize) - wrapperBytes

    /// Reliable types, wrapped in 0x30 (docs/design/paths.md §5.5).
    static func isReliable(_ type: UInt8) -> Bool {
        switch type {
        case 0x01, 0x10, 0x11, 0x12, 0x20, 0x21, 0x22, 0x23, 0x24: return true
        default: return false
        }
    }

    /// Bulk producers share the 12 MiB budget; everything else is control.
    static func isBulk(_ type: UInt8) -> Bool {
        switch type {
        case 0x20, 0x21, 0x22, 0x23, 0x24: return true
        default: return false
        }
    }

    static func encodeReliable(seq: UInt64, inner: Frame) throws -> Frame {
        guard isReliable(inner.type) else { throw PathCodecError.notReliable(inner.type) }
        guard inner.payload.count <= maxInnerPayload else {
            throw PathCodecError.frameTooLarge(inner.payload.count)
        }
        var payload = [UInt8]()
        payload.reserveCapacity(wrapperBytes + inner.payload.count)
        payload.appendBE(seq)
        payload.append(inner.type)
        payload.appendBE(inner.stream)
        payload.append(contentsOf: inner.payload)
        return Frame(type: reliableType, stream: inner.stream, payload: payload)
    }

    static func decodeReliable(_ frame: Frame) throws -> ReliableFrame {
        guard frame.type == reliableType else { throw PathCodecError.malformed }
        var reader = ByteReader(frame.payload)
        let seq = try reader.u64()
        let innerType = try reader.u8()
        let innerStream = try reader.u32()
        guard innerStream == frame.stream else {
            throw PathCodecError.streamMismatch(outer: frame.stream, inner: innerStream)
        }
        return ReliableFrame(seq: seq,
                             inner: Frame(type: innerType, stream: innerStream, payload: reader.rest()))
    }

    static func encodeAck(_ ack: UInt64) -> Frame {
        var payload = [UInt8]()
        payload.appendBE(ack)
        return Frame(type: ackType, stream: 0, payload: payload)
    }

    static func decodeAck(_ frame: Frame) throws -> UInt64 {
        guard frame.type == ackType, frame.stream == 0, frame.payload.count == 8 else {
            throw PathCodecError.malformed
        }
        var reader = ByteReader(frame.payload)
        return try reader.u64()
    }
}

struct ReliableFrame: Equatable {
    var seq: UInt64
    var inner: Frame
}

// MARK: - Replay buffer and credit (PATH-10, PATH-15)

/// The per-direction send buffer. A producer asks [canAdmit] before it reads
/// the next chunk; [append] only ever sees a frame that fits, so the buffer
/// never overflows and no frame is dropped (docs/design/paths.md §8).
struct ReplayBuffer {
    static let capacity = 16 << 20
    static let bulkCapacity = 12 << 20

    struct Entry: Equatable {
        var seq: UInt64
        var frame: [UInt8]
        var bulk: Bool
    }

    /// Everything below this seq was received by the peer, in order.
    private(set) var lastAck: UInt64 = 1
    /// The seq of the newest frame appended.
    private(set) var lastSeq: UInt64 = 0
    private(set) var heldBytes = 0
    private(set) var bulkBytes = 0
    private var entries: [Entry] = []

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }
    var nextSeq: UInt64 { lastSeq + 1 }

    /// True when a frame of [bytes] may be created now. Bulk producers are
    /// capped at 12 MiB so 4 MiB is always left for control; control may use
    /// the whole 16 MiB when no bulk runs. The wire's max is 8 MiB, so a frame
    /// larger than the buffer cannot exist.
    func canAdmit(bytes: Int, bulk: Bool) -> Bool {
        // `bytes` is the encoded frame (its 4-byte length prefix included), so
        // the wire's 8 MiB `len` is at most `maxFrameSize + 4` bytes here.
        guard bytes >= 0, bytes <= Int(maxFrameSize) + 4 else { return false }
        guard heldBytes + bytes <= Self.capacity else { return false }
        if bulk { return bulkBytes + bytes <= Self.bulkCapacity }
        return true
    }

    /// Appends one reliable frame. The caller has checked [canAdmit] with the
    /// same size and [seq] is the next seq. `force` is for the switch's marker
    /// only: one small control frame that never waits for credit (E-6).
    mutating func append(seq: UInt64, frame: [UInt8], bulk: Bool,
                         force: Bool = false) throws {
        guard seq == nextSeq else { throw PathCodecError.malformed }
        guard force || canAdmit(bytes: frame.count, bulk: bulk) else {
            throw PathCodecError.frameTooLarge(frame.count)
        }
        entries.append(Entry(seq: seq, frame: frame, bulk: bulk))
        lastSeq = seq
        heldBytes += frame.count
        if bulk { bulkBytes += frame.count }
    }

    /// Releases everything the peer acknowledged. Returns the number released.
    /// An ack above [lastSeq] is a protocol error the session ends on.
    mutating func ack(_ nextExpected: UInt64) -> Int {
        guard nextExpected > lastAck else { return 0 }
        lastAck = nextExpected
        var released = 0
        while let first = entries.first, first.seq < nextExpected {
            entries.removeFirst()
            heldBytes -= first.frame.count
            if first.bulk { bulkBytes -= first.frame.count }
            released += 1
        }
        return released
    }

    func ackAboveSent(_ ack: UInt64) -> Bool { ack > lastSeq + 1 }

    /// The unacked frames from the peer's last ack, oldest first: what a switch
    /// replays.
    var unacked: [Entry] { entries }

    mutating func discardAll() {
        entries.removeAll(keepingCapacity: false)
        heldBytes = 0
        bulkBytes = 0
    }
}

// MARK: - Reorder window (PATH-4, PATH-9, PATH-10)

/// The receive side's out-of-order window: 64 frames / 4 MiB. When it is full
/// the caller stops reading that path (TCP backpressure); it never drops.
struct ReorderWindow {
    static let maxFrames = 64
    static let maxBytes = 4 << 20

    enum Result: Equatable {
        /// Frames ready to deliver, in order (one or more when a gap filled).
        case deliver([ReliableFrame])
        /// A seq below the next expected: dropped, ack immediately.
        case duplicate
        /// Stored above the gap; nothing to deliver yet.
        case buffered
        /// The window is full: stop reading the path until the gap fills.
        case full
    }

    private(set) var expected: UInt64 = 1
    private(set) var bufferedBytes = 0
    private var buffered: [UInt64: ReliableFrame] = [:]

    var bufferedCount: Int { buffered.count }
    var ack: UInt64 { expected }

    mutating func receive(_ frame: ReliableFrame, payloadBytes: Int? = nil) -> Result {
        if frame.seq < expected { return .duplicate }
        if frame.seq == expected {
            var out = [frame]
            expected += 1
            while let next = buffered.removeValue(forKey: expected) {
                bufferedBytes -= next.inner.payload.count
                out.append(next)
                expected += 1
            }
            return .deliver(out)
        }
        if buffered[frame.seq] != nil { return .duplicate }
        let size = payloadBytes ?? frame.inner.payload.count
        if buffered.count >= Self.maxFrames || bufferedBytes + size > Self.maxBytes {
            return .full
        }
        buffered[frame.seq] = frame
        bufferedBytes += size
        return .buffered
    }

    mutating func reset() {
        expected = 1
        buffered.removeAll()
        bufferedBytes = 0
    }
}

// MARK: - Provider interface (PATH-20, design §9)

enum PathKind: String {
    case lan
    case direct
    case wan

    /// The declared floor, never measured (design §7.1). `direct` is scored at
    /// the 8 Mbit/s a 1080p60 mirror needs until P4 measures it.
    var throughputClass: ThroughputClass {
        switch self {
        case .lan: return ThroughputClass(floorMbps: 100, typicalMbps: 209)
        case .direct: return ThroughputClass(floorMbps: 8, typicalMbps: nil)
        case .wan: return ThroughputClass(floorMbps: 2, typicalMbps: 8)
        }
    }
}

struct ThroughputClass: Equatable {
    var floorMbps: Int
    var typicalMbps: Int?
}

enum PathAvailability: Equatable {
    case ready
    /// Not usable yet, with a code the settings page explains.
    case needsSetup(String)
    /// Not usable on this machine/phone, with a code.
    case unavailable(String)

    var isReady: Bool { self == .ready }
}

/// A dialable target for one phone, or a listener port on the phone's side.
enum PathEndpoint: Equatable {
    case hostPort(host: String, port: UInt16)
    case service(String)
}

