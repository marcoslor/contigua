// Reading less of a window (plan T9, #170): the text view of a tree (MCP-74),
// `find` over its nodes, the off-screen ones included (MCP-75, MCP-106), a hint
// read as a hint (MCP-104), and the arguments that ask for them.

import XCTest
@testable import Contigua

final class UITreeTextTests: XCTestCase {

    /// A phone's `ui.tree` reply holding [nodes], parsed as the Mac parses it.
    private func tree(_ nodes: [[String: Any]]) throws -> UITree {
        let raw: [String: Any] = ["t": "ui.tree", "stream": 3, "seq": 1, "ok": true,
                                  "displayId": 2, "size": [1080, 2340], "truncated": false,
                                  "layers": [["i": 0, "type": "app", "active": true]],
                                  "nodes": nodes]
        return try XCTUnwrap(UITree(message: JSONMessage(raw: raw)))
    }

    /// The tool's answer for [tree] before any filter: its encoded JSON.
    private func answer(_ tree: UITree) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tree.encoded().utf8)) as? [String: Any])
    }

    private func box(_ row: Int) -> [Int] { [0, row * 20, 1080, row * 20 + 20] }

    // MARK: The text view (MCP-74)

    // [MCP-74]
    func testTheTextViewReadsInOrderWithRefs() throws {
        let read = try tree([
            ["i": 0, "k": 3, "role": "TextView", "text": "Ada Lovelace", "heading": true,
             "box": box(1), "at": [0.5, 0.01]],
            ["i": 1, "k": 5, "role": "TextView", "text": "Born 1815", "box": box(2), "at": [0.5, 0.02]],
            ["i": 2, "k": 9, "role": "Button", "text": "Read more", "click": true,
             "box": box(3), "at": [0.5, 0.03]],
            ["i": 3, "k": 4, "role": "EditText", "pwd": true, "edit": true, "text": "hunter2",
             "box": box(4), "at": [0.5, 0.04]],
        ])
        XCTAssertEqual(UITreeText.text(read.nodes),
                       "# Ada Lovelace\nBorn 1815\nRead more [e9 Button]\n[e4 EditText edit pwd]")
    }

    // [MCP-74] A node with no label and nothing to do gives no line; a focused
    // field names its states after the role.
    func testTheTextViewSkipsUnlabelledLayoutAndNamesStates() throws {
        let read = try tree([
            ["i": 0, "k": 1, "role": "FrameLayout", "box": box(0), "at": [0.5, 0.0]],
            ["i": 1, "k": 12, "p": 0, "role": "Button", "desc": "Close", "click": true,
             "box": box(1), "at": [0.5, 0.01]],
            ["i": 2, "k": 4, "p": 0, "role": "EditText", "text": "milk", "edit": true, "focus": true,
             "box": box(2), "at": [0.5, 0.02]],
        ])
        XCTAssertEqual(UITreeText.text(read.nodes), "Close [e12 Button]\nmilk [e4 EditText edit focus]")
    }

    // [MCP-104] [MCP-106]
    func testAHintReadsAsAHint() throws {
        let read = try tree([
            ["i": 0, "k": 7, "role": "EditText", "hint": true, "hintText": "Search", "edit": true,
             "box": box(1), "at": [0.5, 0.01]],
            ["i": 1, "k": 20, "role": "RecyclerView", "scroll": true, "hidden": [0, 41],
             "box": box(2), "at": [0.5, 0.02]],
        ])
        XCTAssertEqual(UITreeText.text(read.nodes),
                       "Search (hint) [e7 EditText edit]\n[e20 RecyclerView scroll, 0 before, 41 after]")
    }

    // MARK: find (MCP-75, MCP-106)

    // [MCP-75]
    func testFindKeepsOnlyMatches() throws {
        var rows: [[String: Any]] = (0..<86).map { n in
            ["i": n, "k": 100 + n, "role": "TextView", "text": "Row \(n)", "box": box(n), "at": [0.5, 0.1]]
        }
        rows.insert(["i": 40, "k": 3, "role": "TextView", "text": "Ada Lovelace", "heading": true,
                     "box": box(40), "at": [0.5, 0.4]], at: 40)
        for n in 41..<rows.count { rows[n]["i"] = n }
        let read = try tree(rows)
        XCTAssertEqual(read.nodes.count, 87)

        let found = UITreeText.find("lovel", in: read.nodes)
        XCTAssertEqual(found.matched, 1)
        XCTAssertEqual(found.total, 87)
        let filtered = UITreeText.findAnswer(try answer(read), found)
        let nodes = try XCTUnwrap(filtered["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes.first?["ref"] as? String, "e3")
        XCTAssertEqual(nodes.first?["text"] as? String, "Ada Lovelace")
        XCTAssertEqual(filtered["matched"] as? Int, 1)
        XCTAssertEqual(filtered["total"] as? Int, 87)

        XCTAssertEqual(UITreeText.find("ADA", in: read.nodes).matched, 1, "case")

        let cafe = try tree([
            ["i": 0, "k": 1, "role": "TextView", "text": "Café", "box": box(0), "at": [0.5, 0.0]],
            ["i": 1, "k": 2, "role": "ImageButton", "desc": "Café menu", "click": true,
             "box": box(1), "at": [0.5, 0.01]],
            ["i": 2, "k": 5, "role": "Button", "id": "cafe_order", "click": true,
             "box": box(2), "at": [0.5, 0.02]],
            ["i": 3, "k": 6, "role": "TextView", "text": "Tea", "box": box(3), "at": [0.5, 0.03]],
        ])
        XCTAssertEqual(UITreeText.find("cafe", in: cafe.nodes).matched, 3,
                       "diacritics, over text, description and view id")

        let none = UITreeText.find("nowhere", in: read.nodes)
        let empty = UITreeText.findAnswer(try answer(read), none)
        XCTAssertEqual((empty["nodes"] as? [Any])?.count, 0)
        XCTAssertEqual(empty["matched"] as? Int, 0)
        XCTAssertEqual(empty["total"] as? Int, 87)
    }

    // [MCP-106] The pure half: an off-screen match names the scrollable that
    // holds it as `in`, and has no `at`.
    func testAnOffScreenMatchNamesItsScrollable() throws {
        let read = try tree([
            ["i": 0, "k": 1, "role": "FrameLayout", "box": box(0), "at": [0.5, 0.0]],
            ["i": 1, "k": 20, "p": 0, "role": "RecyclerView", "scroll": true,
             "box": box(1), "at": [0.5, 0.01]],
            ["i": 2, "k": 21, "p": 1, "role": "LinearLayout", "off": true],
            ["i": 3, "k": 33, "p": 2, "role": "TextView", "text": "Row 50", "off": true],
            ["i": 4, "k": 34, "p": 1, "role": "TextView", "text": "Row 1", "box": box(2), "at": [0.5, 0.02]],
            ["i": 5, "k": 35, "p": 0, "role": "TextView", "text": "Row 99", "off": true],
        ])
        let filtered = UITreeText.findAnswer(try answer(read), UITreeText.find("row", in: read.nodes))
        let nodes = try XCTUnwrap(filtered["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes.compactMap { $0["ref"] as? String }, ["e33", "e34", "e35"])
        XCTAssertEqual(nodes[0]["in"] as? String, "e20")
        XCTAssertNil(nodes[0]["at"])
        XCTAssertEqual(nodes[0]["off"] as? Bool, true)
        XCTAssertNil(nodes[1]["in"], "an on-screen match needs no swipe")
        XCTAssertNil(nodes[2]["in"], "no scrollable holds it")
    }

    // [MCP-106] Through the tool: `find` asks the phone with `offscreen: true`,
    // the match comes back `off` with no `at` and `in` the list's ref; a plain
    // `ui_tree` read does not ask for off-screen nodes.
    @MainActor
    func testFindReachesAnOffScreenNode() async throws {
        let fixture = try TypeTextFixture()
        defer { fixture.close() }
        let window = try await fixture.liveWindow()
        fixture.treeNodes = [
            ["i": 0, "k": 20, "role": "RecyclerView", "scroll": true,
             "box": [0, 200, 1080, 2000], "at": [0.5, 0.47]],
            ["i": 1, "k": 33, "p": 0, "role": "TextView", "text": "Row 50", "off": true],
        ]
        let (found, _) = await fixture.call("ui_tree", ["window": Int(window.stream), "find": "row 50"])
        XCTAssertEqual(found["isError"] as? Bool, false, "ui_tree failed: \(found)")
        let reads = fixture.sent("ui.tree")
        XCTAssertEqual(reads.count, 1, "one ui.tree: \(fixture.sentTypes())")
        XCTAssertEqual(reads.first?.bool("offscreen"), true, "find must ask for off-screen nodes")
        let structured = try XCTUnwrap(found["structuredContent"] as? [String: Any])
        let nodes = try XCTUnwrap(structured["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes.first?["ref"] as? String, "e33")
        XCTAssertEqual(nodes.first?["off"] as? Bool, true)
        XCTAssertNil(nodes.first?["at"])
        XCTAssertEqual(nodes.first?["in"] as? String, "e20")
        XCTAssertEqual(structured["matched"] as? Int, 1)
        XCTAssertEqual(structured["total"] as? Int, 2)

        let (plain, _) = await fixture.call("ui_tree", ["window": Int(window.stream)])
        XCTAssertEqual(plain["isError"] as? Bool, false, "ui_tree failed: \(plain)")
        let plainReads = fixture.sent("ui.tree")
        XCTAssertEqual(plainReads.count, 1)
        XCTAssertNil(plainReads.first?.raw["offscreen"], "a plain read must not ask for off-screen nodes")
    }

    // [MCP-75] `where` rides right after `off` in the bracket; without it
    // the bracket is what it was.
    func testAnOffScreenBracketNamesWhere_MCP75() throws {
        let read = try tree([
            ["i": 0, "k": 20, "role": "RecyclerView", "scroll": true,
             "box": [0, 200, 1080, 2000], "at": [0.5, 0.47]],
            ["i": 1, "k": 33, "p": 0, "role": "TextView", "text": "Row 50",
             "off": true, "where": "below"],
            ["i": 2, "k": 34, "p": 0, "role": "TextView", "text": "Row 99",
             "off": true, "where": "hidden"],
            ["i": 3, "k": 35, "p": 0, "role": "TextView", "text": "Row 7", "off": true],
        ])
        XCTAssertEqual(UITreeText.text(read.nodes, within: [1: "e20", 2: "e20", 3: "e20"]),
                       "[e20 RecyclerView scroll]\nRow 50 [e33 TextView off below, in e20]\n"
                       + "Row 99 [e34 TextView off hidden, in e20]\nRow 7 [e35 TextView off, in e20]")
    }

    // [MCP-75] `find` with `format: "text"`: the text view of the matches only,
    // an off-screen one bracketed `off, in <the list's ref>`.
    @MainActor
    func testFindWithTheTextFormatReadsOnlyTheMatches() async throws {
        let fixture = try TypeTextFixture()
        defer { fixture.close() }
        let window = try await fixture.liveWindow()
        fixture.treeNodes = [
            ["i": 0, "k": 20, "role": "RecyclerView", "scroll": true,
             "box": [0, 200, 1080, 2000], "at": [0.5, 0.47]],
            ["i": 1, "k": 31, "p": 0, "role": "TextView", "text": "Other",
             "box": [0, 200, 1080, 300], "at": [0.5, 0.1]],
            ["i": 2, "k": 33, "p": 0, "role": "TextView", "text": "Row 50", "off": true],
        ]
        let (answer, _) = await fixture.call("ui_tree", ["window": Int(window.stream),
                                                         "find": "row 50", "format": "text"])
        XCTAssertEqual(answer["isError"] as? Bool, false, "ui_tree failed: \(answer)")
        let structured = try XCTUnwrap(answer["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["text"] as? String, "Row 50 [e33 TextView off, in e20]")
        XCTAssertNil(structured["nodes"])
        XCTAssertEqual(structured["matched"] as? Int, 1)
        XCTAssertEqual(structured["total"] as? Int, 3)
        XCTAssertEqual(fixture.sent("ui.tree").first?.bool("offscreen"), true)
    }

    // [MCP-74] Through the tool: `format: "text"` answers `text` and no nodes.
    @MainActor
    func testTheTextFormatAnswersText() async throws {
        let fixture = try TypeTextFixture()
        defer { fixture.close() }
        let window = try await fixture.liveWindow()
        fixture.treeNodes = [
            ["i": 0, "k": 2, "role": "Button", "text": "Continue", "click": true,
             "box": [100, 1400, 980, 1600], "at": [0.5, 0.64]],
        ]
        let (answer, _) = await fixture.call("ui_tree", ["window": Int(window.stream), "format": "text"])
        XCTAssertEqual(answer["isError"] as? Bool, false, "ui_tree failed: \(answer)")
        let structured = try XCTUnwrap(answer["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["format"] as? String, "text")
        XCTAssertEqual(structured["text"] as? String, "Continue [e2 Button]")
        XCTAssertNil(structured["nodes"])
        XCTAssertEqual(structured["window"] as? Int, Int(window.stream))
        XCTAssertNotNil(structured["snapshot"] as? Int)
        XCTAssertNotNil(structured["state"] as? String)
        XCTAssertNil(fixture.sent("ui.tree").first?.raw["offscreen"])
    }

    // MARK: Arguments

    // [MCP-34] [MCP-74] [MCP-75]
    func testTheReadLessArgumentsParse() throws {
        XCTAssertEqual(try MCPArguments.call("list_apps", [:]), .listApps())
        XCTAssertEqual(try MCPArguments.call("list_apps", ["query": "calc", "limit": 5]),
                       .listApps(query: "calc", limit: 5))
        XCTAssertThrowsError(try MCPArguments.call("list_apps", ["limit": 0]))
        XCTAssertThrowsError(try MCPArguments.call("list_apps", ["limit": 501]))
        XCTAssertThrowsError(try MCPArguments.call("list_apps", ["query": ""]))
        XCTAssertEqual(try MCPArguments.call("ui_tree", ["window": 3, "format": "text"]),
                       .uiTree(window: 3, format: .text))
        XCTAssertEqual(try MCPArguments.call("ui_tree", ["window": 3, "find": "Ada"]),
                       .uiTree(window: 3, find: "Ada"))
        XCTAssertEqual(try MCPArguments.call("ui_tree", ["window": 3]),
                       .uiTree(window: 3, format: .tree, find: nil))
        XCTAssertThrowsError(try MCPArguments.call("ui_tree", ["window": 3, "format": "xml"]))
        XCTAssertThrowsError(try MCPArguments.call("ui_tree", ["window": 3, "find": ""]))
    }

    // MARK: observe: "text" (MCP-82)

    // [MCP-82] Every tool that observes takes `text`.
    func testObserveTakesText() throws {
        XCTAssertEqual(try MCPArguments.call("tap", ["window": 3, "x": 0.5, "y": 0.5, "observe": "text"]),
                       .tap(window: 3, x: 0.5, y: 0.5, observe: .text))
        XCTAssertEqual(try MCPArguments.call("press_key", ["window": 3, "key": "back", "observe": "text"]),
                       .pressKey(window: 3, key: .back, observe: .text))
        XCTAssertEqual(try MCPArguments.call("wait", ["window": 3, "ms": 10, "observe": "text"]),
                       .wait(window: 3, mode: .clock(ms: 10), timeoutMs: 10000, observe: .text))
        XCTAssertEqual(try MCPArguments.call("open_app", ["app": "Shop", "observe": "text"]),
                       .openApp("Shop", newWindow: false, observe: .text))
    }

    // [MCP-82] A text observe reads the tree after the settle, as a tree observe does.
    func testObserveTextReadsAfterTheSettle() {
        var machine = MCPActMachine(path: .input, wait: .none, observe: .text)
        var actions: [MCPActMachine.Action]
        (machine, actions) = MCPActMachine.step(machine, .turn(.live))
        XCTAssertEqual(actions, [.sendInput])
        (machine, actions) = MCPActMachine.step(machine, .inputSent)
        XCTAssertEqual(actions, [.sendTree(req: 1)])
        (machine, actions) = MCPActMachine.step(machine, .treeReply(req: 1, "{}"))
        XCTAssertEqual(actions, [.answer(MCPActMachine.Answer(settle: MCPActMachine.Settle(state: "not_waited"),
                                                              tree: "{}"))])
    }

    // [MCP-82] [MCP-74] The act, open and wait answers carry the text view
    // as `text`, in place of `tree`.
    func testObserveTextCarriesTheTextView() throws {
        let read = try tree([
            ["i": 0, "k": 2, "role": "Button", "text": "Continue", "click": true,
             "box": box(1), "at": [0.5, 0.01]],
        ])
        let result = MCPActMachine.Answer(settle: MCPActMachine.Settle(state: "settled", waitedMs: 300),
                                          tree: read.encoded())
        let text = MCPActEnvelope.answer(window: 3, did: MCPActDid.key("back"), frameAtInput: 1,
                                         result: result, observe: .text)
        XCTAssertEqual(text["text"] as? String, "Continue [e2 Button]")
        XCTAssertNil(text["tree"])
        let nodes = MCPActEnvelope.answer(window: 3, did: MCPActDid.key("back"), frameAtInput: 1,
                                          result: result, observe: .tree)
        XCTAssertNotNil(nodes["tree"] as? [String: Any])
        XCTAssertNil(nodes["text"])

        let opened = MCPOpenAnswer.answer(window: 3, kind: .app, package: "com.example.shop", label: "Shop",
                                          opened: .new, openedBy: "you", size: [1080, 2340], result: result,
                                          observe: .text)
        XCTAssertEqual(opened["text"] as? String, "Continue [e2 Button]")
        XCTAssertNil(opened["tree"])

        var waited = MCPWaitAnswer(waitedMs: 10)
        waited.observed(try answer(read), .text)
        XCTAssertEqual(waited.object(window: 3)["text"] as? String, "Continue [e2 Button]")
        XCTAssertNil(waited.object(window: 3)["tree"])
    }

    // [MCP-82] Through the tool: a tap with `observe: "text"` answers the text view.
    @MainActor
    func testATapObservingTextAnswersTheTextView() async throws {
        let fixture = try TypeTextFixture()
        defer { fixture.close() }
        let window = try await fixture.liveWindow()
        fixture.treeNodes = [
            ["i": 0, "k": 2, "role": "Button", "text": "Continue", "click": true,
             "box": [100, 1400, 980, 1600], "at": [0.5, 0.64]],
        ]
        let (answer, _) = await fixture.call("tap", ["window": Int(window.stream), "x": 0.5, "y": 0.2,
                                                     "observe": "text"])
        XCTAssertEqual(answer["isError"] as? Bool, false, "tap failed: \(answer)")
        let structured = try XCTUnwrap(answer["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["text"] as? String, "Continue [e2 Button]")
        XCTAssertNil(structured["tree"])
    }
}
