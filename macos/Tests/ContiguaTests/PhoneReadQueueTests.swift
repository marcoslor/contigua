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

    /// MCP-9: a read queued past its caller's bound leaves the queue unsent
    /// and fails `timeout`.
    func testAQueuedReadTimesOutAtTheCallersBound_MCP9() async throws {
        let queue = PhoneReadQueue()
        let broker = UITreeBroker()
        var sent: [Int] = []
        let first = Task {
            try await queue.run(until: .now + .seconds(5)) {
                try await broker.read(stream: 3, timeout: 5) { sent.append($0) }
            }
        }
        await yieldALot()
        let started = ContinuousClock.now
        do {
            _ = try await queue.run(until: .now + .milliseconds(100)) {
                try await broker.read(stream: 3, timeout: 5) { sent.append($0) }
            }
            XCTFail("the queued read must time out")
        } catch {
            XCTAssertEqual(error as? UITreeError, .timedOut)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        XCTAssertEqual(sent, [1], "the timed-out read is never sent")
        broker.reply(reply(seq: 1))
        _ = try await first.value
    }

    /// MCP-9: a caller past its bound is answered `timeout` at its bound, but
    /// its request keeps the queue until the phone answers it, so the next
    /// request goes out only then and never meets the phone's `busy`.
    func testARequestPastItsCallersBoundKeepsTheQueueUntilThePhoneAnswers_MCP9() async throws {
        let queue = PhoneReadQueue()
        let broker = UITreeBroker()
        var sent: [Int] = []
        let started = ContinuousClock.now
        let first = Task {
            try await queue.run(until: .now + .milliseconds(100)) {
                try await broker.read(stream: 3, timeout: 5) { sent.append($0) }
            }
        }
        await yieldALot()
        let second = Task {
            try await queue.run(until: .now + .seconds(5)) {
                try await broker.read(stream: 3, timeout: 5) { sent.append($0) }
            }
        }
        do {
            _ = try await first.value
            XCTFail("the caller is answered at its bound")
        } catch {
            XCTAssertEqual(error as? UITreeError, .timedOut)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        await yieldALot()
        XCTAssertEqual(sent, [1], "the next request waits for the phone to answer the first")
        broker.reply(reply(seq: 1))  // the phone answers the read its caller gave up on
        await yieldALot()
        XCTAssertEqual(sent, [1, 2])
        broker.reply(reply(seq: 2))
        _ = try await second.value
    }

    func testTheSettleGraceIsThePhonesPlusThree_MCP9() {
        XCTAssertEqual(UISettleBroker.grace, 5.5)
    }

    // MARK: ui.type's own bound (#262 item 14)

    /// [MCP-109] The Mac waits for `ui.type` the read deadline plus 10 ms per
    /// code point: 25 s at the 2000 code-point limit.
    func testATextsBoundGrowsWithItsLength_MCP109() {
        XCTAssertEqual(UITypeBroker.bound(codePoints: 0), 5, accuracy: 0.0001)
        XCTAssertEqual(UITypeBroker.bound(codePoints: 300), 8, accuracy: 0.0001)
        XCTAssertEqual(UITypeBroker.bound(codePoints: 2000), 25, accuracy: 0.0001)
    }

    /// [MCP-109] The window's close ends a `ui.type` wait at once with
    /// `no_window`; another window's text keeps waiting.
    func testAWindowsCloseEndsItsTextsWait_MCP109() async throws {
        let broker = UITypeBroker()
        var sent: [Int] = []
        let closing = Task { try await broker.type(stream: 3, codePoints: 4) { sent.append($0) } }
        let other = Task { try await broker.type(stream: 4, codePoints: 4) { sent.append($0) } }
        await yieldALot()
        XCTAssertEqual(sent, [1, 2])
        broker.windowClosed(stream: 3)
        let reply = try await closing.value
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.code, "no_window")
        broker.reply(UITypeReply(seq: 2, stream: 4, ok: true, entry: "inserted", via: "keys", characters: 4))
        let typed = try await other.value
        XCTAssertTrue(typed.ok, "another window's text ended with the close")
    }

    /// [MCP-84] [MCP-109] `run(queuedUntil:)`: once sent, the caller waits for
    /// the request past that bound; still queued at it, it leaves unsent.
    func testATextsCallerWaitsForItOnceSent_MCP109() async throws {
        let queue = PhoneReadQueue()
        let broker = UITypeBroker()
        var sent: [Int] = []
        let first = Task {
            try await queue.run(queuedUntil: .now + .milliseconds(100)) {
                try await broker.type(stream: 3, codePoints: 4) { sent.append($0) }
            }
        }
        await yieldALot()
        let queued = Task {
            try await queue.run(queuedUntil: .now + .milliseconds(100)) {
                try await broker.type(stream: 3, codePoints: 4) { sent.append($0) }
            }
        }
        do {
            _ = try await queued.value
            XCTFail("a text still queued at its bound is sent")
        } catch {
            XCTAssertEqual(error as? UITreeError, .timedOut)
        }
        try await Task.sleep(for: .milliseconds(100))  // real-time: past the first's queue bound too
        XCTAssertEqual(sent, [1], "the queued text went out")
        broker.reply(UITypeReply(seq: 1, stream: 3, ok: true, entry: "inserted", via: "keys", characters: 4))
        let reply = try await first.value
        XCTAssertTrue(reply.ok, "the sent text's caller stopped waiting at its queue bound")
    }

}
