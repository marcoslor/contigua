// wait (docs/design/mcp.md, MCP-96, MCP-97, MCP-111; plan T11).

import Foundation

extension MCPToolHost {
    /// Wait on a window by the pure runner (MCPWait.swift). Every tree read
    /// and settle goes through the phone's read queue (MCP-9) with the call's
    /// bound (MCP-8) as its deadline.
    func wait(window id: Int, mode: MCPWaitMode, timeoutMs: Int,
              observe: MCPObserve) async throws -> [String: Any] {
        _ = try requireWindow(id)
        let env = MCPHostWaitEnvironment(host: self, id: id)
        switch await MCPWaitRunner.run(mode, timeoutMs: timeoutMs, observe: observe, env: env) {
        case .answer(let answer):
            var object = answer.object(window: id)
            if let window = controller.windows.controller(for: UInt32(id)) {
                object = MCPFreshness.stamp(object, state: stateToken(for: window),
                                            frame: frameObject(for: window))
            } else {
                object["state"] = "closed"
                object["frame"] = env.lastFrame ?? FrameClock.object(seq: 0, ageMs: nil)
            }
            return object
        case .fail(let code):
            if let error = env.error { throw error }
            throw MCPHostActEnvironment(host: self, id: id, ref: nil, did: { MCPActDid.key("none") },
                                        input: { _ in }).error(for: code)
        }
    }
}

/// The real clock, the window's tree and the phone's settle.
@MainActor
final class MCPHostWaitEnvironment: MCPWaitEnvironment {
    private let host: MCPToolHost
    private let id: Int
    private let origin = ContinuousClock.now
    /// The read's own failure, with its sentence, when one ended the call.
    private(set) var error: Error?
    private(set) var lastFrame: [String: Any]?

    init(host: MCPToolHost, id: Int) {
        self.host = host
        self.id = id
    }

    private func instant(_ ms: Int) -> ContinuousClock.Instant { origin + .milliseconds(ms) }

    func nowMs() -> Int {
        let elapsed = ContinuousClock.now - origin
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    func sleep(untilMs: Int) async {
        try? await Task.sleep(until: instant(untilMs), clock: .continuous)
    }

    func readTree(untilMs: Int) async -> MCPWaitRead {
        remember()
        do {
            var answer = try await host.uiTree(id, until: instant(untilMs))
            if let window = host.controller.windows.controller(for: UInt32(id)) {
                answer = MCPFreshness.stamp(answer, state: host.stateToken(for: window),
                                            frame: host.frameObject(for: window))
            }
            return .tree(answer)
        } catch {
            self.error = MCPToolError.mapping(error, phone: host.phoneName)
            return .failed((self.error as? MCPToolError)?.code.rawValue ?? "failed")
        }
    }

    func settle(quietMs: Int, timeoutMs: Int, untilMs: Int) async -> MCPSettleResult {
        remember()
        return await host.settleResult(id, quietMs: quietMs, timeoutMs: timeoutMs, until: instant(untilMs))
    }

    private func remember() {
        if let window = host.controller.windows.controller(for: UInt32(id)) {
            lastFrame = host.frameObject(for: window)
        }
    }
}
