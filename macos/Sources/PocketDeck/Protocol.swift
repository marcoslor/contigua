// Wire codec. The single source of truth is docs/PROTOCOL.md; this file mirrors
// it byte for byte: u32 length prefix (= type + stream + payload), big-endian
// everywhere, max frame 8 MiB.

import Foundation

enum MessageType: UInt8 {
    case json = 0x01
    case videoConfig = 0x02
    case videoFrame = 0x03
    case audioConfig = 0x04
    case audioFrame = 0x05
    case touch = 0x10
    case scroll = 0x11
    case key = 0x12
    case hover = 0x13
    case apkData = 0x20
    case shareData = 0x21
    case dropData = 0x22
    case clipData = 0x23
    case fsData = 0x24
}

enum ProtocolError: Error, Equatable {
    case oversizedFrame(UInt32)
    case shortFrame(UInt32)
    case truncated
}

/// A receiver that sees a frame larger than this closes the session.
let maxFrameSize: UInt32 = 8 << 20

struct Frame: Equatable {
    var type: UInt8
    var stream: UInt32
    var payload: [UInt8]

    init(type: UInt8, stream: UInt32, payload: [UInt8]) {
        self.type = type
        self.stream = stream
        self.payload = payload
    }

    init(type: MessageType, stream: UInt32, payload: [UInt8]) {
        self.init(type: type.rawValue, stream: stream, payload: payload)
    }

    var messageType: MessageType? { MessageType(rawValue: type) }

    /// The inverse of [encoded] for the path layer, which sends encoded bytes.
    init?(encoded bytes: [UInt8]) {
        guard bytes.count >= 9 else { return nil }
        self.type = bytes[4]
        self.stream = UInt32(bytes[5]) << 24 | UInt32(bytes[6]) << 16
            | UInt32(bytes[7]) << 8 | UInt32(bytes[8])
        self.payload = Array(bytes[9...])
    }

    /// len counts type + stream + payload, i.e. everything after the prefix.
    var encoded: [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(payload.count + 9)
        out.appendBE(UInt32(payload.count + 5))
        out.append(type)
        out.appendBE(stream)
        out.append(contentsOf: payload)
        return out
    }

    func encodedData() -> Data { Data(encoded) }
}

/// Incremental length-prefixed reader. Feed it socket chunks, get whole frames.
struct FrameDecoder {
    private var buffer: [UInt8] = []

    /// Buffered but not yet decoded bytes; useful for diagnostics.
    var pending: Int { buffer.count }

    mutating func append(_ data: [UInt8]) throws -> [Frame] {
        if !data.isEmpty { buffer.append(contentsOf: data) }
        return try drain()
    }

    mutating func append(_ data: Data) throws -> [Frame] {
        try append([UInt8](data))
    }

    private mutating func drain() throws -> [Frame] {
        var frames: [Frame] = []
        var consumed = 0
        while buffer.count - consumed >= 4 {
            let len = UInt32(buffer[consumed]) << 24 | UInt32(buffer[consumed + 1]) << 16
                | UInt32(buffer[consumed + 2]) << 8 | UInt32(buffer[consumed + 3])
            if len > maxFrameSize { throw ProtocolError.oversizedFrame(len) }
            guard len >= 5 else { throw ProtocolError.shortFrame(len) }
            let total = 4 + Int(len)
            guard buffer.count - consumed >= total else { break }
            let type = buffer[consumed + 4]
            let stream = UInt32(buffer[consumed + 5]) << 24 | UInt32(buffer[consumed + 6]) << 16
                | UInt32(buffer[consumed + 7]) << 8 | UInt32(buffer[consumed + 8])
            frames.append(Frame(type: type, stream: stream,
                                payload: Array(buffer[(consumed + 9)..<(consumed + total)])))
            consumed += total
        }
        if consumed > 0 { buffer.removeFirst(consumed) }
        return frames
    }
}

// MARK: - Big-endian helpers

extension Array where Element == UInt8 {
    mutating func appendBE(_ value: UInt16) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }

    mutating func appendBE(_ value: UInt32) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }

    mutating func appendBE(_ value: UInt64) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }

    mutating func appendBE(_ value: Float) {
        var be = value.bitPattern.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
}

/// Sequential big-endian reader over a payload.
struct ByteReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - index }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw ProtocolError.truncated }
        defer { index += 1 }
        return bytes[index]
    }

    mutating func u16() throws -> UInt16 {
        guard remaining >= 2 else { throw ProtocolError.truncated }
        defer { index += 2 }
        return UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
    }

    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw ProtocolError.truncated }
        defer { index += 4 }
        return UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16
            | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3])
    }

    mutating func u64() throws -> UInt64 {
        guard remaining >= 8 else { throw ProtocolError.truncated }
        defer { index += 8 }
        var value: UInt64 = 0
        for offset in 0..<8 { value = value << 8 | UInt64(bytes[index + offset]) }
        return value
    }

    mutating func f32() throws -> Float {
        Float(bitPattern: try u32())
    }

    mutating func rest() -> [UInt8] {
        defer { index = bytes.count }
        return Array(bytes[index...])
    }
}

// MARK: - Typed payloads

/// VIDEO_CONFIG: u8 codec · u16 width · u16 height · Annex-B SPS+PPS.
struct VideoConfig: Equatable {
    static let codecH264: UInt8 = 1

    var codec: UInt8
    var width: UInt16
    var height: UInt16
    var parameterSets: [UInt8]

    init(codec: UInt8 = VideoConfig.codecH264, width: UInt16, height: UInt16, parameterSets: [UInt8]) {
        self.codec = codec
        self.width = width
        self.height = height
        self.parameterSets = parameterSets
    }

    init(payload: [UInt8]) throws {
        var r = ByteReader(payload)
        codec = try r.u8()
        width = try r.u16()
        height = try r.u16()
        parameterSets = r.rest()
    }

    var payload: [UInt8] {
        var out = [UInt8]()
        out.append(codec)
        out.appendBE(width)
        out.appendBE(height)
        out.append(contentsOf: parameterSets)
        return out
    }
}

/// VIDEO_FRAME: u64 ptsUs · u8 flags (bit0 keyframe) · Annex-B access unit.
struct VideoFrameData: Equatable {
    var ptsUs: UInt64
    var flags: UInt8
    var annexB: [UInt8]

    var isKeyframe: Bool { flags & 0x01 != 0 }

    init(ptsUs: UInt64, flags: UInt8, annexB: [UInt8]) {
        self.ptsUs = ptsUs
        self.flags = flags
        self.annexB = annexB
    }

    init(payload: [UInt8]) throws {
        var r = ByteReader(payload)
        ptsUs = try r.u64()
        flags = try r.u8()
        annexB = r.rest()
    }

    var payload: [UInt8] {
        var out = [UInt8]()
        out.appendBE(ptsUs)
        out.append(flags)
        out.append(contentsOf: annexB)
        return out
    }
}

/// AUDIO_CONFIG: u8 codec (2 Opus, 3 AAC) · u32 sampleRate · u8 channels ·
/// u16 frameMs · codec setup bytes.
struct AudioConfig: Equatable {
    static let codecOpus: UInt8 = 2
    static let codecAAC: UInt8 = 3

    var codec: UInt8
    var sampleRate: UInt32
    var channels: UInt8
    var frameMs: UInt16
    var setup: [UInt8]

    init(codec: UInt8, sampleRate: UInt32, channels: UInt8, frameMs: UInt16, setup: [UInt8]) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.frameMs = frameMs
        self.setup = setup
    }

    init(payload: [UInt8]) throws {
        var r = ByteReader(payload)
        codec = try r.u8()
        sampleRate = try r.u32()
        channels = try r.u8()
        frameMs = try r.u16()
        setup = r.rest()
    }

    var payload: [UInt8] {
        var out = [UInt8]()
        out.append(codec)
        out.appendBE(sampleRate)
        out.append(channels)
        out.appendBE(frameMs)
        out.append(contentsOf: setup)
        return out
    }
}

/// AUDIO_FRAME: u64 ptsUs · one encoder packet.
struct AudioFrameData: Equatable {
    var ptsUs: UInt64
    var packet: [UInt8]

    init(ptsUs: UInt64, packet: [UInt8]) {
        self.ptsUs = ptsUs
        self.packet = packet
    }

    init(payload: [UInt8]) throws {
        var r = ByteReader(payload)
        ptsUs = try r.u64()
        packet = r.rest()
    }

    var payload: [UInt8] {
        var out = [UInt8]()
        out.appendBE(ptsUs)
        out.append(contentsOf: packet)
        return out
    }
}

enum TouchAction: UInt8 {
    case down = 0
    case up = 1
    case move = 2
    case cancel = 3
}

/// TOUCH: u8 action · u8 pointerId · f32 nx · f32 ny.
struct TouchEvent: Equatable {
    var action: TouchAction
    var pointerId: UInt8
    var nx: Float
    var ny: Float

    init(action: TouchAction, pointerId: UInt8 = 0, nx: Float, ny: Float) {
        self.action = action
        self.pointerId = pointerId
        self.nx = nx
        self.ny = ny
    }

    init(payload: [UInt8]) throws {
        var r = ByteReader(payload)
        let rawAction = try r.u8()
        guard let action = TouchAction(rawValue: rawAction) else { throw ProtocolError.truncated }
        self.action = action
        pointerId = try r.u8()
        nx = try r.f32()
        ny = try r.f32()
    }

    var payload: [UInt8] {
        var out = [UInt8]()
        out.append(action.rawValue)
        out.append(pointerId)
        out.appendBE(nx)
        out.appendBE(ny)
        return out
    }
}

/// SCROLL: f32 nx · f32 ny · f32 hscroll · f32 vscroll (Android axis units).
struct ScrollEvent: Equatable {
    var nx: Float
    var ny: Float
    var hscroll: Float
    var vscroll: Float

    init(nx: Float, ny: Float, hscroll: Float, vscroll: Float) {
        self.nx = nx
        self.ny = ny
        self.hscroll = hscroll
        self.vscroll = vscroll
    }

    init(payload: [UInt8]) throws {
        var r = ByteReader(payload)
        nx = try r.f32()
        ny = try r.f32()
        hscroll = try r.f32()
        vscroll = try r.f32()
    }

    var payload: [UInt8] {
        var out = [UInt8]()
        out.appendBE(nx)
        out.appendBE(ny)
        out.appendBE(hscroll)
        out.appendBE(vscroll)
        return out
    }
}

/// KEY: u8 action (0 down, 1 up) · u32 keycode · u32 metaState.
struct KeyEvent: Equatable {
    var action: UInt8
    var keycode: UInt32
    var metaState: UInt32

    init(action: UInt8, keycode: UInt32, metaState: UInt32 = 0) {
        self.action = action
        self.keycode = keycode
        self.metaState = metaState
    }

    init(payload: [UInt8]) throws {
        var r = ByteReader(payload)
        action = try r.u8()
        keycode = try r.u32()
        metaState = try r.u32()
    }

    var payload: [UInt8] {
        var out = [UInt8]()
        out.append(action)
        out.appendBE(keycode)
        out.appendBE(metaState)
        return out
    }
}

/// HOVER: u8 action (0 enter, 1 move, 2 exit) · f32 nx · f32 ny. A mouse
/// hovering the video: no button is down and no touch is involved.
enum HoverAction: UInt8 {
    case enter = 0
    case move = 1
    case exit = 2
}

struct HoverEvent: Equatable {
    var action: HoverAction
    var nx: Float
    var ny: Float

    init(action: HoverAction, nx: Float, ny: Float) {
        self.action = action
        self.nx = nx
        self.ny = ny
    }

    init(payload: [UInt8]) throws {
        var r = ByteReader(payload)
        let rawAction = try r.u8()
        guard let action = HoverAction(rawValue: rawAction) else { throw ProtocolError.truncated }
        self.action = action
        nx = try r.f32()
        ny = try r.f32()
    }

    var payload: [UInt8] {
        var out = [UInt8]()
        out.append(action.rawValue)
        out.appendBE(nx)
        out.appendBE(ny)
        return out
    }
}

// MARK: - JSON envelope

/// A decoded JSON frame. Every object has a string `"t"`; unknown fields and
/// unknown `t` values are ignored (logged once by the caller).
struct JSONMessage {
    let raw: [String: Any]

    var t: String { raw["t"] as? String ?? "" }

    func string(_ key: String) -> String? { raw[key] as? String }

    func int(_ key: String) -> Int? {
        if let n = raw[key] as? NSNumber { return n.intValue }
        if let s = raw[key] as? String { return Int(s) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if let b = raw[key] as? Bool { return b }
        if let n = raw[key] as? NSNumber { return n.boolValue }
        return nil
    }

    func double(_ key: String) -> Double? {
        if let n = raw[key] as? NSNumber { return n.doubleValue }
        return nil
    }

    func object(_ key: String) -> [String: Any]? { raw[key] as? [String: Any] }
    func array(_ key: String) -> [[String: Any]]? { raw[key] as? [[String: Any]] }
    func strings(_ key: String) -> [String]? { raw[key] as? [String] }

    /// Base64 text decoded; `icon`'s `fg`/`bg`/`mono` layers arrive this way.
    func data(_ key: String) -> Data? {
        string(key).flatMap { Data(base64Encoded: $0) }
    }
}

enum JSONFrame {
    /// The JSON payload bytes (without the frame header).
    static func payload(_ object: [String: Any]) -> [UInt8] {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return [UInt8](data)
    }

    static func encode(_ object: [String: Any]) -> [UInt8] {
        Frame(type: .json, stream: 0, payload: payload(object)).encoded
    }

    static func decode(payload: [UInt8]) -> JSONMessage? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any] else { return nil }
        return JSONMessage(raw: obj)
    }
}
