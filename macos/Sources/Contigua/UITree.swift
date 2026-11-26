// The Mac's side of `ui.tree` (docs/PROTOCOL.md "UI tree", WIN-79, ISS-160):
// the accessibility tree of the display a window's app runs on — a display no
// accessibility service or `uiautomator dump` can read, which is why a window's
// screen was only reachable as pixels until now (ISS-143).
//
// The phone does the trimming (layout folded away, short names, tap points,
// off-screen nodes marked `off`); this parses that contract, refuses a
// malformed reply, writes the tool result, and issues each reply's refs from a
// per-window read counter. A ref never crosses the wire: the phone sends none,
// and the Mac names them `s<snapshot>e<row>` from the counter it owns (S1).
// Text is on-screen content: it goes to the MCP client, never to a log line.

import Foundation

struct UITree: Equatable {
    /// A point in the display's input space, the space TOUCH and `tap` take.
    struct Point: Equatable {
        let x: Double
        let y: Double
    }

    struct Layer: Equatable {
        let index: Int
        let title: String?
        let type: String
        /// The layer with input focus (MCP-105); the phone sends no `focused`.
        let active: Bool
    }

    struct Node: Equatable {
        let index: Int
        /// The name this node answers to in `tap`, issued by the Mac (S1).
        var ref: String
        let parent: Int?
        let layer: Int
        let role: String
        let text: String?
        let desc: String?
        let id: String?
        /// Display pixels, `[left, top, right, bottom]`, clipped to the display.
        let box: [Int]?
        /// The visible bounds' centre, 0..1 of the display's input space.
        let at: Point?
        /// True when the node has no on-screen tap point (F9).
        let off: Bool
        /// Which way an off-screen node is (MCP-75): `above`, `below`, `left`,
        /// `right`, `before`, `after` or `hidden`, from an `offscreen` read.
        /// `where` is a Swift keyword, so it is `whereOff` here.
        var whereOff: String? = nil
        let click: Bool
        let edit: Bool
        let scroll: Bool
        /// Nil unless the node is checkable; false is a real answer.
        let check: Bool?
        let selected: Bool
        let focused: Bool
        let disabled: Bool
        let password: Bool
        /// A loading signal: an indeterminate spinner or an empty WebView (MCP-103).
        var loading: Bool = false
        /// The phone's key (MCP-71): the same node keeps it across reads.
        var k: Int? = nil
        var heading: Bool = false
        /// The covering node's ref (`e<k>`) or `"window"` (MCP-73).
        var covered: String? = nil
        /// The node shows its hint, not content: no `text` (MCP-104).
        var hint: Bool = false
        var hintText: String? = nil
        /// A scrollable's left-out rows `[before, after]` (MCP-106).
        var hidden: [Int]? = nil
    }

    let seq: Int
    let stream: UInt32
    let ok: Bool
    let code: String?
    let message: String?
    let displayId: Int?
    /// The Mac's per-window read counter; nil until [assigning] fills it.
    let snapshot: Int?
    /// The pixel space `box` is in, `[w, h]` (S2).
    let size: [Int]?
    let truncated: Bool
    let layers: [Layer]
    let nodes: [Node]
    let note: String?
    /// True while any node is a loading signal (MCP-103).
    let loading: Bool
    /// How many off-screen rows the phone left out (MCP-106); nil from an older phone.
    var omitted: Int? = nil

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
        self.snapshot = nil
        let rawSize = message.raw["size"] as? [NSNumber]
        self.size = rawSize?.count == 2 ? rawSize!.map(\.intValue) : nil
        self.truncated = message.bool("truncated") ?? false
        self.note = message.string("note")
        self.loading = message.bool("loading") ?? false
        self.omitted = message.int("omitted")
        self.layers = (message.array("layers") ?? []).enumerated().compactMap { index, raw in
            guard let type = raw["type"] as? String else { return nil }
            return Layer(index: raw["i"] as? Int ?? index,
                         title: raw["title"] as? String,
                         type: type,
                         active: raw["active"] as? Bool ?? false)
        }
        self.nodes = (message.array("nodes") ?? []).compactMap { raw in
            guard let role = raw["role"] as? String, let index = raw["i"] as? Int else { return nil }
            let at = (raw["at"] as? [NSNumber]).flatMap { values -> Point? in
                guard values.count == 2 else { return nil }
                return Point(x: values[0].doubleValue, y: values[1].doubleValue)
            }
            var covered: String?
            if let key = raw["covered"] as? Int { covered = "e\(key)" }
            else if let word = raw["covered"] as? String { covered = word }
            let key = raw["k"] as? Int
            var node = Node(index: index,
                        ref: key.map { "e\($0)" } ?? "",
                        parent: raw["p"] as? Int,
                        layer: raw["l"] as? Int ?? 0,
                        role: role,
                        text: raw["text"] as? String,
                        desc: raw["desc"] as? String,
                        id: raw["id"] as? String,
                        box: (raw["box"] as? [NSNumber])?.map(\.intValue),
                        at: at,
                        off: raw["off"] as? Bool ?? false,
                        click: raw["click"] as? Bool ?? false,
                        edit: raw["edit"] as? Bool ?? false,
                        scroll: raw["scroll"] as? Bool ?? false,
                        check: raw["check"] as? Bool,
                        selected: raw["sel"] as? Bool ?? false,
                        focused: raw["focus"] as? Bool ?? false,
                        disabled: raw["disabled"] as? Bool ?? false,
                        password: raw["pwd"] as? Bool ?? false,
                        loading: raw["loading"] as? Bool ?? false,
                        k: key,
                        heading: raw["heading"] as? Bool ?? false,
                        covered: covered,
                        hint: raw["hint"] as? Bool ?? false,
                        hintText: raw["hintText"] as? String,
                        hidden: (raw["hidden"] as? [NSNumber]).flatMap { $0.count == 2 ? $0.map(\.intValue) : nil })
            node.whereOff = raw["where"] as? String
            return node
        }
    }

    init(seq: Int, stream: UInt32, ok: Bool, code: String?, message: String?,
         displayId: Int?, snapshot: Int?, size: [Int]?, truncated: Bool,
         layers: [Layer], nodes: [Node], note: String?, loading: Bool = false) {
        self.seq = seq
        self.stream = stream
        self.ok = ok
        self.code = code
        self.message = message
        self.displayId = displayId
        self.snapshot = snapshot
        self.size = size
        self.truncated = truncated
        self.layers = layers
        self.nodes = nodes
        self.note = note
        self.loading = loading
    }

    /// The same tree stamped with the Mac's read counter [snapshot]. Refs are
    /// the phone's keys, `e<k>`, named at parse (MCP-71); a row with no key
    /// has no ref.
    func assigning(snapshot: Int) -> UITree {
        var out = UITree(seq: seq, stream: stream, ok: ok, code: code, message: message,
                         displayId: displayId, snapshot: snapshot, size: size,
                         truncated: truncated, layers: layers, nodes: nodes,
                         note: note, loading: loading)
        out.omitted = omitted
        return out
    }

    /// Each keyed row's label, as `expect` sends it (PROTOCOL.md "UI tree"
    /// item 8): its text, else its desc, else the first on-screen row under it
    /// with either, in reading order (an `off` row gives none of its own: the
    /// phone reads live nodes and skips what the tree marks `off`, MCP-106).
    /// An editable row's label is its desc, else its id, never its text (its
    /// value); under another row an editable row and its rows give none. A row
    /// with no label is left out: no `expect`.
    ///
    /// Rows arrive in pre-order, so a row's subtree is the run of rows after
    /// it up to `ends[at]`; one pass finds every run.
    func labels() -> [Int: String] {
        let ends = subtreeEnds()
        var out: [Int: String] = [:]
        for (at, node) in nodes.enumerated() {
            guard let k = node.k else { continue }
            if let label = label(at: at, ends: ends) { out[k] = label }
        }
        return out
    }

    private static func own(_ node: Node) -> String? {
        if let text = node.text, !text.isEmpty { return text }
        if let desc = node.desc, !desc.isEmpty { return desc }
        return nil
    }

    private func label(at: Int, ends: [Int]) -> String? {
        let node = nodes[at]
        if node.edit {
            if let desc = node.desc, !desc.isEmpty { return desc }
            if let id = node.id, !id.isEmpty { return id }
            return nil
        }
        if let own = Self.own(node) { return own }
        var next = at + 1
        while next < ends[at] {
            if nodes[next].edit {
                next = ends[next]  // a field and its rows give no label
                continue
            }
            if !nodes[next].off, let own = Self.own(nodes[next]) { return own }
            next += 1
        }
        return nil
    }

    /// For each row's position, the position just past its subtree.
    private func subtreeEnds() -> [Int] {
        var ends = Array(repeating: nodes.count, count: nodes.count)
        var open: [Int] = []  // positions of the rows the current one may sit under
        for (at, node) in nodes.enumerated() {
            while let top = open.last, nodes[top].index != node.parent {
                ends[top] = at
                open.removeLast()
            }
            open.append(at)
        }
        return ends
    }

    /// The tool result: the trimmed tree as JSON text, only the fields the
    /// contract names, so a phone's extra field never leaks into an answer.
    ///
    /// `JSONEncoder`, not `JSONSerialization`: the latter prints a Double in its
    /// full 17-digit expansion, so the tap point `0.949` reached a client as
    /// `0.94899999999999995` and the noise was a tenth of a real tree's tokens.
    func encoded() -> String {
        struct Out: Encodable {
            struct Layer: Encodable {
                let i: Int
                let title: String?
                let type: String
                let active: Bool?
            }

            struct Node: Encodable {
                let i: Int
                let ref: String?
                let p: Int?
                let l: Int?
                let role: String
                let text: String?
                let desc: String?
                let id: String?
                let box: [Int]?
                let at: [Double]?
                let off: Bool?
                /// MCP-75: which way an off-screen row is, from an `offscreen` read.
                let `where`: String?
                let click: Bool?
                let edit: Bool?
                let scroll: Bool?
                let check: Bool?
                let sel: Bool?
                let focus: Bool?
                let disabled: Bool?
                let pwd: Bool?
                let loading: Bool?
                let heading: Bool?
                let covered: String?
                let hint: Bool?
                let hintText: String?
                let hidden: [Int]?
            }

            let window: Int
            let ok: Bool
            let displayId: Int?
            let snapshot: Int?
            let size: [Int]?
            let truncated: Bool
            let layers: [Layer]
            let nodes: [Node]
            let note: String?
            let loading: Bool?
            let omitted: Int?
        }

        // `l` earns its bytes only when the display holds more than one layer:
        // with one, every row would repeat the same 0.
        let severalLayers = layers.count > 1
        let out = Out(
            window: Int(stream),
            ok: ok,
            displayId: displayId,
            snapshot: snapshot,
            size: size,
            truncated: truncated,
            layers: layers.map {
                Out.Layer(i: $0.index, title: $0.title, type: $0.type,
                          active: $0.active ? true : nil)
            },
            nodes: nodes.map { node in
                Out.Node(i: node.index, ref: node.ref.isEmpty ? nil : node.ref, p: node.parent,
                         l: severalLayers ? node.layer : nil,
                         role: node.role, text: node.text, desc: node.desc, id: node.id,
                         box: node.box, at: node.at.map { [$0.x, $0.y] },
                         off: node.off ? true : nil,
                         `where`: node.whereOff,
                         click: node.click ? true : nil,
                         edit: node.edit ? true : nil,
                         scroll: node.scroll ? true : nil,
                         check: node.check,
                         sel: node.selected ? true : nil,
                         focus: node.focused ? true : nil,
                         disabled: node.disabled ? true : nil,
                         pwd: node.password ? true : nil,
                         loading: node.loading ? true : nil,
                         heading: node.heading ? true : nil,
                         covered: node.covered,
                         hint: node.hint ? true : nil,
                         hintText: node.hintText,
                         hidden: node.hidden)
            },
            note: note,
            loading: loading ? true : nil,
            omitted: omitted)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(out) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// The refs of the last tree read for each window (WIN-79). A new tree replaces
/// them, so a ref the client kept from an older screen fails loudly instead of
/// pressing whatever has moved under that point. The per-window read counter
/// lives here too, and survives a reconnect (S1).
struct UITreeRefs {
    /// One element as the tree placed it. The box rides along so a tap can say
    /// what it pressed, in the same pixels the tree named. `off` has no point.
    struct Placed: Equatable {
        let point: UITree.Point?
        let box: [Int]?
        let off: Bool
    }

    private struct Read {
        let snapshot: Int
        let nodes: [String: Placed]
        /// The pixel space of the read's boxes (MCP-50, MCP-63).
        let size: [Int]?
    }

    private var reads: [UInt32: Read] = [:]
    /// The latest read itself, for an answer's `did.node` and `did.hit`
    /// (MCP-87, MCP-108).
    private var trees: [UInt32: UITree] = [:]
    private var counters: [UInt32: Int] = [:]

    /// The next read's snapshot for this window, counting from 1 (S1). Kept
    /// across reconnects: only [forget] drops it.
    mutating func nextSnapshot(for stream: UInt32) -> Int {
        let next = (counters[stream] ?? 0) + 1
        counters[stream] = next
        return next
    }

    /// A successful read replaces the window's refs. A failed read keeps the
    /// previous ones (F6).
    mutating func remember(_ tree: UITree) {
        guard tree.ok, let snapshot = tree.snapshot else { return }
        var nodes: [String: Placed] = [:]
        for node in tree.nodes {
            nodes[node.ref] = Placed(point: node.at, box: node.box, off: node.off)
        }
        trees[tree.stream] = tree
        reads[tree.stream] = Read(snapshot: snapshot, nodes: nodes,
                                  size: tree.size?.count == 2 ? tree.size : nil)
    }

    /// Forget a window's refs and counter: on close, or when a stream id is
    /// reused (F4).
    mutating func forget(stream: UInt32) {
        reads[stream] = nil
        trees[stream] = nil
        counters[stream] = nil
    }

    /// Drop every window's refs, but keep the counters (a reconnect keeps the
    /// read count, S1).
    mutating func forgetAll() {
        reads.removeAll()
        trees.removeAll()
    }

    func latestTree(for stream: UInt32) -> UITree? { trees[stream] }

    func resolved(ref: String, stream: UInt32) -> UITreeResolution {
        guard let read = reads[stream] else { return .noTree }
        guard let placed = read.nodes[ref] else {
            return .stale(ref: ref, snapshot: Self.snapshot(in: ref), latest: read.snapshot)
        }
        return .placed(snapshot: read.snapshot, placed: placed)
    }

    func latestSnapshot(for stream: UInt32) -> Int? { reads[stream]?.snapshot }

    /// The latest read's `size`: the display pixels its boxes are in.
    func latestSize(for stream: UInt32) -> [Int]? { reads[stream]?.size }

    /// `"s13e5"` → 13.
    private static func snapshot(in ref: String) -> Int {
        guard ref.first == "s" else { return 0 }
        var digits = ""
        for ch in ref.dropFirst() {
            if ch.isNumber { digits.append(ch) } else { break }
        }
        return Int(digits) ?? 0
    }
}

/// What resolving a `tap` ref found (WIN-79).
enum UITreeResolution: Equatable {
    /// The ref is in the latest tree, with the read it came from.
    case placed(snapshot: Int, placed: UITreeRefs.Placed)
    /// The ref is from an older tree: name both snapshots so the client knows
    /// which read it pressed on (F1).
    case stale(ref: String, snapshot: Int, latest: Int)
    /// No tree for this window: never read, reopened under this id (F4), or
    /// read before the phone reconnected. The tool has already checked that the
    /// window is open, so this never means "closed".
    case noTree
}

/// Why a `ui.tree` read produced nothing. The tool turns these into one human
/// sentence, never a silence.
enum UITreeError: Error, Equatable {
    case notConnected
    case timedOut

    /// The tool's answer for this failure: one sentence, never a silence (F8).
    var sentence: String {
        switch self {
        case .notConnected: "No phone is connected."
        case .timedOut: "The phone did not answer the accessibility read in time."
        }
    }
}

/// The `tap` tool's refusals as human sentences (WIN-79). Kept here, not in the
/// tool layer, so the unit tests assert the exact words.
enum UITreeRefusal {
    static func stale(ref: String, snapshot: Int, latest: Int) -> String {
        // A ref from an older read names both reads. One the latest read never
        // had (a made-up row, or a ref with no snapshot such as "e5") must not
        // claim it came from a snapshot.
        if snapshot > 0, snapshot < latest {
            return "\(ref) is from snapshot s\(snapshot), but the window is at s\(latest). Call ui_tree again."
        }
        return "\(ref) is not in the window's latest tree (s\(latest)). Use a ref from that tree, or call ui_tree again."
    }
    /// The window is open (the tool checked) but has no tree to resolve against.
    static func noTree(_ ref: String) -> String {
        "\(ref) names nothing: this window has had no tree read since it opened or since the phone reconnected. Call ui_tree first."
    }
    static func offScreen(_ ref: String) -> String {
        "\(ref) is off screen: scroll it into view and read the tree again."
    }
}

/// The Mac's read lifecycle for `ui.tree` (WIN-79): pairs each read to its
/// reply by `seq` (PhoneReadQueue serializes reads, F6), remembers refs per window, and
/// answers `tap` by ref. Owned by the controller but a plain, main-actor type
/// so the unit tests drive the whole lifecycle without a socket.
@MainActor
final class UITreeBroker {
    /// How long a `ui.tree` read waits for the phone (WIN-79, MCP-70).
    nonisolated static let deadline: TimeInterval = 5

    private var seq = 0
    private var waiters: [Int: CheckedContinuation<UITree, Error>] = [:]
    private var refs = UITreeRefs()
    /// The label each client was last answered per window and key: the
    /// `expect` of its next press (MCP-86, #188).
    private var answered: [MCPClientID: [UInt32: [Int: String]]] = [:]

    /// A tree went to [client]: remember its labels for that client's presses.
    /// With [only], just those keys: a `find` answer showed the client only
    /// its matches, and a key it was not shown keeps the label it was (MCP-75).
    func answered(_ tree: UITree, client: MCPClientID?, only: Set<Int>? = nil) {
        guard let client, tree.ok else { return }
        let labels = tree.labels()
        var known = answered[client, default: [:]][tree.stream, default: [:]]
        for node in tree.nodes {
            guard let k = node.k, only?.contains(k) ?? true else { continue }
            known[k] = labels[k]  // a row with no label now drops the old one: no `expect`
        }
        answered[client, default: [:]][tree.stream] = known
    }

    /// The label [client] was last answered for key [k] on [stream]; nil when
    /// never (the press then sends no `expect`).
    func expect(client: MCPClientID?, stream: UInt32, k: Int) -> String? {
        guard let client else { return nil }
        return answered[client]?[stream]?[k]
    }

    /// Start a read. `send` carries the request out with the allocated `seq`;
    /// the reply arrives as [reply], the session's end as [fail], and a silent
    /// phone as the timeout.
    /// One read at a time is `PhoneReadQueue`'s job (F6, MCP-9): the caller
    /// runs this inside it.
    func read(stream: UInt32, timeout: TimeInterval, send: (Int) -> Void) async throws -> UITree {
        seq += 1
        let id = seq
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UITree, Error>) in
            waiters[id] = cont
            send(id)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                self?.finish(id: id, .failure(UITreeError.timedOut))
            }
        }
    }

    /// The phone's answer. A reply whose `seq` has no waiter — a late reply
    /// after a timeout — is ignored: it neither resolves a read nor replaces
    /// refs (F5).
    func reply(_ tree: UITree) {
        guard waiters[tree.seq] != nil else { return }
        var materialized = tree
        if tree.ok {
            let snapshot = refs.nextSnapshot(for: tree.stream)
            materialized = tree.assigning(snapshot: snapshot)
            refs.remember(materialized)
        } else {
            // F6: a failed read keeps the previous refs (remember is a no-op).
            refs.remember(tree)
        }
        finish(id: tree.seq, .success(materialized))
    }

    /// A closed session has no tree to answer with.
    func fail(_ error: UITreeError) {
        refs.forgetAll()
        answered.removeAll()
        let waiting = Array(waiters.values)
        waiters.removeAll()
        for waiter in waiting { waiter.resume(throwing: error) }
    }

    func forget(stream: UInt32) {
        refs.forget(stream: stream)
        for client in answered.keys { answered[client]?[stream] = nil }
    }

    /// An MCP connection closed: the labels it was answered are screen text
    /// and go with it (MCP-86). Other connections' labels stay.
    func forget(client: MCPClientID) {
        answered[client] = nil
    }

    func latestSnapshot(stream: UInt32) -> Int? { refs.latestSnapshot(for: stream) }

    /// The pixel space of the window's latest tree (MCP-50, MCP-63).
    func latestSize(stream: UInt32) -> [Int]? {
        refs.latestSize(for: stream)
    }

    func resolved(ref: String, stream: UInt32) -> UITreeResolution {
        refs.resolved(ref: ref, stream: stream)
    }

    /// The window's latest successful read (MCP-87, MCP-108).
    func latestTree(stream: UInt32) -> UITree? {
        refs.latestTree(for: stream)
    }

    private func finish(id: Int, _ result: Result<UITree, Error>) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.resume(with: result)
    }

}
