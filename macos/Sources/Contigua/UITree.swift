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
        let focused: Bool
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
    /// The Mac's per-window read counter; nil until [assigning] fills it.
    let snapshot: Int?
    /// The pixel space `box` is in, `[w, h]` (S2).
    let size: [Int]?
    let truncated: Bool
    let layers: [Layer]
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
        self.snapshot = nil
        let rawSize = message.raw["size"] as? [NSNumber]
        self.size = rawSize?.count == 2 ? rawSize!.map(\.intValue) : nil
        self.truncated = message.bool("truncated") ?? false
        self.note = message.string("note")
        self.layers = (message.array("layers") ?? []).enumerated().compactMap { index, raw in
            guard let type = raw["type"] as? String else { return nil }
            return Layer(index: raw["i"] as? Int ?? index,
                         title: raw["title"] as? String,
                         type: type,
                         focused: raw["focused"] as? Bool ?? false,
                         active: raw["active"] as? Bool ?? false)
        }
        self.nodes = (message.array("nodes") ?? []).compactMap { raw in
            guard let role = raw["role"] as? String, let index = raw["i"] as? Int else { return nil }
            let at = (raw["at"] as? [NSNumber]).flatMap { values -> Point? in
                guard values.count == 2 else { return nil }
                return Point(x: values[0].doubleValue, y: values[1].doubleValue)
            }
            return Node(index: index,
                        ref: "",
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
                        password: raw["pwd"] as? Bool ?? false)
        }
    }

    init(seq: Int, stream: UInt32, ok: Bool, code: String?, message: String?,
         displayId: Int?, snapshot: Int?, size: [Int]?, truncated: Bool,
         layers: [Layer], nodes: [Node], note: String?) {
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
    }

    /// The same tree with the Mac's read counter [snapshot] and every node's
    /// ref named `s<snapshot>e<row>` (S1).
    func assigning(snapshot: Int) -> UITree {
        UITree(seq: seq, stream: stream, ok: ok, code: code, message: message,
               displayId: displayId, snapshot: snapshot, size: size,
               truncated: truncated, layers: layers,
               nodes: nodes.map { node in
                   var named = node
                   named.ref = "s\(snapshot)e\(node.index)"
                   return named
               },
               note: note)
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
                let focused: Bool
                let active: Bool
            }

            struct Node: Encodable {
                let i: Int
                let ref: String
                let p: Int?
                let l: Int?
                let role: String
                let text: String?
                let desc: String?
                let id: String?
                let box: [Int]?
                let at: [Double]?
                let off: Bool?
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
            let size: [Int]?
            let truncated: Bool
            let layers: [Layer]
            let nodes: [Node]
            let note: String?
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
                          focused: $0.focused, active: $0.active)
            },
            nodes: nodes.map { node in
                Out.Node(i: node.index, ref: node.ref, p: node.parent,
                         l: severalLayers ? node.layer : nil,
                         role: node.role, text: node.text, desc: node.desc, id: node.id,
                         box: node.box, at: node.at.map { [$0.x, $0.y] },
                         off: node.off ? true : nil,
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
    }

    private var reads: [UInt32: Read] = [:]
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
        reads[tree.stream] = Read(snapshot: snapshot, nodes: nodes)
    }

    /// Forget a window's refs and counter: on close, or when a stream id is
    /// reused (F4).
    mutating func forget(stream: UInt32) {
        reads[stream] = nil
        counters[stream] = nil
    }

    /// Drop every window's refs, but keep the counters (a reconnect keeps the
    /// read count, S1).
    mutating func forgetAll() {
        reads.removeAll()
    }

    func resolved(ref: String, stream: UInt32) -> UITreeResolution {
        guard let read = reads[stream] else { return .windowClosed }
        guard let placed = read.nodes[ref] else {
            return .stale(ref: ref, snapshot: Self.snapshot(in: ref), latest: read.snapshot)
        }
        return .placed(snapshot: read.snapshot, placed: placed)
    }

    func latestSnapshot(for stream: UInt32) -> Int? { reads[stream]?.snapshot }

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
    /// No tree for this window: it closed, or was never read (F4).
    case windowClosed
}

/// Why a `ui.tree` read produced nothing. The tool turns these into one human
/// sentence, never a silence.
enum UITreeError: Error, Equatable {
    case notConnected
    case timedOut
}

/// The `tap` tool's refusals as human sentences (WIN-79). Kept here, not in the
/// tool layer, so the unit tests assert the exact words.
enum UITreeRefusal {
    static func stale(ref: String, snapshot: Int, latest: Int) -> String {
        "\(ref) is from snapshot s\(snapshot), but the window is at s\(latest). Call ui_tree again."
    }
    static var windowClosed: String { "That window closed. Call ui_tree again." }
    static func offScreen(_ ref: String) -> String {
        "\(ref) is off screen: scroll it into view and read the tree again."
    }
}

/// The Mac's read lifecycle for `ui.tree` (WIN-79): pairs each read to its
/// reply by `seq`, serializes reads (F6), remembers refs per window, and
/// answers `tap` by ref. Owned by the controller but a plain, main-actor type
/// so the unit tests drive the whole lifecycle without a socket.
@MainActor
final class UITreeBroker {
    private var seq = 0
    private var waiters: [Int: CheckedContinuation<UITree, Error>] = [:]
    private var refs = UITreeRefs()
    /// F6: one read at a time; a second read waits for the first.
    private var reading = false
    private var queue: [CheckedContinuation<Void, Never>] = []

    /// Start a read. `send` carries the request out with the allocated `seq`;
    /// the reply arrives as [reply], the session's end as [fail], and a silent
    /// phone as the timeout.
    func read(stream: UInt32, timeout: TimeInterval, send: (Int) -> Void) async throws -> UITree {
        if reading {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                queue.append(cont)
            }
        }
        reading = true
        defer { releaseRead() }
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
        let waiting = Array(waiters.values)
        waiters.removeAll()
        for waiter in waiting { waiter.resume(throwing: error) }
    }

    func forget(stream: UInt32) { refs.forget(stream: stream) }

    func resolved(ref: String, stream: UInt32) -> UITreeResolution {
        refs.resolved(ref: ref, stream: stream)
    }

    private func finish(id: Int, _ result: Result<UITree, Error>) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.resume(with: result)
    }

    private func releaseRead() {
        if let next = queue.first {
            queue.removeFirst()
            next.resume()
        } else {
            reading = false
        }
    }
}
