// The Mac's half of `ui.tree` (WIN-79, ISS-160): parse the phone's trimmed
// accessibility tree, refuse a malformed one, issue refs from a per-window read
// counter, and write the tool result with only the fields the contract names.

import AppKit
import XCTest
@testable import Contigua

final class UITreeTests: XCTestCase {

    private func message(_ raw: [String: Any]) -> JSONMessage { JSONMessage(raw: raw) }

    /// A reply shaped like the phone's: one app layer, a label and a button.
    /// No `ref` and no `snapshot`: the Mac issues both (S1).
    private func phoneReply(stream: Int = 3, seq: Int = 9, extra: [String: Any] = [:]) -> JSONMessage {
        var raw: [String: Any] = [
            "t": "ui.tree",
            "stream": stream,
            "seq": seq,
            "ok": true,
            "displayId": 47,
            "size": [1_440, 3_120],
            "truncated": false,
            "layers": [
                ["i": 0, "title": "Calculator", "type": "app", "focused": true, "active": true],
            ],
            "nodes": [
                ["i": 0, "k": 5, "l": 0, "role": "TextView", "text": "42 + 1",
                 "box": [100, 200, 500, 400], "at": [0.3, 0.15]],
                ["i": 1, "k": 1, "l": 0, "role": "Button", "text": "Equals",
                 "id": "equals", "box": [540, 640, 780, 760], "at": [0.66, 0.35], "click": true],
            ],
        ]
        for (key, value) in extra { raw[key] = value }
        return message(raw)
    }

    private func failedReply(stream: Int = 3, seq: Int = 9) -> UITree {
        UITree(seq: seq, stream: UInt32(stream), ok: false, code: "no_a11y",
               message: "This phone cannot read an accessibility tree right now.",
               displayId: nil, snapshot: nil, size: nil, truncated: false,
               layers: [], nodes: [], note: nil)
    }

    private func okTree(stream: UInt32, seq: Int) -> UITree {
        UITree(seq: seq, stream: stream, ok: true, code: nil, message: nil,
               displayId: 47, snapshot: nil, size: nil, truncated: false,
               layers: [UITree.Layer(index: 0, title: "App", type: "app", active: true)],
               nodes: [UITree.Node(index: 0, ref: "", parent: nil, layer: 0, role: "Button",
                                   text: "X", desc: nil, id: nil, box: [0, 0, 10, 10],
                                   at: UITree.Point(x: 0.5, y: 0.5), off: false,
                                   click: true, edit: false, scroll: false, check: nil,
                                   selected: false, focused: false, disabled: false, password: false)],
               note: nil)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000) // real-time: bounded poll for a reply's actor hop
        }
    }

    // MARK: Parsing (new shape)

    func testAPhoneReplyParsesIntoLayersAndNodes() throws {
        let tree = try XCTUnwrap(UITree(message: phoneReply()))
        XCTAssertEqual(tree.seq, 9)
        XCTAssertEqual(tree.stream, 3)
        XCTAssertTrue(tree.ok)
        XCTAssertEqual(tree.displayId, 47)
        XCTAssertEqual(tree.size, [1_440, 3_120])
        XCTAssertFalse(tree.truncated)
        XCTAssertEqual(tree.layers.count, 1)
        XCTAssertEqual(tree.layers[0].title, "Calculator")
        XCTAssertEqual(tree.nodes.count, 2)
        XCTAssertEqual(tree.nodes[1].role, "Button")
        XCTAssertEqual(tree.nodes[1].id, "equals")
        XCTAssertEqual(tree.nodes[1].box, [540, 640, 780, 760])
        XCTAssertEqual(tree.nodes[1].at, UITree.Point(x: 0.66, y: 0.35))
        XCTAssertTrue(tree.nodes[1].click)
        XCTAssertFalse(tree.nodes[1].off)
    }

    func testAFailedReadCarriesItsCodeAndSentence() throws {
        let tree = failedReply()
        XCTAssertFalse(tree.ok)
        XCTAssertEqual(tree.code, "no_a11y")
        XCTAssertEqual(tree.message, "This phone cannot read an accessibility tree right now.")
        XCTAssertTrue(tree.nodes.isEmpty)
    }

    func testAMessageWithoutOkIsNotATree() {
        XCTAssertNil(UITree(message: message(["t": "ui.tree", "stream": 3, "seq": 9])))
        XCTAssertNil(UITree(message: message(["t": "ui.tree", "ok": true, "seq": 9])))
    }

    func testANodeWithoutARoleOrIndexIsDropped() throws {
        let raw: [String: Any] = [
            "t": "ui.tree", "stream": 3, "seq": 1, "ok": true,
            "nodes": [
                ["i": 0, "l": 0, "role": "Button", "text": "Save"],
                ["l": 0, "role": "TextView", "text": "no index"],
                ["i": 2, "l": 0, "text": "no role"],
            ],
        ]
        let tree = try XCTUnwrap(UITree(message: message(raw)))
        XCTAssertEqual(tree.nodes.map(\.role), ["Button"])
    }

    func testAnOffScreenNodeIsParsed() throws {
        let raw: [String: Any] = [
            "t": "ui.tree", "stream": 3, "seq": 1, "ok": true,
            "nodes": [["i": 0, "l": 0, "role": "Button", "text": "Checkout",
                       "box": [0, 2_500, 100, 2_600], "off": true]],
        ]
        let tree = try XCTUnwrap(UITree(message: message(raw)))
        XCTAssertTrue(tree.nodes[0].off)
        XCTAssertNil(tree.nodes[0].at)
    }

    // MARK: Encoding

    func testTheResultCarriesOnlyTheContractsFields() throws {
        let tree = try XCTUnwrap(UITree(message: phoneReply(extra: [
            "secret": "not in the contract",
        ]))).assigning(snapshot: 12)
        let text = tree.encoded()
        XCTAssertFalse(text.contains("secret"))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["window"] as? Int, 3)
        XCTAssertEqual(object["displayId"] as? Int, 47)
        XCTAssertEqual(object["snapshot"] as? Int, 12)
        XCTAssertEqual(object["size"] as? [Int], [1_440, 3_120])
        XCTAssertEqual(object["truncated"] as? Bool, false)
        let nodes = try XCTUnwrap(object["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes[1]["text"] as? String, "Equals")
        XCTAssertEqual(nodes[1]["at"] as? [Double], [0.66, 0.35])
        XCTAssertEqual(nodes[1]["ref"] as? String, "e1")
        XCTAssertNil(nodes[1]["off"])
    }

    func testTheLayerIndexIsLeftOutWhenThereIsOneLayer() throws {
        let one = try XCTUnwrap(UITree(message: phoneReply())).assigning(snapshot: 1)
        let oneNodes = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(one.encoded().utf8)) as? [String: Any])["nodes"]
            as? [[String: Any]]
        XCTAssertNotNil(oneNodes)
        XCTAssertTrue(oneNodes?.allSatisfy { $0["l"] == nil } ?? false,
                      "one layer: every row would repeat the same 0")
        // Two layers: the index is the only thing that says whose row it is.
        var raw = phoneReply().raw
        raw["layers"] = [
            ["i": 0, "title": "Calculator", "type": "app", "focused": true, "active": true],
            ["i": 1, "title": "Keyboard", "type": "ime", "focused": false, "active": false],
        ]
        let two = try XCTUnwrap(UITree(message: JSONMessage(raw: raw))).assigning(snapshot: 1)
        XCTAssertTrue(two.encoded().contains("\"l\":0"))
    }

    func testATapPointIsPrintedAtThreeDecimals() throws {
        // Foundation's JSON writer prints 0.949 as 0.94899999999999995; a tree
        // read on a real screen carried that noise on every row.
        var raw = phoneReply().raw
        raw["nodes"] = [["i": 0, "l": 0, "role": "Button", "text": "Buy",
                         "box": [0, 0, 10, 10], "at": [0.949, 0.123]]]
        let tree = try XCTUnwrap(UITree(message: JSONMessage(raw: raw))).assigning(snapshot: 1)
        let text = tree.encoded()
        XCTAssertTrue(text.contains("0.949"), text)
        XCTAssertTrue(text.contains("0.123"), text)
        XCTAssertFalse(text.contains("0.94899"), text)
    }

    func testAnEmptyTreeKeepsItsNote() throws {
        let raw: [String: Any] = [
            "t": "ui.tree", "stream": 3, "seq": 1, "ok": true, "truncated": false,
            "nodes": [], "note": "This display has no accessible content.",
        ]
        let tree = try XCTUnwrap(UITree(message: message(raw)))
        XCTAssertTrue(tree.encoded().contains("no accessible content"))
    }

    func testDefaultsAreNotInvented() throws {
        let raw: [String: Any] = [
            "t": "ui.tree", "stream": 3, "seq": 1, "ok": true,
            "nodes": [["i": 0, "l": 0, "role": "TextView", "text": "plain"]],
        ]
        let tree = try XCTUnwrap(UITree(message: message(raw))).assigning(snapshot: 1)
        let text = tree.encoded()
        XCTAssertFalse(text.contains("\"click\""))
        XCTAssertFalse(text.contains("\"disabled\""))
        XCTAssertFalse(text.contains("\"check\""))
        XCTAssertFalse(text.contains("\"off\""))
    }

    func testAnUncheckedBoxKeepsItsFalse() throws {
        let raw: [String: Any] = [
            "t": "ui.tree", "stream": 3, "seq": 1, "ok": true,
            "nodes": [["i": 0, "l": 0, "role": "CheckBox", "text": "Wi-Fi", "check": false]],
        ]
        let tree = try XCTUnwrap(UITree(message: message(raw)))
        XCTAssertEqual(tree.nodes[0].check, false)
        XCTAssertTrue(tree.encoded().contains("\"check\":false"))
    }

    // MARK: Refs (S1, F1, F4, F6, F9)

    /// MCP-103: the phone's loading signal reaches the client on the row and
    /// on the answer; a tree with none says nothing about loading.
    func testLoadingPassesThrough_MCP103() throws {
        let raw = phoneReply(extra: [
            "loading": true,
            "nodes": [["i": 0, "l": 0, "role": "ProgressBar", "loading": true,
                       "box": [500, 1000, 580, 1080], "at": [0.5, 0.5]]],
        ])
        let tree = try XCTUnwrap(UITree(message: raw)).assigning(snapshot: 1)
        XCTAssertTrue(tree.loading)
        XCTAssertTrue(tree.nodes[0].loading)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tree.encoded().utf8)) as? [String: Any])
        XCTAssertEqual(encoded["loading"] as? Bool, true)
        let row = try XCTUnwrap((encoded["nodes"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["loading"] as? Bool, true)

        let quiet = try XCTUnwrap(UITree(message: phoneReply())).assigning(snapshot: 2)
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(quiet.encoded().utf8)) as? [String: Any])
        XCTAssertNil(plain["loading"])
        XCTAssertNil((plain["nodes"] as? [[String: Any]])?.first?["loading"])
    }

    func test_WIN79_refsCarryTheirSnapshot() throws {
        let tree = try XCTUnwrap(UITree(message: phoneReply())).assigning(snapshot: 13)
        XCTAssertEqual(tree.snapshot, 13)
        // T10 (MCP-71): refs are the phone's keys; the snapshot stays on the answer.
        XCTAssertEqual(tree.nodes.map(\.ref), ["e5", "e1"])
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(tree.encoded().utf8)) as? [String: Any])
        XCTAssertEqual(object["snapshot"] as? Int, 13)
    }

    @MainActor
    func test_WIN79_aKeyResolvesInTheLatestRead() async throws {
        // Two reads of one window; key 1 exists in both (T10, MCP-71: refs
        // survive reads, so the older read's ref is the latest's too).
        let broker = UITreeBroker()
        for _ in 0..<2 {
            var seq = 0
            let read = Task { try await broker.read(stream: 3, timeout: 5, send: { seq = $0 }) }
            await waitUntil { seq != 0 }
            broker.reply(try XCTUnwrap(UITree(message: phoneReply(seq: seq))))
            _ = try await read.value
        }
        // What `tap` reads: the key, the latest snapshot, the row by key.
        XCTAssertEqual(MCPHostActEnvironment.key("e1"), 1)
        XCTAssertEqual(broker.latestSnapshot(stream: 3), 2)
        let row = try XCTUnwrap(broker.latestTree(stream: 3)?.nodes.first { $0.k == 1 })
        XCTAssertEqual(row.ref, "e1")
        XCTAssertNotNil(row.at, "the latest read places the key on screen")
    }

    @MainActor
    func test_WIN79_refsForgottenWhenWindowCloses() async throws {
        let broker = UITreeBroker()
        let client = MCPClientID(1)
        var seq = 0
        let read = Task { try await broker.read(stream: 3, timeout: 5, send: { seq = $0 }) }
        await waitUntil { seq != 0 }
        broker.reply(try XCTUnwrap(UITree(message: phoneReply(seq: seq))))
        broker.answered(try await read.value, client: client)
        XCTAssertEqual(broker.expect(client: client, stream: 3, k: 1), "Equals")
        broker.forget(stream: 3) // window.closed
        // What `refusal()` and the press read: no snapshot, no tree, no label.
        XCTAssertNil(broker.latestSnapshot(stream: 3))
        XCTAssertNil(broker.latestTree(stream: 3))
        XCTAssertNil(broker.expect(client: client, stream: 3, k: 1))
        // The sentence names the ref and the next step (the tool answers "no
        // such window" before this for a window that is really gone).
        XCTAssertTrue(UITreeRefusal.noTree("e1").contains("e1"))
        XCTAssertTrue(UITreeRefusal.noTree("e1").contains("Call ui_tree first."))
    }

    /// #266 item 7: the Mac's own refusal before a press, as the pure
    /// decision `refusal()` makes: a point tap and a ref on a window with a
    /// tree go to the phone; a ref on a window with no tree read since it
    /// opened, or since the phone reconnected, is refused here with WIN-79's
    /// sentence and never claims the window closed ([WIN-79], MCP-86).
    func test_WIN79_theMacRefusesARefOnlyWithoutATree() throws {
        XCTAssertNil(MCPHostActEnvironment.refusal(ref: nil, window: 3, latestSnapshot: nil),
                     "a point tap has no ref to refuse")
        XCTAssertNil(MCPHostActEnvironment.refusal(ref: "e1", window: 3, latestSnapshot: 1),
                     "a window with a tree: the phone judges the ref")
        let refused = try XCTUnwrap(MCPHostActEnvironment.refusal(ref: "e1", window: 3, latestSnapshot: nil))
        XCTAssertEqual(refused.code, .staleRef)
        XCTAssertEqual(refused.message, UITreeRefusal.noTree("e1"))
        XCTAssertEqual(refused.extra["window"] as? Int, 3)
        XCTAssertEqual(refused.extra["ref"] as? String, "e1")
        XCTAssertFalse(refused.message.contains("closed"))
    }

    /// The same decision over the broker's lifecycle: refused before the
    /// first read, allowed after it, refused again once the session ended
    /// (a reconnect) or the window's refs were forgotten (window closed,
    /// its stream id reused) ([WIN-79]).
    @MainActor
    func test_WIN79_aRefIsRefusedBeforeTheFirstReadAndAfterAReconnect() async throws {
        let broker = UITreeBroker()
        func decide() -> MCPToolError? {
            MCPHostActEnvironment.refusal(ref: "e1", window: 3, latestSnapshot: broker.latestSnapshot(stream: 3))
        }
        func read() async throws {
            var seq = 0
            let task = Task { try await broker.read(stream: 3, timeout: 5, send: { seq = $0 }) }
            await waitUntil { seq != 0 }
            broker.reply(try XCTUnwrap(UITree(message: phoneReply(seq: seq))))
            _ = try await task.value
        }
        XCTAssertEqual(decide()?.code, .staleRef, "no tree since the window opened")
        try await read()
        XCTAssertNil(decide(), "a tree was read")
        broker.fail(.notConnected)
        XCTAssertEqual(decide()?.code, .staleRef, "no tree since the phone reconnected")
        try await read()
        XCTAssertNil(decide())
        broker.forget(stream: 3)
        XCTAssertEqual(decide()?.code, .staleRef, "the window's refs were forgotten")
    }

    @MainActor
    func test_WIN79_refsForgottenWhenStreamIdReused() throws {
        // The window manager hands stream 3 out again: the old window's ref
        // must not press on the new window.
        let fixture = MultiWindowFixture()
        let first = fixture.open()
        let stream = first.stream
        var refs = UITreeRefs()
        refs.remember(try XCTUnwrap(UITree(message: phoneReply(stream: Int(stream)))).assigning(snapshot: 1))
        // Only the allocation forgets here, so the test proves that hook.
        fixture.manager.onStreamAllocated = { refs.forget(stream: $0) }
        fixture.manager.resetForNextCheck(forgetPrefs: true)
        XCTAssertEqual(fixture.open().stream, stream, "the id is handed out again")
        // What `refusal()` reads: no snapshot and no tree, so it refuses with noTree.
        XCTAssertNil(refs.latestSnapshot(for: stream))
        XCTAssertNil(refs.latestTree(for: stream))
        XCTAssertEqual(refs.nextSnapshot(for: stream), 1, "a reused id starts its read count at 1")
    }

    func test_WIN79_failedReadKeepsPreviousRefs() throws {
        var refs = UITreeRefs()
        refs.remember(try XCTUnwrap(UITree(message: phoneReply())).assigning(snapshot: 1))
        refs.remember(failedReply(seq: 10))
        XCTAssertEqual(refs.resolved(ref: "e1", stream: 3),
                       .placed(snapshot: 1, placed: UITreeRefs.Placed(
                           point: UITree.Point(x: 0.66, y: 0.35),
                           box: [540, 640, 780, 760], off: false)))
    }

    func test_WIN79_offScreenRefIsRefused() throws {
        var refs = UITreeRefs()
        let raw: [String: Any] = [
            "t": "ui.tree", "stream": 3, "seq": 4, "ok": true,
            "nodes": [["i": 12, "k": 12, "l": 0, "role": "Button", "text": "Checkout", "off": true]],
        ]
        refs.remember(try XCTUnwrap(UITree(message: message(raw))).assigning(snapshot: 4))
        let row = try XCTUnwrap(refs.latestTree(for: 3)?.nodes.first { $0.k == 12 })
        XCTAssertTrue(row.off)
        XCTAssertNil(row.at)
        // The phone answers `off_screen` for it; the Mac's answer is F9's sentence.
        let error = MCPToolError.pressRefusal(code: "off_screen", ref: "e12", window: 3, latestSnapshot: 4,
                                              expect: nil, now: nil, coveredBy: nil)
        XCTAssertEqual(error.code, .offScreen)
        XCTAssertEqual(error.message, "e12 is off screen: scroll it into view and read the tree again.")
    }

    func testRefsAreRememberedUntilTheNextTree() throws {
        var refs = UITreeRefs()
        refs.remember(try XCTUnwrap(UITree(message: phoneReply())).assigning(snapshot: 12))
        XCTAssertEqual(refs.resolved(ref: "e1", stream: 3),
                       .placed(snapshot: 12, placed: UITreeRefs.Placed(
                           point: UITree.Point(x: 0.66, y: 0.35),
                           box: [540, 640, 780, 760], off: false)))
        XCTAssertEqual(refs.resolved(ref: "e9", stream: 3),
                       .stale(ref: "e9", snapshot: 0, latest: 12))
        XCTAssertEqual(refs.resolved(ref: "e1", stream: 4), .noTree,
                       "a ref belongs to its window")
        // A second tree replaces the first: the old names mean new elements.
        var moved = phoneReply()
        var raw = moved.raw
        raw["nodes"] = [["i": 0, "l": 0, "role": "Button", "text": "New",
                         "box": [0, 0, 10, 10], "at": [0.01, 0.01]]]
        moved = JSONMessage(raw: raw)
        refs.remember(try XCTUnwrap(UITree(message: moved)).assigning(snapshot: 13))
        XCTAssertEqual(refs.resolved(ref: "e1", stream: 3),
                       .stale(ref: "e1", snapshot: 0, latest: 13))
        refs.forget(stream: 3)
        XCTAssertEqual(refs.resolved(ref: "e1", stream: 3), .noTree)
    }

    func test_WIN79_aRefTheLatestTreeNeverHadSaysSo() {
        // A made-up row of the latest read, and a ref with no snapshot (the old
        // "e5" form), must not claim to come from a snapshot.
        for (ref, snapshot) in [("s12e9", 12), ("e5", 0)] {
            let sentence = UITreeRefusal.stale(ref: ref, snapshot: snapshot, latest: 12)
            XCTAssertEqual(sentence, "\(ref) is not in the window's latest tree (s12). Use a ref from that tree, or call ui_tree again.")
        }
        XCTAssertEqual(UITreeRefusal.stale(ref: "s3e1", snapshot: 3, latest: 12),
                       "s3e1 is from snapshot s3, but the window is at s12. Call ui_tree again.")
    }

    @MainActor
    func test_WIN79_aReconnectRefusesWithoutSayingTheWindowClosed() async throws {
        let broker = UITreeBroker()
        var seq = 0
        let read = Task { try await broker.read(stream: 3, timeout: 5, send: { seq = $0 }) }
        await waitUntil { seq != 0 }
        broker.reply(try XCTUnwrap(UITree(message: phoneReply(seq: seq))))
        broker.answered(try await read.value, client: MCPClientID(1))
        broker.fail(.notConnected) // the session ended; the window stays open
        // What `refusal()` reads: no snapshot, so it refuses with noTree.
        XCTAssertNil(broker.latestSnapshot(stream: 3), "a ref from before the reconnect must press nothing")
        XCTAssertNil(broker.expect(client: MCPClientID(1), stream: 3, k: 1))
        let sentence = UITreeRefusal.noTree("e1")
        XCTAssertTrue(sentence.contains("since the phone reconnected"), sentence)
        XCTAssertFalse(sentence.contains("closed"), sentence)
    }

    // MARK: The read lifecycle (F5, F6, F8)

    @MainActor
    func test_WIN79_lateReplyAfterTimeoutDoesNotReplaceRefs() async throws {
        let broker = UITreeBroker()
        // First read resolves normally: s1.
        var seq1 = 0
        let first = Task { try await broker.read(stream: 3, timeout: 5, send: { seq1 = $0 }) }
        await waitUntil { seq1 != 0 }
        broker.reply(try XCTUnwrap(UITree(message: phoneReply(seq: seq1))))
        _ = try await first.value

        // Second read times out (no reply).
        var seq2 = 0
        let second = Task { try await broker.read(stream: 3, timeout: 0.05, send: { seq2 = $0 }) }
        await waitUntil { seq2 != 0 }
        do {
            _ = try await second.value
            XCTFail("expected a timeout")
        } catch let error as UITreeError {
            XCTAssertEqual(error, .timedOut)
        }

        // The late reply must not replace the refs: s1 still answers, s2 does not.
        broker.reply(try XCTUnwrap(UITree(message: phoneReply(seq: seq2))))
        XCTAssertEqual(broker.resolved(ref: "e1", stream: 3),
                       .placed(snapshot: 1, placed: UITreeRefs.Placed(
                           point: UITree.Point(x: 0.66, y: 0.35),
                           box: [540, 640, 780, 760], off: false)))
        XCTAssertEqual(broker.latestSnapshot(stream: 3), 1, "the late reply is not a read")
    }

    @MainActor
    func test_WIN79_twoWindowsReadOneAfterTheOther() async throws {
        // F6 lives in PhoneReadQueue (MCP-9), which the controller reads through.
        let broker = UITreeBroker()
        let reads = PhoneReadQueue()
        var seq1 = 0
        var seq2 = 0
        let first = Task { try await reads.run { try await broker.read(stream: 1, timeout: 5, send: { seq1 = $0 }) } }
        await waitUntil { seq1 != 0 }
        let second = Task { try await reads.run { try await broker.read(stream: 2, timeout: 5, send: { seq2 = $0 }) } }
        // The second read waits for the first instead of racing it (F6).
        try? await Task.sleep(nanoseconds: 20_000_000) // real-time: let a wrongly-racing second read run
        XCTAssertEqual(seq2, 0, "the second window's read must wait")
        broker.reply(okTree(stream: 1, seq: seq1))
        _ = try await first.value
        await waitUntil { seq2 != 0 }
        broker.reply(okTree(stream: 2, seq: seq2))
        let secondTree = try await second.value
        XCTAssertTrue(secondTree.ok)
    }

    @MainActor
    func test_WIN79_timeoutAnswersASentence() async {
        let broker = UITreeBroker()
        do {
            _ = try await broker.read(stream: 3, timeout: 0.05, send: { _ in })
            XCTFail("expected a timeout")
        } catch let error as UITreeError {
            XCTAssertEqual(error, .timedOut)
            XCTAssertEqual(error.sentence, "The phone did not answer the accessibility read in time.")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    @MainActor
    func test_WIN79_disconnectFailsPendingReads() async {
        let broker = UITreeBroker()
        let reads = PhoneReadQueue()
        var seq = 0
        var queuedSent = false
        let read = Task { try await reads.run { try await broker.read(stream: 3, timeout: 5, send: { seq = $0 }) } }
        await waitUntil { seq != 0 }
        // A second window's read queued behind the first (F6).
        let queued = Task { try await reads.run { try await broker.read(stream: 4, timeout: 5, send: { _ in queuedSent = true }) } }
        try? await Task.sleep(nanoseconds: 20_000_000) // real-time: let the queued read join the queue
        // The controller's session end fails both (failUITrees).
        reads.fail(UITreeError.notConnected)
        broker.fail(.notConnected)
        for task in [read, queued] {
            do {
                _ = try await task.value
                XCTFail("expected a failure")
            } catch let error as UITreeError {
                XCTAssertEqual(error, .notConnected)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(queuedSent, "a read queued behind an ended session is never sent")
    }

    func test_WIN79_staleRefSentence() {
        let sentence = UITreeRefusal.stale(ref: "s4e12", snapshot: 4, latest: 9)
        XCTAssertTrue(sentence.contains("s4"), sentence)
        XCTAssertTrue(sentence.contains("s9"), sentence)
        XCTAssertTrue(sentence.contains("ui_tree"), sentence)
    }

    // MARK: T10 — keys, heading, covered (MCP-71, MCP-72, MCP-73)

    func testHeadingAndCoveredPassThrough() throws {
        let raw: [String: Any] = [
            "t": "ui.tree", "stream": 3, "seq": 4, "ok": true,
            "nodes": [
                ["i": 0, "k": 8, "l": 0, "role": "TextView", "text": "Settings",
                 "box": [0, 0, 10, 10], "at": [0.5, 0.1], "heading": true, "covered": 9],
                ["i": 1, "k": 10, "l": 0, "role": "Button", "text": "Plain",
                 "box": [0, 20, 10, 30], "at": [0.5, 0.3]],
            ],
        ]
        let tree = try XCTUnwrap(UITree(message: message(raw))).assigning(snapshot: 1)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(tree.encoded().utf8)) as? [String: Any])
        let nodes = try XCTUnwrap(object["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes[0]["heading"] as? Bool, true)
        XCTAssertEqual(nodes[0]["covered"] as? String, "e9")
        XCTAssertNil(nodes[1]["heading"])
        XCTAssertNil(nodes[1]["covered"])
    }

    func testRefsAreTheKeys() throws {

        let raw: [String: Any] = [
            "t": "ui.tree", "stream": 3, "seq": 4, "ok": true,
            "nodes": [
                ["i": 0, "k": 12, "l": 0, "role": "Button", "text": "Pay",
                 "box": [0, 0, 10, 10], "at": [0.5, 0.1], "covered": 31],
                ["i": 1, "k": 31, "l": 0, "role": "ImageButton", "desc": "Close",
                 "box": [0, 0, 10, 10], "at": [0.5, 0.1]],
            ],
        ]
        let tree = try XCTUnwrap(UITree(message: message(raw))).assigning(snapshot: 6)
        XCTAssertEqual(tree.nodes.map(\.ref), ["e12", "e31"])
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(tree.encoded().utf8)) as? [String: Any])
        let nodes = try XCTUnwrap(object["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes[0]["ref"] as? String, "e12")
        XCTAssertEqual(nodes[0]["covered"] as? String, "e31")
        for node in nodes {
            let ref = node["ref"] as? String ?? ""
            XCTAssertNil(ref.range(of: #"^s\d+e\d+$"#, options: .regularExpression), ref)
        }
    }

    // MARK: Review: labels are linear, and no label is no expect (MCP-86)

    private func row(_ i: Int, k: Int?, p: Int?, text: String? = nil) -> UITree.Node {
        var node = UITree.Node(index: i, ref: k.map { "e\($0)" } ?? "", parent: p, layer: 0,
                               role: "View", text: text, desc: nil, id: nil, box: nil, at: nil,
                               off: false, click: false, edit: false, scroll: false, check: nil,
                               selected: false, focused: false, disabled: false, password: false)
        node.k = k
        return node
    }

    private func tree(_ nodes: [UITree.Node]) -> UITree {
        UITree(seq: 1, stream: 3, ok: true, code: nil, message: nil, displayId: 1, snapshot: 1,
               size: nil, truncated: false, layers: [], nodes: nodes, note: nil)
    }

    /// One deep chain of [count] rows in pre-order: the first [keyed] are
    /// keyed containers with no label, the last row is the only labelled one.
    private func chain(_ count: Int, keyed: Int) -> UITree {
        tree((0..<count).map { i in
            row(i, k: i < keyed ? i + 1 : nil, p: i == 0 ? nil : i - 1,
                text: i == count - 1 ? "Leaf" : nil)
        })
    }

    func testLabelsOfALargeTreeAreFast() {
        // A small chain first, against a tight bound: a quadratic labels()
        // fails here in seconds instead of holding the run on the big tree.
        let small = chain(150, keyed: 50)
        var started = Date()
        let smallLabels = small.labels()
        let smallSeconds = Date().timeIntervalSince(started)
        print("labels(): 150 rows in \(smallSeconds) s")
        XCTAssertLessThan(smallSeconds, 0.25)
        XCTAssertEqual(smallLabels.count, 50)
        guard smallSeconds < 0.25 else { return }
        // 1200 rows, 400 unlabelled keyed containers over one labelled leaf.
        let big = chain(1200, keyed: 400)
        started = Date()
        let labels = big.labels()
        let bigSeconds = Date().timeIntervalSince(started)
        print("labels(): 1200 rows in \(bigSeconds) s")
        XCTAssertLessThan(bigSeconds, 1.0)
        XCTAssertEqual(labels.count, 400)
        XCTAssertEqual(Set(labels.values), ["Leaf"])
    }

    func testAnUnlabelledRowTakesTheFirstLabelledRowUnderIt() {
        let labels = tree([
            row(0, k: 1, p: nil),                       // A
            row(1, k: 2, p: 0),                         //   B
            row(2, k: 3, p: 1, text: "Inner"),          //     first labelled under A
            row(3, k: 4, p: 0, text: "Later"),          //   a later child of A
            row(4, k: 5, p: nil),                       // C: no labelled row under it
            row(5, k: 6, p: nil),                       // D, C's sibling
            row(6, k: 7, p: 5, text: "Sibling's child"),
        ]).labels()
        XCTAssertEqual(labels[1], "Inner")
        XCTAssertEqual(labels[2], "Inner")
        XCTAssertNil(labels[5], "never a later sibling's child")
        XCTAssertEqual(labels[6], "Sibling's child")
    }

    @MainActor
    func testARowWithNoLabelSendsNoExpect() {
        let broker = UITreeBroker()
        let client = MCPClientID(1)
        broker.answered(tree([row(0, k: 1, p: nil), row(1, k: 2, p: nil, text: "Pay")]), client: client)
        XCTAssertNil(broker.expect(client: client, stream: 3, k: 1))
        XCTAssertEqual(broker.expect(client: client, stream: 3, k: 2), "Pay")
    }

    /// #266 item 9: the screen labels a connection was answered (its presses'
    /// `expect`s) are screen text: they go when that connection closes, and
    /// another connection's stay ([MCP-86]).
    @MainActor
    func testAClosedConnectionsLabelsAreDropped_MCP86() throws {
        _ = NSApplication.shared
        let profile = try XCTUnwrap(Profile(name: "unit-labels-\(UUID().uuidString.prefix(8).lowercased())"))
        let controller = ConnectionController(options: LaunchOptions.parse(["Contigua"]), profile: profile)
        defer {
            controller.shutdown()
            if let suite = profile.defaultsSuiteName { profile.defaults.removePersistentDomain(forName: suite) }
            try? FileManager.default.removeItem(at: profile.supportDirectoryUrl)
        }
        let gone = MCPClientID(1)
        let staying = MCPClientID(2)
        let pay = tree([row(0, k: 1, p: nil, text: "Pay")])
        controller.uiTreeAnswered(pay, client: gone)
        controller.uiTreeAnswered(pay, client: staying)
        XCTAssertEqual(controller.uiTreeExpect(client: gone, stream: 3, k: 1), "Pay")

        controller.mcp.onClientClosed?(gone)
        XCTAssertNil(controller.uiTreeExpect(client: gone, stream: 3, k: 1),
                     "a closed connection's screen labels outlived it")
        XCTAssertEqual(controller.uiTreeExpect(client: staying, stream: 3, k: 1), "Pay",
                       "another connection's labels went with it")
    }

    // [MCP-86] Item 7: an editable row's label is its desc, else its id, never its text.
    func testAnEditableRowsLabelIsNotItsText() {
        func field(_ i: Int, k: Int?, p: Int?, desc: String?, id: String?) -> UITree.Node {
            UITree.Node(index: i, ref: k.map { "e\($0)" } ?? "", parent: p, layer: 0, role: "EditText",
                        text: "milk", desc: desc, id: id, box: nil, at: nil, off: false, click: true,
                        edit: true, scroll: false, check: nil, selected: false, focused: false,
                        disabled: false, password: false, k: k)
        }
        let labels = tree([
            field(0, k: 1, p: nil, desc: nil, id: "search_box"),
            field(1, k: 2, p: nil, desc: "Search", id: "search_box"),
            field(2, k: 3, p: nil, desc: nil, id: nil),
            row(3, k: 4, p: nil),                                   // a container
            field(4, k: 5, p: 3, desc: "Note", id: nil),            //   its field contributes nothing
            row(5, k: 6, p: 3, text: "Shopping"),
        ]).labels()
        XCTAssertEqual(labels[1], "search_box")
        XCTAssertEqual(labels[2], "Search")
        XCTAssertNil(labels[3])
        XCTAssertEqual(labels[4], "Shopping")
        // Review A: a password field's row has no text or desc: its id labels it.
        var pw = field(0, k: 9, p: nil, desc: nil, id: "pw")
        pw = UITree.Node(index: 0, ref: "e9", parent: nil, layer: 0, role: "EditText", text: nil, desc: nil,
                         id: "pw", box: nil, at: nil, off: false, click: true, edit: true, scroll: false,
                         check: nil, selected: false, focused: false, disabled: false, password: true, k: 9)
        XCTAssertEqual(tree([pw]).labels()[9], "pw")
    }

    // MARK: B6, the tree says what it does not show (MCP-104…106)

    private func encodedObject(_ raw: [String: Any]) throws -> [String: Any] {
        let tree = try XCTUnwrap(UITree(message: message(raw))).assigning(snapshot: 1)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(tree.encoded().utf8)) as? [String: Any])
    }

    // [MCP-104]
    func testHintPassesThrough() throws {
        let object = try encodedObject([
            "t": "ui.tree", "stream": 3, "seq": 4, "ok": true,
            "nodes": [
                ["i": 0, "k": 2, "l": 0, "role": "EditText", "hint": true, "hintText": "Search products",
                 "box": [0, 0, 10, 10], "at": [0.5, 0.1], "edit": true],
                ["i": 1, "k": 3, "l": 0, "role": "EditText", "text": "milk",
                 "box": [0, 20, 10, 30], "at": [0.5, 0.3], "edit": true],
            ],
        ])
        let nodes = try XCTUnwrap(object["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes[0]["hint"] as? Bool, true)
        XCTAssertEqual(nodes[0]["hintText"] as? String, "Search products")
        XCTAssertNil(nodes[0]["text"])
        XCTAssertEqual(nodes[1]["text"] as? String, "milk")
        XCTAssertNil(nodes[1]["hint"])
        XCTAssertNil(nodes[1]["hintText"])
    }

    // [MCP-105]
    func testActivePassesThroughAndFocusedIsGone() throws {
        let object = try encodedObject([
            "t": "ui.tree", "stream": 3, "seq": 4, "ok": true,
            "layers": [
                // An old fake still sends `focused`: it is dropped.
                ["i": 0, "title": "Shop", "type": "app", "focused": true],
                ["i": 1, "title": "Keyboard", "type": "ime", "active": true],
            ],
            "nodes": [
                ["i": 0, "k": 2, "l": 1, "role": "EditText", "text": "milk",
                 "box": [0, 0, 10, 10], "at": [0.5, 0.1], "edit": true, "focus": true],
            ],
        ])
        let layers = try XCTUnwrap(object["layers"] as? [[String: Any]])
        XCTAssertEqual(layers.count, 2)
        XCTAssertTrue(layers.allSatisfy { $0["focused"] == nil })
        XCTAssertNil(layers[0]["active"])
        XCTAssertEqual(layers[1]["active"] as? Bool, true)
        let nodes = try XCTUnwrap(object["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes[0]["focus"] as? Bool, true)
    }

    // [MCP-106]
    // [MCP-75] [MCP-106] An off-screen row says which way it is; a plain read
    // never carries the field.
    func testWherePassesThroughOnAnOffScreenRow_MCP75() throws {
        let object = try encodedObject([
            "t": "ui.tree", "stream": 3, "seq": 4, "ok": true, "omitted": 1,
            "nodes": [
                ["i": 0, "k": 33, "l": 0, "role": "TextView", "text": "Row 50",
                 "off": true, "where": "below"],
                ["i": 1, "k": 34, "l": 0, "role": "TextView", "text": "Row 1",
                 "box": [0, 20, 10, 30], "at": [0.5, 0.1]],
            ],
        ])
        let nodes = try XCTUnwrap(object["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes[0]["where"] as? String, "below")
        XCTAssertNil(nodes[1]["where"], "an on-screen row has no where")
    }

    func testHiddenAndOmittedPassThrough() throws {
        let object = try encodedObject([
            "t": "ui.tree", "stream": 3, "seq": 4, "ok": true, "omitted": 115,
            "nodes": [
                ["i": 0, "k": 2, "l": 0, "role": "RecyclerView", "scroll": true,
                 "box": [0, 0, 10, 10], "at": [0.5, 0.5], "hidden": [3, 112]],
                ["i": 1, "k": 3, "p": 0, "l": 0, "role": "TextView", "text": "Item 4",
                 "box": [0, 0, 10, 2], "at": [0.5, 0.1]],
            ],
        ])
        XCTAssertEqual(object["omitted"] as? Int, 115)
        let nodes = try XCTUnwrap(object["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes[0]["hidden"] as? [Int], [3, 112])
        XCTAssertNil(nodes[1]["hidden"])
        let none = try encodedObject(["t": "ui.tree", "stream": 3, "seq": 4, "ok": true, "omitted": 0, "nodes": []])
        XCTAssertEqual(none["omitted"] as? Int, 0)
    }

    // [MCP-86] The label skips an off row: the phone, reading live nodes, does too.
    func testAnOffRowGivesNoLabel() {
        let item3 = UITree.Node(index: 1, ref: "e2", parent: 0, layer: 0,
                                role: "TextView", text: "Item 3", desc: nil, id: nil, box: nil, at: nil,
                                off: true, click: false, edit: false, scroll: false, check: nil,
                                selected: false, focused: false, disabled: false, password: false, k: 2)
        let labels = tree([
            row(0, k: 1, p: nil),
            item3,
            row(2, k: 3, p: 0, text: "Item 4"),
        ]).labels()
        XCTAssertEqual(labels[1], "Item 4")
        XCTAssertEqual(labels[3], "Item 4")
    }
}
