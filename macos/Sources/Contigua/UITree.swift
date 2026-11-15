// The Mac's side of `ui.tree` (docs/PROTOCOL.md "UI tree", WIN-79, ISS-160):
// the accessibility tree of the display a window's app runs on — a display no
// accessibility service or `uiautomator dump` can read, which is why a window's
// screen was only reachable as pixels until now (ISS-143).
//
// The phone does the trimming (layout folded away, short names, tap points and
// refs ready for `tap`); this parses that contract, refuses a malformed reply,
// writes the tool result, and remembers each window's refs so a tap can name an
// element instead of a point. Text is on-screen content: it goes to the MCP
// client, never to a log line.

import Foundation

struct UITree: Equatable {
    /// A point in the window's video rect, the space `tap` takes.
    struct Point: Equatable {
        let x: Double
        let y: Double
    }

    struct Window: Equatable {
        let index: Int
        let title: String?
        let type: String
        let focused: Bool
        let active: Bool
    }

    struct Node: Equatable {
        let index: Int
        /// The name this node answers to in `tap`, unique within this tree.
        let ref: String
        let parent: Int?
        let window: Int
        let role: String
        let text: String?
        let desc: String?
        let id: String?
        /// Display pixels, `[left, top, right, bottom]`.
        let box: [Int]?
        /// The bounds' centre, 0..1 of the window.
        let at: Point?
        let click: Bool
        let edit: Bool
        let scroll: Bool
        /// Nil unless the node is checkable; false is a real answer.
        let check: Bool?
        let selected: Bool
        let focused: Bool
        let disabled: Bool
        let password: Bool
    }

    let seq: Int
    let stream: UInt32
    let ok: Bool
    let code: String?
    let message: String?
    let display: Int?
    let snapshot: Int?
    let truncated: Bool
    let windows: [Window]
    let nodes: [Node]
    let note: String?

    /// Nil when the message is not a usable `ui.tree` reply at all (an older
    /// phone, or a torn one); the caller ignores it as it ignores any unknown
    /// message.
    init?(message: JSONMessage) {
        guard let ok = message.bool("ok") else { return nil }
        guard let stream = message.int("stream") else { return nil }
        self.seq = message.int("seq") ?? 0
        self.stream = UInt32(max(0, stream))
        self.ok = ok
        self.code = message.string("code")
        self.message = message.string("message")
        self.display = message.int("display")
        self.snapshot = message.int("snapshot")
        self.truncated = message.bool("truncated") ?? false
        self.note = message.string("note")
        self.windows = (message.array("windows") ?? []).enumerated().compactMap { index, raw in
            guard let type = raw["type"] as? String else { return nil }
            return Window(index: raw["i"] as? Int ?? index,
                          title: raw["title"] as? String,
                          type: type,
                          focused: raw["focused"] as? Bool ?? false,
                          active: raw["active"] as? Bool ?? false)
        }
        self.nodes = (message.array("nodes") ?? []).compactMap { raw in
            guard let role = raw["role"] as? String, let index = raw["i"] as? Int,
                  let ref = raw["ref"] as? String else { return nil }
            let at = (raw["at"] as? [NSNumber]).flatMap { values -> Point? in
                guard values.count == 2 else { return nil }
                return Point(x: values[0].doubleValue, y: values[1].doubleValue)
            }
            return Node(index: index,
                        ref: ref,
                        parent: raw["p"] as? Int,
                        window: raw["w"] as? Int ?? 0,
                        role: role,
                        text: raw["text"] as? String,
                        desc: raw["desc"] as? String,
                        id: raw["id"] as? String,
                        box: (raw["box"] as? [NSNumber])?.map(\.intValue),
                        at: at,
                        click: raw["click"] as? Bool ?? false,
                        edit: raw["edit"] as? Bool ?? false,
                        scroll: raw["scroll"] as? Bool ?? false,
                        check: raw["check"] as? Bool,
                        selected: raw["sel"] as? Bool ?? false,
                        focused: raw["focus"] as? Bool ?? false,
                        disabled: raw["disabled"] as? Bool ?? false,
                        password: raw["pwd"] as? Bool ?? false)
        }
    }

    /// The tool result: the trimmed tree as JSON text, only the fields the
    /// contract names, so a phone's extra field never leaks into an answer.
    func encoded() -> String {
        var root: [String: Any] = [
            "window": Int(stream),
            "ok": ok,
        ]
        if let display { root["display"] = display }
        if let snapshot { root["snapshot"] = snapshot }
        root["truncated"] = truncated
        root["windows"] = windows.map { window -> [String: Any] in
            var row: [String: Any] = ["i": window.index, "type": window.type,
                                      "focused": window.focused, "active": window.active]
            if let title = window.title { row["title"] = title }
            return row
        }
        root["nodes"] = nodes.map { node -> [String: Any] in
            var row: [String: Any] = ["i": node.index, "ref": node.ref,
                                      "w": node.window, "role": node.role]
            if let parent = node.parent { row["p"] = parent }
            if let text = node.text { row["text"] = text }
            if let desc = node.desc { row["desc"] = desc }
            if let id = node.id { row["id"] = id }
            if let box = node.box { row["box"] = box }
            if let at = node.at { row["at"] = [at.x, at.y] }
            if node.click { row["click"] = true }
            if node.edit { row["edit"] = true }
            if node.scroll { row["scroll"] = true }
            if let check = node.check { row["check"] = check }
            if node.selected { row["sel"] = true }
            if node.focused { row["focus"] = true }
            if node.disabled { row["disabled"] = true }
            if node.password { row["pwd"] = true }
            return row
        }
        if let note { root["note"] = note }
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// The refs of the last tree read for each window (WIN-79). A new tree replaces
/// them, so a ref the client kept from an older screen fails loudly instead of
/// pressing whatever has moved under that point.
struct UITreeRefs {
    private struct Read {
        let snapshot: Int
        let points: [String: UITree.Point]
    }

    private var reads: [UInt32: Read] = [:]

    mutating func remember(_ tree: UITree) {
        guard tree.ok else {
            reads[tree.stream] = nil
            return
        }
        var points: [String: UITree.Point] = [:]
        for node in tree.nodes {
            if let at = node.at { points[node.ref] = at }
        }
        reads[tree.stream] = Read(snapshot: tree.snapshot ?? 0, points: points)
    }

    mutating func forget(stream: UInt32) { reads[stream] = nil }
    mutating func forgetAll() { reads.removeAll() }

    /// The point this ref named in the tree last read for that window.
    func point(ref: String, stream: UInt32) -> UITree.Point? {
        reads[stream]?.points[ref]
    }

    /// The read a ref came from, for a sentence that says how old it is.
    func snapshot(stream: UInt32) -> Int? { reads[stream]?.snapshot }
}

/// Why a `ui.tree` read, or a tap by ref, produced nothing. The tool turns
/// these into one human sentence, never a silence.
enum UITreeError: Error, Equatable {
    case notConnected
    case timedOut
    /// The ref is not in the tree last read for that window.
    case staleRef
}
