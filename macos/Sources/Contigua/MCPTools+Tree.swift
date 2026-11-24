// ui_tree (docs/design/mcp.md, MCP-70, WIN-79).

import Foundation

extension MCPToolHost {
    /// WIN-79/ISS-160: the display's accessibility tree, trimmed by the phone
    /// for a reader. The text in it is on-screen content and lives in the result
    /// only; the app's log line for the call carries name, duration, code and
    /// window (MCP-14). The phone's failure codes map per MCP-70. `find` keeps
    /// the matches, reading the off-screen nodes too (MCP-75, MCP-106);
    /// `format: text` answers the text view (MCP-74).
    func uiTree(_ id: Int, wait: MCPWait, format: MCPTreeFormat = .tree,
                find: String? = nil) async throws -> [String: Any] {
        var settled: MCPActMachine.Settle?
        if wait == .settle {
            _ = try requireWindow(id)
            settled = await settleOnly(id)
        }
        var answer = try await uiTree(id, format: format, find: find)
        if let settled { answer["settle"] = MCPActEnvelope.settle(settled) }
        return answer
    }

    /// One read shaped as [format] asks, filtered by [find].
    func uiTree(_ id: Int, until: ContinuousClock.Instant? = nil, format: MCPTreeFormat,
                find: String? = nil) async throws -> [String: Any] {
        let (tree, answer) = try await readTree(id, until: until, offscreen: find != nil)
        guard let find else {
            controller.uiTreeAnswered(tree, client: client)  // MCP-86: this client's expects
            switch format {
            case .tree: return answer
            case .text: return UITreeText.textAnswer(answer, text: UITreeText.text(tree.nodes))
            }
        }
        let found = UITreeText.find(find, in: tree.nodes)
        let kept = Set(found.rows)
        let shown = tree.nodes.filter { kept.contains($0.index) }
        controller.uiTreeAnswered(tree, client: client, only: Set(shown.compactMap(\.k)))
        let filtered = UITreeText.findAnswer(answer, found)
        switch format {
        case .tree: return filtered
        case .text:
            return UITreeText.textAnswer(filtered, text: UITreeText.text(shown, within: found.within))
        }
    }

    /// MCP-64, MCP-81: settle the window with no input (the machine's Sent
    /// entry), for `screenshot` and `ui_tree` with `wait: "settle"`. A window
    /// that closes meanwhile answers through the read that follows.
    func settleOnly(_ id: Int) async -> MCPActMachine.Settle {
        let env = MCPHostActEnvironment(host: self, id: id, ref: nil,
                                        did: { MCPActDid.key("none") }, input: { _ in })
        let outcome = await MCPActRunner.run(MCPActMachine(screenshotWaiting: ()), window: UInt32(id),
                                             queue: nil, deadline: Self.actDeadline(), env: env)
        switch outcome {
        case .answer(let answer): return answer.settle
        case .fail: return MCPActMachine.Settle(state: "unavailable")
        }
    }

    func uiTree(_ id: Int, until: ContinuousClock.Instant? = nil) async throws -> [String: Any] {
        let (tree, answer) = try await readTree(id, until: until, offscreen: false)
        controller.uiTreeAnswered(tree, client: client)  // MCP-86: this client's expects
        return answer
    }

    /// One `ui.tree` read and its encoded answer; a failed read throws.
    private func readTree(_ id: Int, until: ContinuousClock.Instant?,
                          offscreen: Bool) async throws -> (UITree, [String: Any]) {
        _ = try requireWindow(id)
        let tree = try await controller.uiTree(stream: UInt32(id), until: until, offscreen: offscreen)
        guard tree.ok else {
            throw MCPToolError.uiTreeFailed(code: tree.code, message: tree.message,
                                            window: id, phone: phoneName)
        }
        let object = try JSONSerialization.jsonObject(with: Data(tree.encoded().utf8))
        guard let answer = object as? [String: Any] else {
            throw MCPToolError.failed("The phone could not read that display's accessibility tree. Use screenshot instead.",
                                      window: id)
        }
        return (tree, answer)
    }
}
