// Reading less of a window (docs/design/mcp.md "ui_tree", plan T9, #170): the
// text view of a tree (MCP-74) — a covered node saying what sits over it
// (MCP-73) — a hint read as a hint (MCP-104, and `find` reading it), and
// `find`, which keeps only the matching nodes, the off-screen ones included,
// each of those naming the scrollable to swipe (MCP-75, MCP-106).
//
// Pure: a parsed tree in, text or a filtered answer out. The text and the
// query are on-screen content and a client's words: they go to the client,
// never to a log line. A row has one parser, `UITree.Node.parse` (a wire row
// and an encoded one alike), so this view and `find` cannot drift apart.

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
        lines(nodes.map { ($0, within[$0.index]) })
    }

    /// The text view of an encoded `ui_tree` answer (an observed read, MCP-82):
    /// the same rows again, parsed by the one parser, with each row's `in` as
    /// the `find` that answered it named it.
    static func text(answer: [String: Any]) -> String {
        let rows = answer["nodes"] as? [[String: Any]] ?? []
        var within: [Int: String] = [:]
        let nodes = rows.compactMap { row -> UITree.Node? in
            guard let node = UITree.Node.parse(row) else { return nil }
            if let holder = row["in"] as? String { within[node.index] = holder }
            return node
        }
        return text(nodes, within: within)
    }

    /// The lines of [rows], each with the `find`'s scrollable. An unlabelled
    /// clickable wrapper adopts its non-actionable children's labels onto its
    /// own line (MCP-74): a cross-platform toolkit's icon button is one `View`
    /// a client can press, wrapping the text it shows, and two disconnected
    /// lines read as two controls.
    private static func lines(_ rows: [(UITree.Node, String?)]) -> String {
        let absorbed = wrappers(rows)
        var out: [String] = []
        for (at, entry) in rows.enumerated() {
            if absorbed.swallowed.contains(at) { continue }
            let (row, within) = entry
            guard let line = line(row, within: within, label: absorbed.joined[at] ?? label(row)) else {
                continue
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// Which unlabelled clickable wrappers take their children's labels, and
    /// whose lines then go (MCP-74).
    private struct Absorbed {
        var joined: [Int: String] = [:]
        var swallowed: Set<Int> = []
    }

    private static func wrappers(_ rows: [(UITree.Node, String?)]) -> Absorbed {
        var out = Absorbed()
        guard rows.count > 1 else { return out }
        /// The positions under [at], pre-order: the run after it until a row
        /// whose parent is not one of them. A row's `p` names a node's `i`, not
        /// its position — the rows left out off screen make the two differ on
        /// every real screen — so both sides of the comparison are `i`. `next`
        /// advances every pass, so a malformed parent loop ends at the row count.
        func descendants(of at: Int) -> [Int] {
            var under: Set<Int> = [rows[at].0.index]
            var found: [Int] = []
            var next = at + 1
            while next < rows.count {
                guard let parent = rows[next].0.parent, under.contains(parent) else { break }
                under.insert(rows[next].0.index)
                found.append(next)
                next += 1
            }
            return found
        }
        func acts(_ node: UITree.Node) -> Bool {
            node.click || node.edit || node.scroll || node.check != nil
        }
        for (at, entry) in rows.enumerated() {
            let row = entry.0
            // Only a clickable wrapper with no label of its own, and not a
            // field, a list or a check: those act on themselves.
            guard row.click, !row.edit, !row.scroll, row.check == nil, label(row) == nil else { continue }
            let under = descendants(of: at)
            // An actionable or off-screen descendant stays its own line: a
            // clickable card keeps its inner button, and a swipe may reach the
            // row that is off screen.
            guard !under.contains(where: { acts(rows[$0].0) || rows[$0].0.off }) else { continue }
            let labels = under.compactMap { label(rows[$0].0) }
            guard !labels.isEmpty else { continue }
            out.joined[at] = labels.joined(separator: " ")
            for other in under where label(rows[other].0) != nil { out.swallowed.insert(other) }
        }
        return out
    }

    /// `# ` for a heading, the label (a shown hint as `<hint> (hint)`, never a
    /// password's text), then `[<ref> <role> <states>]` for a node a client can
    /// act on; nil for a node with neither.
    private static func line(_ node: UITree.Node, within: String?, label: String? = nil) -> String? {
        var parts: [String] = []
        if let label = label ?? self.label(node) {
            parts.append(node.heading ? "# " + label : label)
        }
        if let bracket = bracket(node, within: within) { parts.append(bracket) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The words a line leads with. A formatted value can carry a different
    /// accessible description — a price's ImageSpan placeholders as `text`,
    /// "36 reais com 69 centavos" as `desc` — so both are said, and neither
    /// the visible text nor what the page reads out is lost (MCP-74). A
    /// password field's text never is.
    private static func label(_ node: UITree.Node) -> String? {
        if node.hint, let hint = node.hintText, !hint.isEmpty { return hint + " (hint)" }
        if !node.password, let text = node.text, !text.isEmpty {
            if let desc = node.desc, !desc.isEmpty, desc != text { return text + " — " + desc }
            return text
        }
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
        // MCP-75: an off-screen row names which way it is, right after `off`.
        let states: [(Bool, String)] = [
            (node.edit, "edit"), (node.scroll, "scroll"), (node.check == true, "check"),
            (node.selected, "sel"), (node.focused, "focus"), (node.disabled, "disabled"),
            (node.password, "pwd"),
            (node.off, node.whereOff.map { "off \($0)" } ?? "off"),
        ]
        words += states.filter(\.0).map(\.1)
        var inside = words.joined(separator: " ")
        if let hidden = node.hidden, hidden.count == 2 {
            inside += ", \(hidden[0]) before, \(hidden[1]) after"
        }
        // MCP-73: a covered row says what sits over it, so a text read tells
        // a promo modal's button from one nothing covers.
        if let covered = node.covered, !covered.isEmpty { inside += ", covered by \(covered)" }
        if let within { inside += ", in \(within)" }
        return "[" + inside + "]"
    }

    // MARK: find (MCP-75, MCP-106)

    /// The rows whose text, description, hint or view id contains [needle],
    /// ignoring case and accents, as `wait`'s text does (MCP-97). An empty
    /// field keeps its words in `hintText` (MCP-104), so `find` reads it or a
    /// search bar can never be found.
    static func find(_ needle: String, in nodes: [UITree.Node]) -> UITreeFind {
        func has(_ value: String?) -> Bool {
            value?.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        var byIndex: [Int: UITree.Node] = [:]
        for node in nodes where byIndex[node.index] == nil { byIndex[node.index] = node }
        var rows: [Int] = []
        var within: [Int: String] = [:]
        for node in nodes where has(node.text) || has(node.desc) || has(node.hintText) || has(node.id) {
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
