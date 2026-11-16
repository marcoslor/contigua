// The Mac's half of `ui.tree` (WIN-79, ISS-160): parse the phone's trimmed
// accessibility tree, refuse a malformed one, and write the tool result with
// only the fields the contract names.

import XCTest
@testable import Contigua

final class UITreeTests: XCTestCase {

    private func message(_ raw: [String: Any]) -> JSONMessage { JSONMessage(raw: raw) }

    /// A reply shaped like the phone's: one app window, a label, a button and a
    /// password field.
    private func phoneReply(extra: [String: Any] = [:]) -> JSONMessage {
        var raw: [String: Any] = [
            "t": "ui.tree",
            "stream": 3,
            "seq": 9,
            "ok": true,
            "displayId": 47,
            "snapshot": 12,
            "truncated": false,
            "windows": [
                ["i": 0, "title": "Calculator", "type": "app", "focused": true, "active": true],
                ["i": 1, "title": "Keyboard", "type": "ime", "focused": false, "active": false],
            ],
            "nodes": [
                ["i": 0, "ref": "e0", "w": 0, "role": "TextView", "text": "42 + 1",
                 "box": [100, 200, 500, 400], "at": [0.3, 0.15]],
                ["i": 1, "ref": "e1", "p": 0, "w": 0, "role": "Button", "text": "Equals",
                 "id": "equals", "box": [540, 640, 780, 760], "at": [0.66, 0.35], "click": true],
                ["i": 2, "ref": "e2", "p": 0, "w": 0, "role": "EditText", "pwd": true, "edit": true,
                 "box": [100, 800, 900, 900], "at": [0.5, 0.425]],
            ],
        ]
        for (key, value) in extra { raw[key] = value }
        return message(raw)
    }

    func testAPhoneReplyParsesIntoWindowsAndNodes() throws {
        let tree = try XCTUnwrap(UITree(message: phoneReply()))
        XCTAssertEqual(tree.seq, 9)
        XCTAssertEqual(tree.stream, 3)
        XCTAssertTrue(tree.ok)
        XCTAssertEqual(tree.displayId, 47)
        XCTAssertEqual(tree.snapshot, 12)
        XCTAssertFalse(tree.truncated)
        XCTAssertEqual(tree.windows.count, 2)
        XCTAssertEqual(tree.windows[0].title, "Calculator")
        XCTAssertEqual(tree.windows[1].type, "ime")
        XCTAssertEqual(tree.nodes.count, 3)
        XCTAssertEqual(tree.nodes[1].role, "Button")
        XCTAssertEqual(tree.nodes[1].parent, 0)
        XCTAssertEqual(tree.nodes[1].id, "equals")
        XCTAssertEqual(tree.nodes[1].box, [540, 640, 780, 760])
        XCTAssertEqual(tree.nodes[1].at, UITree.Point(x: 0.66, y: 0.35))
        XCTAssertEqual(tree.nodes[1].ref, "e1")
        XCTAssertTrue(tree.nodes[1].click)
        XCTAssertTrue(tree.nodes[2].password)
        XCTAssertNil(tree.nodes[2].text)
    }

    func testAFailedReadCarriesItsCodeAndSentence() throws {
        let raw: [String: Any] = [
            "t": "ui.tree", "stream": 3, "seq": 9, "ok": false,
            "code": "no_a11y", "message": "This phone cannot read an accessibility tree right now.",
        ]
        let tree = try XCTUnwrap(UITree(message: message(raw)))
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
                ["i": 0, "ref": "e0", "w": 0, "role": "Button", "text": "Save"],
                ["ref": "e1", "w": 0, "role": "TextView", "text": "no index"],
                ["i": 2, "ref": "e2", "w": 0, "text": "no role"],
                ["i": 3, "w": 0, "role": "Button", "text": "no ref"],
            ],
        ]
        let tree = try XCTUnwrap(UITree(message: message(raw)))
        XCTAssertEqual(tree.nodes.map(\.role), ["Button"])
    }

    func testTheResultCarriesOnlyTheContractsFields() throws {
        let tree = try XCTUnwrap(UITree(message: phoneReply(extra: [
            "secret": "not in the contract",
        ])))
        let text = tree.encoded()
        XCTAssertFalse(text.contains("secret"))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["window"] as? Int, 3)
        XCTAssertEqual(object["displayId"] as? Int, 47)
        XCTAssertEqual(object["truncated"] as? Bool, false)
        let nodes = try XCTUnwrap(object["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes.count, 3)
        XCTAssertEqual(nodes[1]["text"] as? String, "Equals")
        XCTAssertEqual(nodes[1]["at"] as? [Double], [0.66, 0.35])
        XCTAssertEqual(nodes[1]["ref"] as? String, "e1")
        XCTAssertNil(nodes[2]["text"])
        XCTAssertEqual(nodes[2]["pwd"] as? Bool, true)
    }

    func testTheWindowIndexIsLeftOutWhenThereIsOneWindow() throws {
        var raw = phoneReply().raw
        raw["windows"] = [["i": 0, "title": "Calculator", "type": "app", "focused": true, "active": true]]
        let one = try XCTUnwrap(UITree(message: JSONMessage(raw: raw)))
        let oneNodes = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(one.encoded().utf8)) as? [String: Any])["nodes"]
            as? [[String: Any]]
        XCTAssertNotNil(oneNodes)
        XCTAssertTrue(oneNodes?.allSatisfy { $0["w"] == nil } ?? false,
                      "one window: every row would repeat the same 0")
        // Two windows: the index is the only thing that says whose row it is.
        let two = try XCTUnwrap(UITree(message: phoneReply()))
        XCTAssertTrue(two.encoded().contains("\"w\":0"))
    }

    func testATapPointIsPrintedAtThreeDecimals() throws {
        // Foundation's JSON writer prints 0.949 as 0.94899999999999995; a tree
        // read on a real screen carried that noise on every row.
        var raw = phoneReply().raw
        raw["nodes"] = [["i": 0, "ref": "e0", "w": 0, "role": "Button", "text": "Buy",
                         "box": [0, 0, 10, 10], "at": [0.949, 0.123]]]
        let tree = try XCTUnwrap(UITree(message: JSONMessage(raw: raw)))
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
        // The phone omits what is false; the parse must not turn a missing
        // click into an explicit one.
        let raw: [String: Any] = [
            "t": "ui.tree", "stream": 3, "seq": 1, "ok": true,
            "nodes": [["i": 0, "ref": "e0", "w": 0, "role": "TextView", "text": "plain"]],
        ]
        let tree = try XCTUnwrap(UITree(message: message(raw)))
        let text = tree.encoded()
        XCTAssertFalse(text.contains("\"click\""))
        XCTAssertFalse(text.contains("\"disabled\""))
        XCTAssertFalse(text.contains("\"check\""))
    }

    func testRefsAreRememberedUntilTheNextTree() throws {
        var refs = UITreeRefs()
        refs.remember(try XCTUnwrap(UITree(message: phoneReply())))
        XCTAssertEqual(refs.resolved(ref: "e1", stream: 3)?.placed.point,
                       UITree.Point(x: 0.66, y: 0.35))
        XCTAssertEqual(refs.resolved(ref: "e1", stream: 3)?.placed.box, [540, 640, 780, 760])
        XCTAssertEqual(refs.resolved(ref: "e1", stream: 3)?.snapshot, 12)
        XCTAssertNil(refs.resolved(ref: "e9", stream: 3))
        XCTAssertNil(refs.resolved(ref: "e1", stream: 4), "a ref belongs to its window")
        // A second tree replaces the first: the old names mean new elements.
        var moved = phoneReply()
        var raw = moved.raw
        raw["snapshot"] = 13
        raw["nodes"] = [["i": 0, "ref": "e0", "w": 0, "role": "Button", "text": "New",
                         "box": [0, 0, 10, 10], "at": [0.01, 0.01]]]
        moved = JSONMessage(raw: raw)
        refs.remember(try XCTUnwrap(UITree(message: moved)))
        XCTAssertNil(refs.resolved(ref: "e1", stream: 3), "an older tree's ref is gone")
        XCTAssertEqual(refs.resolved(ref: "e0", stream: 3)?.placed.point, UITree.Point(x: 0.01, y: 0.01))
        refs.forget(stream: 3)
        XCTAssertNil(refs.resolved(ref: "e0", stream: 3))
    }

    func testAnUncheckedBoxKeepsItsFalse() throws {
        let raw: [String: Any] = [
            "t": "ui.tree", "stream": 3, "seq": 1, "ok": true,
            "nodes": [["i": 0, "ref": "e0", "w": 0, "role": "CheckBox", "text": "Wi-Fi", "check": false]],
        ]
        let tree = try XCTUnwrap(UITree(message: message(raw)))
        XCTAssertEqual(tree.nodes[0].check, false)
        XCTAssertTrue(tree.encoded().contains("\"check\":false"))
    }
}
