// The replay buffer (docs/design/paths.md §8, PATH-4/10/15): ack release,
// duplicates, replay from the last ack, the 8 MiB frame and the 16/12 MiB
// budgets.

import XCTest
@testable import PocketDeck

final class ReplayBufferTests: XCTestCase {
    private func encodedFrame(seq: UInt64, bytes: Int, type: UInt8 = 0x01) -> (Frame, [UInt8]) {
        let inner = Frame(type: type, stream: 0, payload: [UInt8](repeating: UInt8(seq & 0xff), count: bytes))
        let frame = try! PathCodec.encodeReliable(seq: seq, inner: inner)
        return (frame, frame.encoded)
    }

    func testAckReleasesEverythingBelowIt() {
        var buffer = ReplayBuffer()
        for seq in 1...5 {
            let (_, bytes) = encodedFrame(seq: UInt64(seq), bytes: 10)
            XCTAssertTrue(buffer.canAdmit(bytes: bytes.count, bulk: false))
            try! buffer.append(seq: UInt64(seq), frame: bytes, bulk: false)
        }
        XCTAssertEqual(buffer.count, 5)
        XCTAssertEqual(buffer.ack(3), 2)
        // Each encoded frame is 22 bytes of wrapper plus its 10-byte payload.
        XCTAssertEqual(buffer.heldBytes, 3 * 32)
        XCTAssertEqual(buffer.unacked.map(\.seq), [3, 4, 5])
        // A repeated or lower ack releases nothing.
        XCTAssertEqual(buffer.ack(2), 0)
        XCTAssertEqual(buffer.ack(3), 0)
    }

    func testReplayFromTheLastAckAfterASwitch() {
        var buffer = ReplayBuffer()
        for seq in 1...4 {
            let (_, bytes) = encodedFrame(seq: UInt64(seq), bytes: 4)
            try! buffer.append(seq: UInt64(seq), frame: bytes, bulk: false)
        }
        _ = buffer.ack(2)
        XCTAssertEqual(buffer.unacked.map(\.seq), [2, 3, 4])
        // The replay is exactly the unacked frames, in order, byte for byte.
        let replay = buffer.unacked.map(\.frame)
        XCTAssertEqual(replay.count, 3)
        XCTAssertEqual(replay[0], encodedFrame(seq: 2, bytes: 4).1)
    }

    func testADuplicateSeqIsNotAppended() {
        var buffer = ReplayBuffer()
        let (_, bytes) = encodedFrame(seq: 1, bytes: 4)
        try! buffer.append(seq: 1, frame: bytes, bulk: false)
        XCTAssertThrowsError(try buffer.append(seq: 1, frame: bytes, bulk: false))
        XCTAssertEqual(buffer.count, 1)
    }

    func testAnEightMiBFrameFits() {
        var buffer = ReplayBuffer()
        let (_, bytes) = encodedFrame(seq: 1, bytes: PathCodec.maxInnerPayload)
        XCTAssertEqual(bytes.count, Int(maxFrameSize) + 4)
        XCTAssertTrue(buffer.canAdmit(bytes: bytes.count, bulk: false))
        try! buffer.append(seq: 1, frame: bytes, bulk: false)
        XCTAssertEqual(buffer.heldBytes, Int(maxFrameSize) + 4)
    }

    func testAFramePastTheCapIsNeverAdmitted() {
        var buffer = ReplayBuffer()
        XCTAssertFalse(buffer.canAdmit(bytes: Int(maxFrameSize) + 5, bulk: false))
        XCTAssertFalse(buffer.canAdmit(bytes: 17 << 20, bulk: false))
    }

    func testBulkStopsAtTwelveMiBAndLeavesFourForControl() {
        var buffer = ReplayBuffer()
        var seq: UInt64 = 1
        var bulkBytes = 0
        while true {
            let (_, bytes) = encodedFrame(seq: UInt64(seq), bytes: 1 << 20, type: 0x22)
            if !buffer.canAdmit(bytes: bytes.count, bulk: true) { break }
            try! buffer.append(seq: seq, frame: bytes, bulk: true)
            bulkBytes += bytes.count
            seq += 1
        }
        XCTAssertLessThanOrEqual(bulkBytes, ReplayBuffer.bulkCapacity)
        XCTAssertLessThan(ReplayBuffer.bulkCapacity - bulkBytes, 1 << 20, "the producer stopped at the cap, not early")
        XCTAssertGreaterThanOrEqual(ReplayBuffer.capacity - buffer.heldBytes, 4 << 20)
        // A KEY still goes out: control may use the free 4 MiB.
        let (_, key) = encodedFrame(seq: UInt64(seq), bytes: 16, type: 0x12)
        XCTAssertTrue(buffer.canAdmit(bytes: key.count, bulk: false))
        try! buffer.append(seq: seq, frame: key, bulk: false)
    }

    func testControlMayUseTheWholeBufferWithoutBulk() {
        var buffer = ReplayBuffer()
        var seq: UInt64 = 1
        while buffer.canAdmit(bytes: (1 << 20) + 22, bulk: false) {
            let (_, bytes) = encodedFrame(seq: UInt64(seq), bytes: 1 << 20)
            try! buffer.append(seq: seq, frame: bytes, bulk: false)
            seq += 1
        }
        XCTAssertGreaterThan(buffer.heldBytes, ReplayBuffer.bulkCapacity)
        XCTAssertLessThanOrEqual(buffer.heldBytes, ReplayBuffer.capacity)
    }

    func testAnAckAboveWhatWasSentIsAProtocolError() {
        var buffer = ReplayBuffer()
        try! buffer.append(seq: 1, frame: encodedFrame(seq: 1, bytes: 4).1, bulk: false)
        XCTAssertFalse(buffer.ackAboveSent(2))
        XCTAssertTrue(buffer.ackAboveSent(3))
    }
}
