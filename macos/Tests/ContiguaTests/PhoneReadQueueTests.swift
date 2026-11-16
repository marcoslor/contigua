// One `ui.*` request at a time per phone, in arrival order across clients
// (MCP-9): the phone never sees a second request while one runs, so no client
// sees its `busy`.

import XCTest
@testable import Contigua

@MainActor
final class PhoneReadQueueTests: XCTestCase {

    private func reply(seq: Int, stream: UInt32 = 3) -> UITree {
        UITree(seq: seq, stream: stream, ok: true, code: nil, message: nil, displayId: 47,
               snapshot: nil, size: [1080, 2400], truncated: false, layers: [], nodes: [], note: nil)
    }

    private func settled(seq: Int) -> UISettleReply {
        UISettleReply(seq: seq, stream: 3, ok: true, settled: true, waitedMs: 300, events: 0,
                      reason: nil, code: nil)
    }

    private func yieldALot() async {
        for _ in 0..<50 { await Task.yield() }
    }

    func testTwoClientsReadsAreSerialised_MCP9() async throws {
        let queue = PhoneReadQueue()
        let broker = UITreeBroker()
        var sent: [Int] = []
        let first = Task {
            try await queue.run { try await broker.read(stream: 3, timeout: 5) { sent.append($0) } }
        }
        let second = Task {
            try await queue.run { try await broker.read(stream: 3, timeout: 5) { sent.append($0) } }
        }
        await yieldALot()
        XCTAssertEqual(sent, [1], "one ui.tree at a time")
        broker.reply(reply(seq: 1))
        await yieldALot()
        XCTAssertEqual(sent, [1, 2], "the second read is sent after the first reply")
        broker.reply(reply(seq: 2))
        let a = try await first.value
        let b = try await second.value
        XCTAssertTrue(a.ok)
        XCTAssertTrue(b.ok)
    }

    func testASettleAndATreeShareTheQueue_MCP9() async throws {
        let queue = PhoneReadQueue()
        let trees = UITreeBroker()
        let settles = UISettleBroker()
        var sent: [String] = []
        let settle = Task {
            try await queue.run {
                try await settles.settle(stream: 3, quietMs: 300, timeoutMs: 2000, grace: 5) {
                    sent.append("settle\($0)")
                }
            }
        }
        let tree = Task {
            try await queue.run { try await trees.read(stream: 3, timeout: 5) { sent.append("tree\($0)") } }
        }
        await yieldALot()
        XCTAssertEqual(sent, ["settle1"])
        settles.reply(settled(seq: 1))
        await yieldALot()
        XCTAssertEqual(sent, ["settle1", "tree1"])
        trees.reply(reply(seq: 1))
        let answer = try await settle.value
        XCTAssertTrue(answer.settled)
        _ = try await tree.value
    }

    func testALateSettleReplyIsIgnored_MCP9() async throws {
        let settles = UISettleBroker()
        do {
            _ = try await settles.settle(stream: 3, quietMs: 300, timeoutMs: 2000, grace: 0.05) { _ in }
            XCTFail("a silent phone must time out")
        } catch {
            XCTAssertEqual(error as? UITreeError, .timedOut)
        }
        settles.reply(settled(seq: 1))  // no waiter: ignored, no crash
    }

    func testAnEndedSessionFailsTheQueuedRequests_MCP9() async {
        let queue = PhoneReadQueue()
        let broker = UITreeBroker()
        var sent: [Int] = []
        let first = Task {
            try await queue.run { try await broker.read(stream: 3, timeout: 5) { sent.append($0) } }
        }
        let second = Task {
            try await queue.run { try await broker.read(stream: 3, timeout: 5) { sent.append($0) } }
        }
        await yieldALot()
        queue.fail(UITreeError.notConnected)
        broker.fail(.notConnected)
        let a = await first.result
        let b = await second.result
        XCTAssertThrowsError(try a.get())
        XCTAssertThrowsError(try b.get())
        XCTAssertEqual(sent, [1], "a request queued behind an ended session is never sent")
    }

    func testTheSettleReplyParses_MCP81() throws {
        let raw: [String: Any] = ["t": "ui.settle", "stream": 3, "seq": 7, "ok": true,
                                  "settled": false, "waitedMs": 2000, "events": 4, "reason": "loading"]
        let reply = try XCTUnwrap(UISettleReply(message: JSONMessage(raw: raw)))
        XCTAssertEqual(reply, UISettleReply(seq: 7, stream: 3, ok: true, settled: false, waitedMs: 2000,
                                            events: 4, reason: "loading", code: nil))
        let failed = try XCTUnwrap(UISettleReply(message: JSONMessage(raw: [
            "t": "ui.settle", "stream": 3, "seq": 8, "ok": false, "code": "not_available"])))
        XCTAssertEqual(failed.code, "not_available")
        XCTAssertFalse(failed.ok)
    }
}
