// The receive side's reorder window (docs/design/paths.md §5.3/§8,
// PATH-4/9/10): in-order delivery, a gap, duplicates, and a full window that
// stops the read instead of dropping.

import XCTest
@testable import PocketDeck

final class ReorderWindowTests: XCTestCase {
    private func frame(_ seq: UInt64, bytes: Int = 4) -> ReliableFrame {
        ReliableFrame(seq: seq,
                      inner: Frame(type: .json, stream: 0,
                                   payload: [UInt8](repeating: UInt8(truncatingIfNeeded: seq), count: bytes)))
    }

    func testInOrderFramesAreDeliveredAndTheAckAdvances() {
        var window = ReorderWindow()
        guard case .deliver(let first) = window.receive(frame(1)) else { return XCTFail() }
        XCTAssertEqual(first.map(\.seq), [1])
        XCTAssertEqual(window.ack, 2)
        guard case .deliver(let second) = window.receive(frame(2)) else { return XCTFail() }
        XCTAssertEqual(second.map(\.seq), [2])
        XCTAssertEqual(window.ack, 3)
    }

    func testAGapHoldsFramesUntilItFills() {
        var window = ReorderWindow()
        XCTAssertEqual(window.receive(frame(2)), .buffered)
        XCTAssertEqual(window.receive(frame(3)), .buffered)
        XCTAssertEqual(window.ack, 1, "the ack does not advance past a gap")
        XCTAssertEqual(window.bufferedCount, 2)
        guard case .deliver(let frames) = window.receive(frame(1)) else { return XCTFail() }
        XCTAssertEqual(frames.map(\.seq), [1, 2, 3])
        XCTAssertEqual(window.ack, 4)
        XCTAssertEqual(window.bufferedCount, 0)
    }

    func testADuplicateIsDroppedAndNeverDeliveredTwice() {
        var window = ReorderWindow()
        _ = window.receive(frame(1))
        XCTAssertEqual(window.receive(frame(1)), .duplicate)
        XCTAssertEqual(window.receive(frame(0)), .duplicate)
        XCTAssertEqual(window.receive(frame(3)), .buffered)
        XCTAssertEqual(window.receive(frame(3)), .duplicate)
        XCTAssertEqual(window.receive(frame(2)), .deliver([frame(2), frame(3)]))
    }

    func testSixtyFourBufferedFramesFitAndTheSixtyFifthIsFull() {
        var window = ReorderWindow()
        for seq in 2...65 { XCTAssertEqual(window.receive(frame(UInt64(seq))), .buffered) }
        XCTAssertEqual(window.bufferedCount, 64)
        XCTAssertEqual(window.receive(frame(66)), .full)
        XCTAssertEqual(window.bufferedCount, 64, "a full window never drops a buffered frame")
        guard case .deliver(let frames) = window.receive(frame(1)) else { return XCTFail() }
        XCTAssertEqual(frames.count, 65)
    }

    func testTheFourMiBByteWindowStopsTheReadToo() {
        var window = ReorderWindow()
        // 1 MiB payloads: four fit, the fifth does not.
        for seq in 2...5 {
            XCTAssertEqual(window.receive(frame(UInt64(seq), bytes: 1 << 20)), .buffered)
        }
        XCTAssertEqual(window.receive(frame(6, bytes: 1 << 20)), .full)
        XCTAssertEqual(window.bufferedBytes, 4 << 20)
    }

    func testResetForgetsTheWindowForANewSession() {
        var window = ReorderWindow()
        _ = window.receive(frame(2))
        window.reset()
        XCTAssertEqual(window.ack, 1)
        XCTAssertEqual(window.bufferedCount, 0)
    }
}
