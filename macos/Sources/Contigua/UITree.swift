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
    let displayId: Int?
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
        self.displayId = message.int("displayId")
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
    ///
    /// `JSONEncoder`, not `JSONSerialization`: the latter prints a Double in its
    /// full 17-digit expansion, so the tap point `0.949` reached a client as
    /// `0.94899999999999995` and the noise was a tenth of a real tree's tokens.
    func encoded() -> String {
        struct Out: Encodable {
            struct Window: Encodable {
                let i: Int
                let title: String?
                let type: String
                let focused: Bool
                let active: Bool
            }

            struct Node: Encodable {
                let i: Int
                let ref: String
                let p: Int?
                let w: Int?
                let role: String
                let text: String?
                let desc: String?
                let id: String?
                let box: [Int]?
                let at: [Double]?
                let click: Bool?
                let edit: Bool?
                let scroll: Bool?
                let check: Bool?
                let sel: Bool?
                let focus: Bool?
                let disabled: Bool?
                let pwd: Bool?
            }

            let window: Int
            let ok: Bool
            let displayId: Int?
            let snapshot: Int?
            let truncated: Bool
            let windows: [Window]
            let nodes: [Node]
            let note: String?
        }

        // `w` earns its bytes only when the display holds more than one window:
        // with one, every row would repeat the same 0.
        let severalWindows = windows.count > 1
        let out = Out(
            window: Int(stream),
            ok: ok,
            displayId: displayId,
            snapshot: snapshot,
            truncated: truncated,
            windows: windows.map {
                Out.Window(i: $0.index, title: $0.title, type: $0.type,
                           focused: $0.focused, active: $0.active)
            },
            nodes: nodes.map { node in
                Out.Node(i: node.index, ref: node.ref, p: node.parent,
                         w: severalWindows ? node.window : nil,
                         role: node.role, text: node.text, desc: node.desc, id: node.id,
                         box: node.box, at: node.at.map { [$0.x, $0.y] },
                         click: node.click ? true : nil,
                         edit: node.edit ? true : nil,
                         scroll: node.scroll ? true : nil,
                         check: node.check,
                         sel: node.selected ? true : nil,
                         focus: node.focused ? true : nil,
                         disabled: node.disabled ? true : nil,
                         pwd: node.password ? true : nil)
            },
            note: note)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(out) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// The refs of the last tree read for each window (WIN-79). A new tree replaces
/// them, so a ref the client kept from an older screen fails loudly instead of
/// pressing whatever has moved under that point.
struct UITreeRefs {
    /// One element as the tree placed it. The box rides along so a tap can say
    /// what it pressed, in the same pixels the tree named.
    struct Placed: Equatable {
        let point: UITree.Point
        let box: [Int]?
    }

    private struct Read {
        let snapshot: Int
        let nodes: [String: Placed]
    }

    private var reads: [UInt32: Read] = [:]

    mutating func remember(_ tree: UITree) {
        guard tree.ok else {
            reads[tree.stream] = nil
            return
        }
        var nodes: [String: Placed] = [:]
        for node in tree.nodes {
            if let at = node.at { nodes[node.ref] = Placed(point: at, box: node.box) }
        }
        reads[tree.stream] = Read(snapshot: tree.snapshot ?? 0, nodes: nodes)
    }

    mutating func forget(stream: UInt32) { reads[stream] = nil }
    mutating func forgetAll() { reads.removeAll() }

    /// The element this ref named in the tree last read for that window, and the
    /// read it came from.
    func resolved(ref: String, stream: UInt32) -> (snapshot: Int, placed: Placed)? {
        guard let read = reads[stream], let placed = read.nodes[ref] else { return nil }
        return (read.snapshot, placed)
    }
}

/// Why a `ui.tree` read, or a tap by ref, produced nothing. The tool turns
/// these into one human sentence, never a silence.
enum UITreeError: Error, Equatable {
    case notConnected
    case timedOut
    /// The ref is not in the tree last read for that window.
    case staleRef
}
