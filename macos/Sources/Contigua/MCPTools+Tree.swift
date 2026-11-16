// ui_tree (docs/design/mcp.md, MCP-70, WIN-79).

import Foundation

extension MCPToolHost {
    /// WIN-79/ISS-160: the display's accessibility tree, trimmed by the phone
    /// for a reader. The text in it is on-screen content and lives in the result
    /// only; the app's log line for the call carries name, duration, code and
    /// window (MCP-14). The phone's failure codes map per MCP-70.
    func uiTree(_ id: Int, wait: MCPWait) async throws -> [String: Any] {
        guard wait == .settle else { return try await uiTree(id) }
        _ = try requireWindow(id)
        let settle = await settleOnly(id)
        var answer = try await uiTree(id)
        answer["settle"] = MCPActEnvelope.settle(settle)
        return answer
    }

    /// MCP-64, MCP-81: settle the window with no input (the machine's Sent
    /// entry), for `screenshot` and `ui_tree` with `wait: "settle"`. A window
    /// that closes meanwhile answers through the read that follows.
    func settleOnly(_ id: Int) async -> MCPActMachine.Settle {
        let env = MCPHostActEnvironment(host: self, id: id, ref: nil,
                                        did: { MCPActDid.key("none") }, input: { _ in })
        let outcome = await MCPActRunner.run(MCPActMachine(screenshotWaiting: ()), window: UInt32(id),
                                             queue: nil, deadline: Self.actDeadline, env: env)
        switch outcome {
        case .answer(let answer): return answer.settle
        case .fail: return MCPActMachine.Settle(state: "unavailable")
        }
    }

    func uiTree(_ id: Int) async throws -> [String: Any] {
        _ = try requireWindow(id)
        let tree = try await controller.uiTree(stream: UInt32(id))
        guard tree.ok else {
            throw MCPToolError.uiTreeFailed(code: tree.code, message: tree.message,
                                            window: id, phone: phoneName)
        }
        let object = try JSONSerialization.jsonObject(with: Data(tree.encoded().utf8))
        guard let answer = object as? [String: Any] else {
            throw MCPToolError.failed("The phone could not read that display's accessibility tree. Use screenshot instead.",
                                      window: id)
        }
        return answer
    }
}
