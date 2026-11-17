// `wait` (plan T11): a clock, text that appears or goes, and the settle, run
// against an injected clock, tree reads and settle replies (MCP-96, MCP-97,
// MCP-111).

import XCTest
@testable import Contigua

@MainActor
final class MCPWaitTests: XCTestCase {

    /// A virtual clock: sleeping moves it, a settle moves it by its wait.
    final class FakeWait: MCPWaitEnvironment {
        var now = 0
        var trees: [[String: Any]] = []
        var reads: [Int] = []
        var readUntil: [Int] = []
        var settles: [(quietMs: Int, timeoutMs: Int)] = []
        var settleReply: MCPSettleResult = .reply(settled: true, waitedMs: 0, reason: nil)
        /// Settle replies in order (the last repeats); empty: `settleReply`.
        var settleReplies: [MCPSettleResult] = []
        /// Read answers in order (the last repeats); empty: `trees`.
        var readScript: [MCPWaitRead] = []

        func nowMs() -> Int { now }
        func pause(untilMs: Int) async { now = max(now, untilMs) }
        func readTree(untilMs: Int) async -> MCPWaitRead {
            reads.append(now)
            readUntil.append(untilMs)
            if !readScript.isEmpty { return readScript[min(reads.count - 1, readScript.count - 1)] }
            let index = min(reads.count - 1, trees.count - 1)
            return index >= 0 ? .tree(trees[index]) : .failed("failed")
        }
        func settle(quietMs: Int, timeoutMs: Int, untilMs: Int) async -> MCPSettleResult {
            settles.append((quietMs, timeoutMs))
            let reply = settleReplies.isEmpty ? settleReply
                : settleReplies[min(settles.count - 1, settleReplies.count - 1)]
            if case .reply(_, let waited, _) = reply { now += waited }
            return reply
        }
    }

    private func tree(_ texts: [(ref: String, text: String)]) -> [String: Any] {
        ["window": 3, "nodes": texts.map { ["ref": $0.ref, "role": "TextView", "text": $0.text] }]
    }

    private func answer(_ outcome: MCPWaitOutcome) throws -> MCPWaitAnswer {
        guard case .answer(let answer) = outcome else {
            XCTFail("expected an answer, got \(outcome)")
            throw XCTSkip("no answer")
        }
        return answer
    }

    // [MCP-96]
    func testAPlainWaitReturnsAfterMs() async throws {
        let env = FakeWait()
        env.trees = [tree([("e1", "Hello")])]
        let result = try answer(await MCPWaitRunner.run(.clock(ms: 5000), timeoutMs: 10000,
                                                        observe: .tree, env: env))
        XCTAssertEqual(env.now, 5000)
        XCTAssertEqual(result.waitedMs, 5000)
        XCTAssertNil(result.until)
        XCTAssertNil(result.match)
        // The observe read comes after the clock, once.
        XCTAssertEqual(env.reads, [5000])
        XCTAssertNotNil(result.tree)
    }

    // [MCP-97]
    func testWaitForTextPollsAtMostTwiceASecond() async throws {
        let env = FakeWait()
        env.trees = [tree([("e1", "00:03")]), tree([("e1", "00:04")]), tree([("e9", "00:05.1")])]
        let result = try answer(await MCPWaitRunner.run(.text("00:05", gone: false), timeoutMs: 10000,
                                                        observe: .tree, env: env))
        XCTAssertEqual(env.reads, [0, 500, 1000])
        for (a, b) in zip(env.reads, env.reads.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, 500) }
        XCTAssertEqual(result.until, "met")
        XCTAssertEqual(result.match?["ref"] as? String, "e9")
        XCTAssertEqual(result.waitedMs, 1000)
    }

    // [MCP-97]
    func testGoneWaitsForDisappearance() async throws {
        let env = FakeWait()
        env.trees = [tree([("e1", "Loading…")]), tree([("e1", "Loading…")]), tree([("e2", "Done")])]
        let result = try answer(await MCPWaitRunner.run(.text("Loading", gone: true), timeoutMs: 10000,
                                                        observe: .tree, env: env))
        XCTAssertEqual(env.reads, [0, 500, 1000])
        XCTAssertEqual(result.until, "met")
        XCTAssertNil(result.match)
    }

    // [MCP-97]
    func testTimeoutIsNotAnError() async throws {
        let env = FakeWait()
        env.trees = [tree([("e1", "Nope")])]
        let result = try answer(await MCPWaitRunner.run(.text("Continue", gone: false), timeoutMs: 1500,
                                                        observe: .tree, env: env))
        XCTAssertEqual(result.until, "timeout")
        XCTAssertEqual(result.waitedMs, 1500)
        XCTAssertNil(result.match)
        XCTAssertTrue(env.reads.allSatisfy { $0 <= 1500 }, "\(env.reads)")
        let body = MCPDispatcher.resultBody(.answer(result.object(window: 3)))
        XCTAssertEqual(body["isError"] as? Bool, false)
    }

    // [MCP-111]
    func testWaitUntilSettledAnswersWhenTheDisplaySettles() async throws {
        let env = FakeWait()
        env.trees = [tree([("e1", "Hello")])]
        env.settleReply = .reply(settled: true, waitedMs: 900, reason: nil)
        let result = try answer(await MCPWaitRunner.run(.settle, timeoutMs: 10000, observe: .tree, env: env))
        XCTAssertEqual(env.settles.map(\.quietMs), [MCPActMachine.quietMs])
        XCTAssertEqual(env.settles.map(\.timeoutMs), [10000])
        XCTAssertEqual(result.until, "met")
        XCTAssertEqual(result.waitedMs, 900)
        XCTAssertNil(result.reason)
        XCTAssertNotNil(result.tree)
    }

    // [MCP-111]
    func testWaitUntilSettledTimesOutWithItsReason() async throws {
        let env = FakeWait()
        env.trees = [tree([("e1", "Hello")])]
        env.settleReply = .reply(settled: false, waitedMs: 2000, reason: "loading")
        let result = try answer(await MCPWaitRunner.run(.settle, timeoutMs: 2000, observe: .tree, env: env))
        XCTAssertEqual(env.settles.map(\.timeoutMs), [2000])
        XCTAssertEqual(result.until, "timeout")
        XCTAssertEqual(result.reason, "loading")
        let body = MCPDispatcher.resultBody(.answer(result.object(window: 3)))
        XCTAssertEqual(body["isError"] as? Bool, false)
    }

    // [MCP-8] every read is bound to the call's deadline: timeoutMs + 3 s.
    func testEveryReadCarriesTheCallsBound_MCP8() async throws {
        let env = FakeWait()
        env.trees = [tree([("e1", "Nope")])]
        _ = await MCPWaitRunner.run(.text("Continue", gone: false), timeoutMs: 1500, observe: .none, env: env)
        XCTAssertFalse(env.readUntil.isEmpty)
        XCTAssertTrue(env.readUntil.allSatisfy { $0 == 1500 + 3000 }, "\(env.readUntil)")
        XCTAssertEqual(MCPWaitRunner.boundMs(.clock(ms: 5000), timeoutMs: 10000), 8000)
    }

    // [MCP-111]
    func testASettleLongerThanTheWireCapIsSeveralSettles() async throws {
        let env = FakeWait()
        env.trees = [tree([("e1", "Hello")])]
        env.settleReplies = [.reply(settled: false, waitedMs: 10000, reason: "changes"),
                             .reply(settled: true, waitedMs: 1200, reason: nil)]
        let result = try answer(await MCPWaitRunner.run(.settle, timeoutMs: 30000, observe: .tree, env: env))
        XCTAssertEqual(env.settles.map(\.timeoutMs), [10000, 10000])
        XCTAssertEqual(result.until, "met")
        XCTAssertEqual(result.waitedMs, 11200)
        XCTAssertNil(result.reason)
    }

    // [MCP-111]
    func testAChainedSettleTimesOutWithTheLastReason() async throws {
        let env = FakeWait()
        env.trees = [tree([("e1", "Hello")])]
        env.settleReplies = [.reply(settled: false, waitedMs: 10000, reason: "changes"),
                             .reply(settled: false, waitedMs: 10000, reason: "changes"),
                             .reply(settled: false, waitedMs: 5000, reason: "loading")]
        let result = try answer(await MCPWaitRunner.run(.settle, timeoutMs: 25000, observe: .tree, env: env))
        XCTAssertEqual(env.settles.map(\.timeoutMs), [10000, 10000, 5000])
        XCTAssertEqual(result.until, "timeout")
        XCTAssertEqual(result.reason, "loading")
        XCTAssertEqual(result.waitedMs, 25000)
    }

    // [MCP-97]
    func testABusyReadIsRetriedAtTheNextPoll() async throws {
        let env = FakeWait()
        env.readScript = [.failed("busy"), .tree(tree([("e4", "Continue")]))]
        let result = try answer(await MCPWaitRunner.run(.text("Continue", gone: false), timeoutMs: 10000,
                                                        observe: .tree, env: env))
        XCTAssertEqual(env.reads, [0, 500])
        XCTAssertEqual(result.until, "met")
        XCTAssertEqual(result.match?["ref"] as? String, "e4")
    }

    // [MCP-97]
    func testABusyAtTheDeadlineIsTheError() async throws {
        let env = FakeWait()
        env.readScript = [.failed("busy")]
        let outcome = await MCPWaitRunner.run(.text("Continue", gone: false), timeoutMs: 1500,
                                              observe: .tree, env: env)
        guard case .fail(let code) = outcome else { return XCTFail("expected busy, got \(outcome)") }
        XCTAssertEqual(code, "busy")
        XCTAssertEqual(env.reads, [0, 500, 1000, 1500])
    }

    // [MCP-97]
    func testAnotherReadFailureEndsTheWait() async throws {
        let env = FakeWait()
        env.readScript = [.failed("no_display"), .tree(tree([("e4", "Continue")]))]
        let outcome = await MCPWaitRunner.run(.text("Continue", gone: false), timeoutMs: 10000,
                                              observe: .tree, env: env)
        guard case .fail(let code) = outcome else { return XCTFail("expected no_display, got \(outcome)") }
        XCTAssertEqual(code, "no_display")
        XCTAssertEqual(env.reads, [0])
    }

    // [MCP-97]
    func testTheMatchIgnoresCaseAndAccents() async throws {
        let env = FakeWait()
        env.trees = [tree([("e2", "Café")])]
        let result = try answer(await MCPWaitRunner.run(.text("CAFE", gone: false), timeoutMs: 10000,
                                                        observe: .tree, env: env))
        XCTAssertEqual(result.until, "met")
        XCTAssertEqual(result.match?["text"] as? String, "Café")
        XCTAssertEqual(result.match?["ref"] as? String, "e2")
    }
}
