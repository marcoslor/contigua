// Input calls on one window run one at a time, and the person's input during a
// call reaches its answer (MCP-84); the runner owns the deadline (MCP-8).

import XCTest
@testable import Contigua

/// A window and phone the runner drives: it records what was sent, and holds
/// each settle until the test releases it.
@MainActor
final class FakeActEnvironment: MCPActEnvironment {
    var log: [String]
    let name: String
    var condition: MCPActMachine.Condition = .live
    var refusalCode: String?
    var settleGate: CheckedContinuation<Void, Never>?
    var holdSettle = false
    var settleNeverAnswers = false
    var settleStarted: (() -> Void)?

    init(name: String, log: [String] = []) {
        self.name = name
        self.log = log
    }

    func windowCondition() -> MCPActMachine.Condition { condition }
    func refusal() -> String? { refusalCode }
    func sendInput() async { log.append("\(name).input") }
    func sendPress() async -> MCPActMachine.Event { .pressOK }
    func sendType() async -> MCPActMachine.Event { .typeOK(entry: "inserted", via: "keys") }

    func settle(quietMs: Int, timeoutMs: Int) async -> MCPSettleResult {
        log.append("\(name).settle")
        settleStarted?()
        if settleNeverAnswers {
            try? await Task.sleep(for: .seconds(30))
            return .failed("timeout")
        }
        if holdSettle {
            await withCheckedContinuation { settleGate = $0 }
        }
        return .reply(settled: true, waitedMs: 300, reason: nil)
    }

    func readTree() async -> MCPTreeResult { .ok("{}") }

    func release() {
        settleGate?.resume()
        settleGate = nil
    }
}

/// Records every environment's steps in one order.
@MainActor
final class SharedLog {
    var lines: [String] = []
}

@MainActor
final class WindowActQueueTests: XCTestCase {

    private func untilTrue(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 where !condition() {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func testCallsOnOneWindowRunInOrder_MCP84() async {
        let queue = WindowActQueue()
        let a = FakeActEnvironment(name: "A")
        let b = FakeActEnvironment(name: "B")
        a.holdSettle = true
        let first = Task {
            await MCPActRunner.run(MCPActMachine(path: .input, wait: .settle, observe: .none),
                                   window: 3, queue: queue, deadline: .seconds(5), env: a)
        }
        await untilTrue { a.settleGate != nil }
        let second = Task {
            await MCPActRunner.run(MCPActMachine(path: .input, wait: .settle, observe: .none),
                                   window: 3, queue: queue, deadline: .seconds(5), env: b)
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(b.log, [], "B must not send while A's call runs")
        a.release()
        _ = await first.value
        _ = await second.value
        XCTAssertEqual(a.log, ["A.input", "A.settle"])
        XCTAssertEqual(b.log, ["B.input", "B.settle"])
    }

    func testAnotherWindowDoesNotWait_MCP84() async {
        let queue = WindowActQueue()
        let a = FakeActEnvironment(name: "A")
        let b = FakeActEnvironment(name: "B")
        a.holdSettle = true
        let first = Task {
            await MCPActRunner.run(MCPActMachine(path: .input, wait: .settle, observe: .none),
                                   window: 3, queue: queue, deadline: .seconds(5), env: a)
        }
        await untilTrue { a.settleGate != nil }
        let outcome = await MCPActRunner.run(MCPActMachine(path: .input, wait: .settle, observe: .none),
                                             window: 4, queue: queue, deadline: .seconds(5), env: b)
        XCTAssertEqual(outcome, .answer(MCPActMachine.Answer(
            settle: MCPActMachine.Settle(state: "settled", waitedMs: 300))))
        a.release()
        _ = await first.value
    }

    func testThePersonsInputDuringASettleIsReported_MCP84() async {
        let queue = WindowActQueue()
        let a = FakeActEnvironment(name: "A")
        a.holdSettle = true
        let call = Task {
            await MCPActRunner.run(MCPActMachine(path: .input, wait: .settle, observe: .none),
                                   window: 3, queue: queue, deadline: .seconds(5), env: a)
        }
        await untilTrue { a.settleGate != nil }
        queue.report(window: 3, source: "person")
        queue.report(window: 4, source: "person")  // another window's input is not this call's
        a.release()
        let outcome = await call.value
        XCTAssertEqual(outcome, .answer(MCPActMachine.Answer(
            settle: MCPActMachine.Settle(state: "settled", waitedMs: 300), alsoActed: ["person"])))
    }

    func testInputBeforeTheCallIsNotReported_MCP84() async {
        let queue = WindowActQueue()
        queue.report(window: 3, source: "person")
        let outcome = await MCPActRunner.run(MCPActMachine(path: .input, wait: .settle, observe: .none),
                                             window: 3, queue: queue, deadline: .seconds(5),
                                             env: FakeActEnvironment(name: "A"))
        XCTAssertEqual(outcome, .answer(MCPActMachine.Answer(
            settle: MCPActMachine.Settle(state: "settled", waitedMs: 300))))
    }

    func testTheDeadlineAnswersStillChanging_MCP8() async {
        let queue = WindowActQueue()
        let a = FakeActEnvironment(name: "A")
        a.settleNeverAnswers = true
        let started = Date()
        let outcome = await MCPActRunner.run(MCPActMachine(path: .input, wait: .settle, observe: .none),
                                             window: 3, queue: queue, deadline: .milliseconds(200), env: a)
        guard case .answer(let answer) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(answer.settle.state, "still_changing")
        XCTAssertEqual(answer.settle.reason, "changes")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        // The window's queue moves on after a call the deadline ended.
        let b = FakeActEnvironment(name: "B")
        _ = await MCPActRunner.run(MCPActMachine(path: .input, wait: .none, observe: .none),
                                   window: 3, queue: queue, deadline: .seconds(1), env: b)
        XCTAssertEqual(b.log, ["B.input"])
    }

    func testARefusedRefSendsNothing_MCP108() async {
        let a = FakeActEnvironment(name: "A")
        a.refusalCode = "stale_ref"
        let outcome = await MCPActRunner.run(MCPActMachine(path: .input, wait: .settle, observe: .tree),
                                             window: 3, queue: WindowActQueue(), deadline: .seconds(5),
                                             env: a, ref: true)
        XCTAssertEqual(outcome, .fail("stale_ref"))
        XCTAssertEqual(a.log, [])
    }

    func testAWindowNotLiveSendsNothing_MCP85() async {
        let a = FakeActEnvironment(name: "A")
        a.condition = .notReady
        let outcome = await MCPActRunner.run(MCPActMachine(path: .input, wait: .settle, observe: .tree),
                                             window: 3, queue: WindowActQueue(), deadline: .seconds(5), env: a)
        XCTAssertEqual(outcome, .fail("not_ready"))
        XCTAssertEqual(a.log, [])
    }
}
