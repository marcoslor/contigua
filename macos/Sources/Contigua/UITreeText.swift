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

    /// What a line is made of: a parsed node, or a row of an answer already
    /// encoded (an observed read, MCP-82).
    private struct Row {
        var ref = "", role = "", text: String?, desc: String?, hintText: String?
        var heading = false, hint = false, click = false, edit = false, scroll = false
        var check: Bool?
        var selected = false, focused = false, disabled = false, password = false, off = false
        /// Which way an off-screen row is (MCP-75): `above`, `below`, `left`,
        /// `right`, `before`, `after` or `hidden`.
        var whereOff: String?
        var hidden: [Int]?

        init(_ node: UITree.Node) {
            ref = node.ref; role = node.role; text = node.text; desc = node.desc
            hintText = node.hintText; heading = node.heading; hint = node.hint
            click = node.click; edit = node.edit; scroll = node.scroll; check = node.check
            selected = node.selected; focused = node.focused; disabled = node.disabled
            password = node.password; off = node.off; whereOff = node.whereOff; hidden = node.hidden
        }

        /// A row as `UITree.encoded()` writes it.
        init(_ row: [String: Any]) {
            func flag(_ key: String) -> Bool { row[key] as? Bool ?? false }
            ref = row["ref"] as? String ?? ""; role = row["role"] as? String ?? ""
            text = row["text"] as? String; desc = row["desc"] as? String
            hintText = row["hintText"] as? String; heading = flag("heading"); hint = flag("hint")
            click = flag("click"); edit = flag("edit"); scroll = flag("scroll"); check = row["check"] as? Bool
            selected = flag("sel"); focused = flag("focus"); disabled = flag("disabled")
            password = flag("pwd"); off = flag("off"); whereOff = row["where"] as? String
            hidden = (row["hidden"] as? [Int]).flatMap { $0.count == 2 ? $0 : nil }
        }
    }

    /// One line per labelled or actionable node, in reading order.
    /// [within] adds `, in <ref>` to an off-screen match's bracket.
    static func text(_ nodes: [UITree.Node], within: [Int: String] = [:]) -> String {
        lines(nodes.map { (Row($0), $0.index, $0.parent, within[$0.index]) })
    }

    /// The text view of an encoded `ui_tree` answer (an observed read, MCP-82).
    static func text(answer: [String: Any]) -> String {
        lines((answer["nodes"] as? [[String: Any]] ?? []).map { row in
            (Row(row), row["i"] as? Int ?? -1, row["p"] as? Int, row["in"] as? String)
        })
    }

    /// The lines of [rows], each with its `i`, its parent's `i` and a `find`'s
    /// scrollable. An unlabelled clickable wrapper adopts its non-actionable
    /// children's labels onto its own line (MCP-74): a Flutter icon button is
    /// one `View` a client can press, wrapping the text it shows, and two
    /// disconnected lines read as two controls.
    private static func lines(_ rows: [(Row, Int, Int?, String?)]) -> String {
        let absorbed = wrappers(rows)
        var out: [String] = []
        for (at, entry) in rows.enumerated() {
            if absorbed.swallowed.contains(at) { continue }
            let (row, _, _, within) = entry
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

    private static func wrappers(_ rows: [(Row, Int, Int?, String?)]) -> Absorbed {
        var out = Absorbed()
        guard rows.count > 1 else { return out }
        let place = Dictionary(rows.enumerated().map { ($0.element.1, $0.offset) },
                                uniquingKeysWith: { first, _ in first })
        /// The positions under [at], pre-order: the run after it until a row
        /// whose parent is not one of them. Bounded by the row count, so a
        /// malformed parent loop ends.
        func descendants(of at: Int) -> [Int] {
            var under: Set<Int> = [rows[at].1]
            var found: [Int] = []
            var next = at + 1
            var steps = 0
            while next < rows.count, steps <= rows.count {
                steps += 1
                guard let parent = rows[next].2, let parentAt = place[parent],
                      under.contains(parentAt) else { break }
                under.insert(rows[next].1)
                found.append(next)
                next += 1
            }
            return found
        }
        func acts(_ row: Row) -> Bool { row.click || row.edit || row.scroll || row.check != nil }
        for (at, entry) in rows.enumerated() {
            let (row, _, _, _) = entry
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
    private static func line(_ row: Row, within: String?, label: String? = nil) -> String? {
        var parts: [String] = []
        if let label = label ?? self.label(row) {
            parts.append(row.heading ? "# " + label : label)
        }
        if let bracket = bracket(row, within: within) { parts.append(bracket) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The words a line leads with. A formatted value can carry a different
    /// accessible description — a price's ImageSpan placeholders as `text`,
    /// "36 reais com 69 centavos" as `desc` — so both are said, and neither
    /// the visible text nor what the page reads out is lost (MCP-74). A
    /// password field's text never is.
    private static func label(_ row: Row) -> String? {
        if row.hint, let hint = row.hintText, !hint.isEmpty { return hint + " (hint)" }
        if !row.password, let text = row.text, !text.isEmpty {
            if let desc = row.desc, !desc.isEmpty, desc != text { return text + " — " + desc }
            return text
        }
        if let desc = row.desc, !desc.isEmpty { return desc }
        return nil
    }

    /// A node takes a tap, text, a swipe or a check; an off-screen match is
    /// bracketed too, so the reader sees it is off and where.
    private static func bracket(_ row: Row, within: String?) -> String? {
        let acts = row.click || row.edit || row.scroll || row.check != nil
        guard acts || row.off else { return nil }
        var words: [String] = row.ref.isEmpty ? [] : [row.ref]
        words.append(row.role)
        // The row's own keys, in the row's order (WIN-79), true ones only.
        // MCP-75: an off-screen row names which way it is, right after `off`.
        let states: [(Bool, String)] = [
            (row.edit, "edit"), (row.scroll, "scroll"), (row.check == true, "check"),
            (row.selected, "sel"), (row.focused, "focus"), (row.disabled, "disabled"),
            (row.password, "pwd"),
            (row.off, row.whereOff.map { "off \($0)" } ?? "off"),
        ]
        words += states.filter(\.0).map(\.1)
        var inside = words.joined(separator: " ")
        if let hidden = row.hidden, hidden.count == 2 {
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
