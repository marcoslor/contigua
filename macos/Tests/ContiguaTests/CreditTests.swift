// Credit, never a drop (docs/design/paths.md §8, PATH-10/15): a bulk producer
// pauses at its budget and resumes on the ack that frees it; a 200 MiB
// transfer across a 10 s orphan completes byte-exact with ≤ 16 MiB held.

import CryptoKit
import XCTest
@testable import Contigua

final class CreditTests: XCTestCase {
    /// One MiB chunks with deterministic contents; `offset` is the producer's
    /// file position (a paused producer holds only this and a descriptor).
    private struct Producer {
        static let chunk = 1 << 20
        var offset = 0
        let total: Int

        mutating func next() -> [UInt8]? {
            guard offset < total else { return nil }
            let count = min(Self.chunk, total - offset)
            let bytes = (0..<count).map { UInt8(truncatingIfNeeded: (offset + $0) &* 31 &+ 7) }
            offset += count
            return bytes
        }
    }

    func testABulkProducerStopsAtTwelveMiBAndResumesOnTheAck() {
        var buffer = ReplayBuffer()
        var producer = Producer(total: 40 << 20)
        var seq: UInt64 = 1
        var waits = 0
        var maxBulk = 0
        while producer.offset < producer.total {
            // Ask before reading: the frame that would not fit is never created.
            guard buffer.canAdmit(bytes: Producer.chunk + 64, bulk: true) else {
                waits += 1
                XCTAssertLessThanOrEqual(buffer.bulkBytes, ReplayBuffer.bulkCapacity)
                _ = buffer.ack(buffer.lastSeq - 3)
                continue
            }
            let chunk = producer.next()!
            let bytes = try! PathCodec.encodeReliable(
                seq: seq, inner: Frame(type: 0x22, stream: 1, payload: chunk)).encoded
            try! buffer.append(seq: seq, frame: bytes, bulk: true)
            maxBulk = max(maxBulk, buffer.bulkBytes)
            seq += 1
        }
        XCTAssertGreaterThan(waits, 0, "the producer waited at least once")
        XCTAssertLessThanOrEqual(maxBulk, ReplayBuffer.bulkCapacity)
    }

    func testAControlFrameGoesOutWhenBulkHoldsItsWholeBudget() {
        var buffer = ReplayBuffer()
        var seq: UInt64 = 1
        while buffer.canAdmit(bytes: Producer.chunk + 64, bulk: true) {
            let bytes = try! PathCodec.encodeReliable(
                seq: seq, inner: Frame(type: 0x21, stream: 1,
                                       payload: [UInt8](repeating: 0xab, count: Producer.chunk))).encoded
            try! buffer.append(seq: seq, frame: bytes, bulk: true)
            seq += 1
        }
        let key = try! PathCodec.encodeReliable(
            seq: seq, inner: Frame(type: 0x12, stream: 0,
                                   payload: [0, 0, 0, 0, 0, 0, 0, 0, 0])).encoded
        XCTAssertTrue(buffer.canAdmit(bytes: key.count, bulk: false))
        try! buffer.append(seq: seq, frame: key, bulk: false)
        XCTAssertGreaterThan(buffer.bulkBytes, 0)
    }

    /// A 200 MiB file (1 MiB frames) with the path silent for ten ack rounds:
    /// the producer pauses while the peer is silent, the ack frees room, and
    /// every delivered payload matches its source. Held bytes never pass 16 MiB.
    func testATwoHundredMiBTransferAcrossAnOrphanIsByteExact() {
        var buffer = ReplayBuffer()
        var producer = Producer(total: 200 << 20)
        var seq: UInt64 = 1
        var maxHeld = 0
        var orphanRounds = 0
        var silentPolls = 0
        var delivered = 0
        var sourceHash = SHA256()
        var deliveredHash = SHA256()
        var sawSilence = false
        var outageDone = false
        var outage = false

        while delivered < 200 << 20 {
            let room = buffer.canAdmit(bytes: Producer.chunk + 64, bulk: true)
            if room, let chunk = producer.next() {
                let bytes = try! PathCodec.encodeReliable(
                    seq: seq, inner: Frame(type: 0x22, stream: 1, payload: chunk)).encoded
                try! buffer.append(seq: seq, frame: bytes, bulk: true)
                seq += 1
                maxHeld = max(maxHeld, buffer.heldBytes)
                sourceHash.update(data: Data(chunk))
                // Mid-transfer the radio goes silent for ten ack rounds: no ack
                // leaves the path, so the producer runs out of credit and waits.
                if !outageDone && delivered >= 20 << 20 && !outage {
                    outage = true
                    sawSilence = true
                }
                if !outage {
                    buffer.ack(buffer.lastSeq + 1)
                    deliveredHash.update(data: Data(chunk))
                    delivered += chunk.count
                }
            } else if !buffer.isEmpty {
                // No credit: the path is black-holed and the buffer is at its
                // cap. What the producer already created waits for the ack.
                outage = true
                sawSilence = true
                silentPolls += 1
                if silentPolls > 10 {
                    silentPolls = 0
                    orphanRounds += 1
                    outageDone = true
                    outage = false
                    // The path returns: replay from the peer's last ack.
                    for entry in buffer.unacked {
                        let stream = UInt32(entry.frame[5]) << 24 | UInt32(entry.frame[6]) << 16
                            | UInt32(entry.frame[7]) << 8 | UInt32(entry.frame[8])
                        let inner = try! PathCodec.decodeReliable(
                            Frame(type: 0x30, stream: stream, payload: Array(entry.frame[9...])))
                        deliveredHash.update(data: Data(inner.inner.payload))
                        delivered += inner.inner.payload.count
                    }
                    buffer.ack(buffer.lastSeq + 1)
                }
            } else {
                break
            }
        }
        XCTAssertTrue(sawSilence)
        XCTAssertGreaterThan(orphanRounds, 0)
        XCTAssertEqual(delivered, 200 << 20)
        XCTAssertEqual(sourceHash.finalize(), deliveredHash.finalize())
        XCTAssertLessThanOrEqual(maxHeld, ReplayBuffer.capacity)
        XCTAssertGreaterThan(maxHeld, ReplayBuffer.bulkCapacity - (2 << 20), "the 12 MiB cap was reached")
    }
}
