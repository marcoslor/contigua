// Reading less of a window (docs/design/mcp.md "ui_tree", plan T9, #170): the
// text view of a tree (MCP-74), a hint read as a hint (MCP-104), and `find`,
// which keeps only the matching nodes, the off-screen ones included, each of
// those naming the scrollable to swipe (MCP-75, MCP-106).
//
// Pure: a parsed tree in, text or a filtered answer out. The text and the
// query are on-screen content and a client's words: they go to the client,
// never to a log line.

import Foundation

/// What `find` kept of one read (MCP-75).
struct UITreeFind: Equatable {
    /// The matching rows' `i`, in reading order.
    var rows: [Int]
    var matched: Int { rows.count }
    /// Every row the read held, the matches and the rest.
    var total: Int
    /// For each off-screen match's `i`, the ref of the scrollable that holds
    /// it (MCP-106): swiping that ref reaches it.
    var within: [Int: String]
}

enum UITreeText {
    // MARK: The text view (MCP-74)

    /// One line per labelled or actionable node, in reading order.
    /// [within] adds `, in <ref>` to an off-screen match's bracket.
    static func text(_ nodes: [UITree.Node], within: [Int: String] = [:]) -> String {
        nodes.compactMap { line($0, within: within[$0.index]) }.joined(separator: "\n")
    }

    /// `# ` for a heading, the label (a shown hint as `<hint> (hint)`, never a
    /// password's text), then `[<ref> <role> <states>]` for a node a client can
    /// act on; nil for a node with neither.
    static func line(_ node: UITree.Node, within: String? = nil) -> String? {
        var parts: [String] = []
        if let label = label(node) {
            parts.append(node.heading ? "# " + label : label)
        }
        if let bracket = bracket(node, within: within) { parts.append(bracket) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func label(_ node: UITree.Node) -> String? {
        if node.hint, let hint = node.hintText, !hint.isEmpty { return hint + " (hint)" }
        if !node.password, let text = node.text, !text.isEmpty { return text }
        if let desc = node.desc, !desc.isEmpty { return desc }
        return nil
    }

    /// A node takes a tap, text, a swipe or a check; an off-screen match is
    /// bracketed too, so the reader sees it is off and where.
    private static func bracket(_ node: UITree.Node, within: String?) -> String? {
        let acts = node.click || node.edit || node.scroll || node.check != nil
        guard acts || node.off else { return nil }
        var words: [String] = node.ref.isEmpty ? [] : [node.ref]
        words.append(node.role)
        // The row's own keys, in the row's order (WIN-79), true ones only.
        let states: [(Bool, String)] = [
            (node.edit, "edit"), (node.scroll, "scroll"), (node.check == true, "check"),
            (node.selected, "sel"), (node.focused, "focus"), (node.disabled, "disabled"),
            (node.password, "pwd"), (node.off, "off"),
        ]
        words += states.filter(\.0).map(\.1)
        var inside = words.joined(separator: " ")
        if let hidden = node.hidden, hidden.count == 2 {
            inside += ", \(hidden[0]) before, \(hidden[1]) after"
        }
        if let within { inside += ", in \(within)" }
        return "[" + inside + "]"
    }

    // MARK: find (MCP-75, MCP-106)

    /// The rows whose text, description or view id contains [needle],
    /// ignoring case and accents, as `wait`'s text does (MCP-97).
    static func find(_ needle: String, in nodes: [UITree.Node]) -> UITreeFind {
        func has(_ value: String?) -> Bool {
            value?.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        var byIndex: [Int: UITree.Node] = [:]
        for node in nodes where byIndex[node.index] == nil { byIndex[node.index] = node }
        var rows: [Int] = []
        var within: [Int: String] = [:]
        for node in nodes where has(node.text) || has(node.desc) || has(node.id) {
            rows.append(node.index)
            if node.off, let holder = scrollable(holding: node, in: byIndex, limit: nodes.count) {
                within[node.index] = holder
            }
        }
        return UITreeFind(rows: rows, total: nodes.count, within: within)
    }

    /// The ref of the nearest on-screen scrollable above [node] by `p`: the
    /// one a client can swipe. Bounded by the row count, so a malformed
    /// parent loop ends.
    private static func scrollable(holding node: UITree.Node, in byIndex: [Int: UITree.Node],
                                   limit: Int) -> String? {
        var parent = node.parent
        var steps = 0
        while let at = parent, let row = byIndex[at], steps < limit {
            if row.scroll, !row.off, !row.ref.isEmpty { return row.ref }
            parent = row.parent
            steps += 1
        }
        return nil
    }

    // MARK: Answers

    /// The `ui_tree` answer [answer] (the encoded tree) keeping only [found]'s
    /// rows, each off-screen one with `in`, plus `matched` and `total`.
    static func findAnswer(_ answer: [String: Any], _ found: UITreeFind) -> [String: Any] {
        var out = answer
        let keep = Set(found.rows)
        let nodes = (answer["nodes"] as? [[String: Any]] ?? []).compactMap { row -> [String: Any]? in
            guard let index = row["i"] as? Int, keep.contains(index) else { return nil }
            var row = row
            if let holder = found.within[index] { row["in"] = holder }
            return row
        }
        out["nodes"] = nodes
        out["matched"] = found.matched
        out["total"] = found.total
        return out
    }

    /// The `format: "text"` answer: the read's window and snapshot, the text,
    /// and what the tree said of itself when it says something (a note, the
    /// node cap, a loading screen). No rows.
    static func textAnswer(_ answer: [String: Any], text: String) -> [String: Any] {
        var out: [String: Any] = ["format": "text", "text": text]
        for key in ["window", "snapshot", "note", "settle", "matched", "total"] {
            if let value = answer[key] { out[key] = value }
        }
        for key in ["truncated", "loading"] where answer[key] as? Bool == true {
            out[key] = true
        }
        return out
    }
}
