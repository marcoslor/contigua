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

        func nowMs() -> Int { now }
        func sleep(untilMs: Int) async { now = max(now, untilMs) }
        func readTree(untilMs: Int) async -> MCPWaitRead {
            reads.append(now)
            readUntil.append(untilMs)
            let index = min(reads.count - 1, trees.count - 1)
            return index >= 0 ? .tree(trees[index]) : .failed("failed")
        }
        func settle(quietMs: Int, timeoutMs: Int, untilMs: Int) async -> MCPSettleResult {
            settles.append((quietMs, timeoutMs))
            if case .reply(_, let waited, _) = settleReply { now += waited }
            return settleReply
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
}
