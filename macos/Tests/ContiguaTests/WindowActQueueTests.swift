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
    var inputMs = 0
    var inputEnded: ContinuousClock.Instant?
    var settleStartedAt: ContinuousClock.Instant?

    init(name: String, log: [String] = []) {
        self.name = name
        self.log = log
    }

    func windowCondition() -> MCPActMachine.Condition { condition }
    func refusal() -> String? { refusalCode }
    func sendInput() async {
        log.append("\(name).input")
        if inputMs > 0 { try? await Task.sleep(for: .milliseconds(inputMs)) } // real-time: an input that takes a while to send
        inputEnded = .now
    }
    func sendPress() async -> MCPActMachine.Event { .pressOK }
    func sendType() async -> MCPActMachine.Event { .typeOK(entry: "inserted", via: "keys") }

    func settle(quietMs: Int, timeoutMs: Int, until: ContinuousClock.Instant) async -> MCPSettleResult {
        log.append("\(name).settle")
        settleStartedAt = .now
        settleStarted?()
        if settleNeverAnswers {
            try? await Task.sleep(for: .seconds(30)) // real-time: a phone that never answers; the deadline ends the call
            return .failed("timeout")
        }
        if holdSettle {
            await withCheckedContinuation { settleGate = $0 }
        }
        return .reply(settled: true, waitedMs: 300, reason: nil)
    }

    func readTree(until: ContinuousClock.Instant) async -> MCPTreeResult { .ok("{}") }

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
            try? await Task.sleep(for: .milliseconds(2)) // real-time: let the runner reach its held settle
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

    // MARK: Review fixes (T5)

    /// MCP-84: A's deadline ends its call while its input is still going out;
    /// B's input waits until A's has finished.
    func testTheNextCallWaitsForAnInputInFlight_MCP84() async {
        let queue = WindowActQueue()
        let a = FakeActEnvironment(name: "A")
        a.inputMs = 300
        let b = FakeActEnvironment(name: "B")
        let first = Task {
            await MCPActRunner.run(MCPActMachine(path: .input, wait: .settle, observe: .none),
                                   window: 3, queue: queue, deadline: .milliseconds(100), env: a)
        }
        await untilTrue { !a.log.isEmpty }
        let second = Task {
            await MCPActRunner.run(MCPActMachine(path: .input, wait: .none, observe: .none),
                                   window: 3, queue: queue, deadline: .seconds(5), env: b)
        }
        let outcome = await first.value
        XCTAssertEqual(outcome, .answer(MCPActMachine.Answer(
            settle: MCPActMachine.Settle(state: "not_waited", reason: "deadline"))))
        _ = await second.value
        XCTAssertEqual(b.log, ["B.input"])
        let aEnded = try? XCTUnwrap(a.inputEnded)
        let bEnded = try? XCTUnwrap(b.inputEnded)
        if let aEnded, let bEnded { XCTAssertLessThan(aEnded, bEnded) }
        XCTAssertEqual(a.log, ["A.input"], "A never settles after its deadline")
    }

    /// MCP-8: `waitedMs` counts from the settle's send, not from the call's start.
    func testTheDeadlineCountsOnlyTheSettlesWait_MCP8() async {
        let a = FakeActEnvironment(name: "A")
        a.inputMs = 150
        a.settleNeverAnswers = true
        let outcome = await MCPActRunner.run(MCPActMachine(path: .input, wait: .settle, observe: .none),
                                             window: 3, queue: WindowActQueue(),
                                             deadline: .milliseconds(300), env: a)
        guard case .answer(let answer) = outcome, let waited = answer.settle.waitedMs else {
            return XCTFail("\(outcome)")
        }
        XCTAssertEqual(answer.settle.reason, "deadline")
        XCTAssertLessThan(waited, 250, "the 150 ms of input is not the settle's wait")
    }

    /// MCP-84: a connection that closes takes its queued calls with it:
    /// nothing is sent for them.
    func testAClientThatLeftSendsNothing_MCP84() async {
        let queue = WindowActQueue()
        let a = FakeActEnvironment(name: "A")
        a.holdSettle = true
        let b = FakeActEnvironment(name: "B")
        let first = Task {
            await MCPActRunner.run(MCPActMachine(path: .input, wait: .settle, observe: .none),
                                   window: 3, queue: queue, deadline: .seconds(5), env: a,
                                   client: MCPClientID(1))
        }
        await untilTrue { a.settleGate != nil }
        let second = Task {
            await MCPActRunner.run(MCPActMachine(path: .input, wait: .settle, observe: .none),
                                   window: 3, queue: queue, deadline: .seconds(5), env: b,
                                   client: MCPClientID(2))
        }
        for _ in 0..<20 { await Task.yield() }
        queue.clientGone(MCPClientID(2))
        XCTAssertEqual(await second.value, .fail("cancelled"))
        a.release()
        _ = await first.value
        XCTAssertEqual(b.log, [])
    }

    /// MCP-84: another MCP client's input on the window is `another_agent`;
    /// the holder's own is not reported.
    func testAnotherAgentsInputIsReported_MCP84() async {
        let queue = WindowActQueue()
        let a = FakeActEnvironment(name: "A")
        a.holdSettle = true
        let call = Task {
            await MCPActRunner.run(MCPActMachine(path: .input, wait: .settle, observe: .none),
                                   window: 3, queue: queue, deadline: .seconds(5), env: a,
                                   client: MCPClientID(1))
        }
        await untilTrue { a.settleGate != nil }
        queue.agentInput(window: 3, client: MCPClientID(1))
        queue.agentInput(window: 3, client: MCPClientID(2))
        a.release()
        XCTAssertEqual(await call.value, .answer(MCPActMachine.Answer(
            settle: MCPActMachine.Settle(state: "settled", waitedMs: 300), alsoActed: ["another_agent"])))
    }

    /// MCP-84: input_probe holds the window's turn like an input call.
    func testAProbeWaitsForTheWindowsTurn_MCP84() async {
        let queue = WindowActQueue()
        let a = FakeActEnvironment(name: "A")
        a.holdSettle = true
        let first = Task {
            await MCPActRunner.run(MCPActMachine(path: .input, wait: .settle, observe: .none),
                                   window: 3, queue: queue, deadline: .seconds(5), env: a)
        }
        await untilTrue { a.settleGate != nil }
        var probed = false
        let probe = Task { await queue.exclusive(window: 3, client: nil) { probed = true } }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(probed)
        a.release()
        _ = await first.value
        _ = await probe.value
        XCTAssertTrue(probed)
    }
}
