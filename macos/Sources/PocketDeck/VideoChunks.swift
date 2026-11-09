// VIDEO_CHUNK: one fragment of a video access unit, so the phone's writer can
// put audio between fragments of a large frame (R4). The Mac reassembles one
// unit per stream and hands the decoder the same VideoFrameData it always got.

import Foundation

/// VIDEO_CHUNK: u64 ptsUs · u8 flags (bit0 keyframe) · u16 index · u16 count ·
/// one fragment of the Annex-B access unit.
struct VideoChunkData: Equatable {
    /// The phone never sends a fragment larger than this (R4's chunk size).
    static let maxBytes = 16 * 1024
    /// 8 MiB / 16 KiB = 512, the most fragments one access unit can have.
    static let maxChunks = 512

    var ptsUs: UInt64
    var flags: UInt8
    var index: UInt16
    var count: UInt16
    var data: [UInt8]

    init(ptsUs: UInt64, flags: UInt8, index: UInt16, count: UInt16, data: [UInt8]) {
        self.ptsUs = ptsUs
        self.flags = flags
        self.index = index
        self.count = count
        self.data = data
    }

    init(payload: [UInt8]) throws {
        var r = ByteReader(payload)
        ptsUs = try r.u64()
        flags = try r.u8()
        index = try r.u16()
        count = try r.u16()
        data = r.rest()
        guard count >= 1, count <= UInt16(Self.maxChunks), index < count,
              data.count <= Self.maxBytes else {
            throw ProtocolError.truncated
        }
    }
}

/// Reassembles one access unit per stream. A fragment for a different
/// (ptsUs, flags) discards the incomplete unit, so a dropped fragment costs
/// one frame and the next keyframe restarts cleanly. Memory is bounded by one
/// 8 MiB unit per stream.
struct VideoChunkAssembler {
    private struct Unit {
        var ptsUs: UInt64
        var flags: UInt8
        var count: Int
        var parts: [Int: [UInt8]]
        var bytes: Int
    }

    private var units: [UInt32: Unit] = [:]

    /// Adds one fragment; returns the whole access unit when it is complete.
    mutating func add(stream: UInt32, chunk: VideoChunkData) -> VideoFrameData? {
        let count = Int(chunk.count)
        if var unit = units[stream],
           unit.ptsUs == chunk.ptsUs, unit.flags == chunk.flags, unit.count == count {
            guard unit.parts[Int(chunk.index)] == nil else { return nil }
            unit.parts[Int(chunk.index)] = chunk.data
            unit.bytes += chunk.data.count
            units[stream] = unit
        } else {
            units[stream] = Unit(ptsUs: chunk.ptsUs, flags: chunk.flags, count: count,
                                 parts: [Int(chunk.index): chunk.data],
                                 bytes: chunk.data.count)
        }
        guard let unit = units[stream], unit.parts.count == unit.count else { return nil }
        var annexB: [UInt8] = []
        annexB.reserveCapacity(unit.bytes)
        for index in 0..<unit.count {
            guard let part = unit.parts[index] else { return nil }
            annexB.append(contentsOf: part)
        }
        units[stream] = nil
        return VideoFrameData(ptsUs: unit.ptsUs, flags: unit.flags, annexB: annexB)
    }

    mutating func forget(stream: UInt32) {
        units[stream] = nil
    }

    mutating func reset() {
        units.removeAll()
    }
}
