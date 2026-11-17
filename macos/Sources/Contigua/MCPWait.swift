// `wait` (docs/design/mcp.md, MCP-96, MCP-97, MCP-111; plan T11): a clock, a
// text condition polled at most twice a second, or the phone's settle. The
// decisions (when to read next, whether a tree meets the condition, the call's
// bound) are pure; the runner drives them against an environment whose clock,
// tree reads and settle are injected, so the tests run on a virtual clock.

import Foundation

/// What `wait` waits for. The argument checks keep these exclusive.
enum MCPWaitMode: Equatable {
    /// MCP-96: `ms` milliseconds.
    case clock(ms: Int)
    /// MCP-97: until a node's text or description contains it (with `gone`:
    /// until none does).
    case text(String, gone: Bool)
    /// MCP-111: the settle of MCP-81 and MCP-107, for up to `timeoutMs`.
    case settle
}

/// One tree read while waiting: the `ui_tree` answer, or its failure code.
enum MCPWaitRead {
    case tree([String: Any])
    case failed(String)
}

/// The answer before the host stamps `window`, `state` and `frame`.
struct MCPWaitAnswer {
    var waitedMs: Int
    var until: String?
    var match: [String: Any]?
    var reason: String?
    var tree: [String: Any]?
    var treeError: String?

    func object(window: Int) -> [String: Any] {
        var object: [String: Any] = ["window": window, "waitedMs": waitedMs]
        if let until { object["until"] = until }
        if let match { object["match"] = match }
        if let reason { object["reason"] = reason }
        if let tree { object["tree"] = tree }
        if let treeError { object["treeError"] = treeError }
        return object
    }
}

enum MCPWaitOutcome {
    case answer(MCPWaitAnswer)
    case fail(String)
}

/// The clock, the reads and the settle, in milliseconds on one clock. Every
/// call carries `untilMs`, the call's own bound (MCP-8); reads and settles
/// take their turn in the phone's read queue (MCP-9).
@MainActor
protocol MCPWaitEnvironment: AnyObject {
    func nowMs() -> Int
    func sleep(untilMs: Int) async
    func readTree(untilMs: Int) async -> MCPWaitRead
    func settle(quietMs: Int, timeoutMs: Int, untilMs: Int) async -> MCPSettleResult
}

enum MCPWaitPlan {
    /// MCP-97: never two reads less than this apart.
    static let pollMs = 500
    static let defaultTimeoutMs = 10_000
    static let maxMs = 30_000
    /// PROTOCOL.md "UI tree" §7: the phone's largest settle timeout.
    static let settleCapMs = 10_000
    /// MCP-8: what a call may take beyond its own wait.
    static let graceMs = 3000

    /// When the next read may start: at once for the first, else 500 ms after
    /// the last read started.
    static func nextRead(lastReadAt: Int?, now: Int) -> Int {
        guard let lastReadAt else { return now }
        return max(now, lastReadAt + pollMs)
    }

    /// The first node whose text or description contains `text`, as `match`.
    static func match(_ text: String, in tree: [String: Any]) -> [String: Any]? {
        let nodes = tree["nodes"] as? [[String: Any]] ?? []
        for node in nodes {
            let label = node["text"] as? String
            let desc = node["desc"] as? String
            guard label?.contains(text) == true || desc?.contains(text) == true else { continue }
            var found: [String: Any] = [:]
            if let ref = node["ref"] { found["ref"] = ref }
            if let shown = label ?? desc { found["text"] = shown }
            return found
        }
        return nil
    }
}

@MainActor
enum MCPWaitRunner {
    /// MCP-8: `ms` + 3 s for a clock; `timeoutMs` + 3 s for a condition.
    nonisolated static func boundMs(_ mode: MCPWaitMode, timeoutMs: Int) -> Int {
        switch mode {
        case .clock(let ms): return ms + MCPWaitPlan.graceMs
        case .text, .settle: return timeoutMs + MCPWaitPlan.graceMs
        }
    }

    static func run(_ mode: MCPWaitMode, timeoutMs: Int, observe: MCPObserve,
                    env: MCPWaitEnvironment) async -> MCPWaitOutcome {
        let start = env.nowMs()
        let until = start + boundMs(mode, timeoutMs: timeoutMs)
        switch mode {
        case .clock(let ms):
            await env.sleep(untilMs: start + ms)
            var answer = MCPWaitAnswer(waitedMs: env.nowMs() - start)
            await observeRead(&answer, observe: observe, env: env, until: until)
            return .answer(answer)

        case .text(let text, let gone):
            let end = start + timeoutMs
            var lastReadAt: Int?
            var lastTree: [String: Any]?
            while true {
                let next = MCPWaitPlan.nextRead(lastReadAt: lastReadAt, now: env.nowMs())
                if lastReadAt != nil && next > end {
                    await env.sleep(untilMs: end)
                    var answer = MCPWaitAnswer(waitedMs: env.nowMs() - start, until: "timeout")
                    if observe == .tree { answer.tree = lastTree }
                    return .answer(answer)
                }
                await env.sleep(untilMs: next)
                lastReadAt = env.nowMs()
                switch await env.readTree(untilMs: until) {
                case .failed(let code):
                    return .fail(code)
                case .tree(let tree):
                    lastTree = tree
                    let found = MCPWaitPlan.match(text, in: tree)
                    if gone ? found == nil : found != nil {
                        var answer = MCPWaitAnswer(waitedMs: env.nowMs() - start, until: "met",
                                                   match: gone ? nil : found)
                        if observe == .tree { answer.tree = tree }
                        return .answer(answer)
                    }
                }
            }

        case .settle:
            // PROTOCOL.md "UI tree" §7 clamps a settle to 10 s; MCP-111 allows
            // 30 s ([NEEDS CLARIFICATION] in the row): one settle, at the wire's cap.
            let result = await env.settle(quietMs: MCPActMachine.quietMs,
                                          timeoutMs: min(timeoutMs, MCPWaitPlan.settleCapMs),
                                          untilMs: until)
            var answer: MCPWaitAnswer
            switch result {
            case .reply(let settled, _, let reason):
                answer = MCPWaitAnswer(waitedMs: env.nowMs() - start, until: settled ? "met" : "timeout",
                                       reason: settled ? nil : (reason ?? "changes"))
            case .failed(let code):
                return .fail(code)
            }
            await observeRead(&answer, observe: observe, env: env, until: until)
            return .answer(answer)
        }
    }

    private static func observeRead(_ answer: inout MCPWaitAnswer, observe: MCPObserve,
                                    env: MCPWaitEnvironment, until: Int) async {
        guard observe == .tree else { return }
        switch await env.readTree(untilMs: until) {
        case .tree(let tree): answer.tree = tree
        case .failed(let code): answer.treeError = code
        }
    }
}
