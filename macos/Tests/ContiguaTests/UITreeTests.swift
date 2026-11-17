// The Mac's half of `ui.tree` (WIN-79, ISS-160): parse the phone's trimmed
// accessibility tree, refuse a malformed one, issue refs from a per-window read
// counter, and write the tool result with only the fields the contract names.

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
               layers: [UITree.Layer(index: 0, title: "App", type: "app", focused: true, active: true)],
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
        guard case .press(_, let snapshot, _) = UITreeTapPlan(broker.resolved(ref: "e1", stream: 3), ref: "e1") else {
            return XCTFail("the latest ref must press")
        }
        XCTAssertEqual(snapshot, 2)
    }

    func test_WIN79_refsForgottenWhenWindowCloses() throws {
        var refs = UITreeRefs()
        refs.remember(try XCTUnwrap(UITree(message: phoneReply())).assigning(snapshot: 1))
        refs.forget(stream: 3) // window.closed
        XCTAssertEqual(refs.resolved(ref: "e1", stream: 3), .noTree)
        XCTAssertEqual(UITreeTapPlan(refs.resolved(ref: "e1", stream: 3), ref: "e1"),
                       .refuse(UITreeRefusal.noTree("e1")))
        // The sentence names the ref and the next step (the tool answers "no
        // such window" before this for a window that is really gone).
        XCTAssertTrue(UITreeRefusal.noTree("e1").contains("e1"))
        XCTAssertTrue(UITreeRefusal.noTree("e1").contains("Call ui_tree first."))
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
        let plan = UITreeTapPlan(refs.resolved(ref: "e1", stream: stream), ref: "e1")
        XCTAssertEqual(plan, .refuse(UITreeRefusal.noTree("e1")))
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
        XCTAssertEqual(UITreeTapPlan(refs.resolved(ref: "e12", stream: 3), ref: "e12"),
                       .refuse("e12 is off screen: scroll it into view and read the tree again."))
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
        _ = try await read.value
        broker.fail(.notConnected) // the session ended; the window stays open
        guard case .refuse(let sentence) = UITreeTapPlan(broker.resolved(ref: "e1", stream: 3), ref: "e1") else {
            return XCTFail("a ref from before the reconnect must press nothing")
        }
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
}
