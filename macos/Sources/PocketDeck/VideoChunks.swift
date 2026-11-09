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

/// Reassembles one access unit per stream. Each stream is either idle or
/// holding one incomplete unit; a fragment that cannot belong to it (a
/// different pts/flags/count, or a duplicate index) throws the stub away.
/// Throwing a stub away is a break of the reference chain (WIN-62's
/// `incomplete`), so [Result.discardedIncomplete] travels back to the caller
/// instead of the unit vanishing silently. Memory is bounded by one 8 MiB unit
/// per stream.
struct VideoChunkAssembler {
    private struct Unit {
        var ptsUs: UInt64
        var flags: UInt8
        var count: Int
        var parts: [Int: [UInt8]]
        var bytes: Int
    }

    /// What one fragment did.
    struct Result: Equatable {
        /// An incomplete unit was thrown away instead of being decoded.
        var discardedIncomplete = false
        /// The access unit this fragment completed, if any.
        var frame: VideoFrameData?
    }

    private var units: [UInt32: Unit] = [:]

    /// Adds one fragment and reports both a completed unit and any stub it
    /// had to discard. A discarded stub and a completed unit can arrive
    /// together (the fragment of a new single-fragment unit).
    mutating func add(stream: UInt32, chunk: VideoChunkData) -> Result {
        let count = Int(chunk.count)
        var discarded = false
        if var unit = units[stream],
           unit.ptsUs == chunk.ptsUs, unit.flags == chunk.flags, unit.count == count {
            guard unit.parts[Int(chunk.index)] == nil else {
                // A duplicate index is a malformed payload: the unit it
                // belongs to can no longer be trusted.
                units[stream] = nil
                return Result(discardedIncomplete: true)
            }
            unit.parts[Int(chunk.index)] = chunk.data
            unit.bytes += chunk.data.count
            units[stream] = unit
        } else {
            discarded = units[stream] != nil
            units[stream] = Unit(ptsUs: chunk.ptsUs, flags: chunk.flags, count: count,
                                 parts: [Int(chunk.index): chunk.data],
                                 bytes: chunk.data.count)
        }
        guard let unit = units[stream], unit.parts.count == unit.count else {
            return Result(discardedIncomplete: discarded)
        }
        var annexB: [UInt8] = []
        annexB.reserveCapacity(unit.bytes)
        for index in 0..<unit.count {
            guard let part = unit.parts[index] else {
                return Result(discardedIncomplete: discarded)
            }
            annexB.append(contentsOf: part)
        }
        units[stream] = nil
        return Result(discardedIncomplete: discarded,
                      frame: VideoFrameData(ptsUs: unit.ptsUs, flags: unit.flags, annexB: annexB))
    }

    /// The stream ended: reports whether an incomplete unit was thrown away.
    @discardableResult
    mutating func forget(stream: UInt32) -> Bool {
        units.removeValue(forKey: stream) != nil
    }

    mutating func reset() {
        units.removeAll()
    }
}
