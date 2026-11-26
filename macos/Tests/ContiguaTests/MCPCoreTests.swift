// MCP core: the initialize handshake, the stable tool list, argument validation
// for every tool, and the JSON-RPC error boundaries (docs/design/mcp.md).

import XCTest
@testable import Contigua

final class MCPCoreTests: XCTestCase {

    /// Records calls from the async perform closure without tripping concurrency checks.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [MCPCall] = []
        var calls: [MCPCall] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        func add(_ call: MCPCall) {
            lock.lock(); storage.append(call); lock.unlock()
        }
    }

    private func line(_ object: [String: Any]) -> Data {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return data + Data("\n".utf8)
    }

    private func request(_ id: Int, _ method: String, _ params: [String: Any]? = nil) -> Data {
        var object: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { object["params"] = params }
        return line(object)
    }

    private func decode(_ data: Data?) throws -> [String: Any] {
        let unwrapped = try XCTUnwrap(data)
        let object = try JSONSerialization.jsonObject(with: unwrapped)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func errorCode(_ data: Data?) throws -> Int {
        let object = try decode(data)
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        return try XCTUnwrap(error["code"] as? Int)
    }

    private func toolNames() -> [String] {
        MCPTools.all.map(\.name.rawValue)
    }

    // MARK: initialize

    func testInitializeHandshake() async throws {
        let response = try decode(await MCPDispatcher.handle(
            line: request(1, "initialize", ["protocolVersion": MCPProtocol.version,
                                           "capabilities": [:],
                                           "clientInfo": ["name": "test", "version": "1"]]),
            client: MCPClientID(1), perform: { _, _ in .answer([:]) }))
        XCTAssertEqual(response["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(response["id"] as? Int, 1)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
        XCTAssertNotNil(capabilities["tools"])
        let info = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(info["name"] as? String, "contigua")
        XCTAssertFalse((info["version"] as? String ?? "").isEmpty)
    }

    /// MCP-3: serverInfo reports the app's version from its bundle, never a
    /// number of its own that drifts from `VERSION`.
    func testServerInfoVersionIsTheAppsVersion() {
        XCTAssertEqual(MCPProtocol.appVersion(["CFBundleShortVersionString": "0.2.0"]), "0.2.0")
        XCTAssertEqual(MCPProtocol.appVersion(["CFBundleShortVersionString": ""]), "unknown")
        XCTAssertEqual(MCPProtocol.appVersion(nil), "unknown")
    }

    func testInitializedNotificationGetsNoReply() async {
        let data = await MCPDispatcher.handle(
            line: line(["jsonrpc": "2.0", "method": "notifications/initialized"]),
            client: MCPClientID(1), perform: { _, _ in .answer([:]) })
        XCTAssertNil(data)
    }

    func testPingAnswersAnEmptyResult() async throws {
        let response = try decode(await MCPDispatcher.handle(
            line: request(7, "ping"), client: MCPClientID(1), perform: { _, _ in .answer([:]) }))
        XCTAssertEqual((response["result"] as? [String: Any])?.count, 0)
    }

    // MARK: tools/list

    func testToolListIsStable() async throws {
        let response = try decode(await MCPDispatcher.handle(
            line: request(2, "tools/list", [:]),
            client: MCPClientID(1), perform: { _, _ in .answer([:]) }))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, [
            "phone_status", "list_apps", "open_app", "list_windows", "screenshot", "ui_tree",
            "wait", "tap", "swipe", "type_text", "press_key",
            "close_window", "send_link", "send_file",
        ])
        for tool in tools {
            XCTAssertFalse((tool["description"] as? String ?? "").isEmpty)
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            XCTAssertNotNil(schema["properties"] as? [String: Any])
        }
    }

    func testTapSchemaIsExactlyTheDocumentedShape() throws {
        let tap = try XCTUnwrap(MCPTools.tool("tap"))
        let expected: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["window"],
            "properties": [
                "window": ["type": "integer", "minimum": 1, "maximum": 1_000_000,
                           "description": "Window id from list_windows."],
                "x": ["type": "number", "minimum": 0, "maximum": 1,
                      "description": "Horizontal position, 0 (left) to 1 (right), in the window's video rect."],
                "y": ["type": "number", "minimum": 0, "maximum": 1,
                      "description": "Vertical position, 0 (top) to 1 (bottom), in the window's video rect."],
                "ref": ["type": "string", "minLength": 1, "maxLength": 32, "pattern": "^e[0-9]+$",
                        "description": "Element ref from ui_tree, e.g. \"e5\". Takes precedence over x and y."],
                // MCP-88 (T2).
                "holdMs": ["type": "integer", "minimum": 1, "maximum": 3000,
                           "description": "Hold the press this many milliseconds (1 to 3000): a long press."],
                // MCP-81, MCP-82 (T5; `text` T9).
                "wait": ["type": "string", "enum": ["settle", "none"],
                         "description": "settle (the default for an action) waits until the window's accessibility tree has not changed for 300 ms and nothing on it is loading, at most 2 s; none answers at once."],
                "observe": ["type": "string", "enum": ["tree", "text", "none"],
                            "description": "tree (the default) returns the ui_tree answer read after the settle; text returns that screen as ui_tree's text view; none returns no screen."],
            ],
        ]
        XCTAssertEqual(tap.schema as NSDictionary, expected as NSDictionary)
    }

    func testTapTakesARefOrAPointButNotNeither() throws {
        // WIN-79: a ref names an element in the tree the client just read.
        XCTAssertEqual(try MCPArguments.call("tap", ["window": 3, "ref": "e5"]),
                       .tapRef(window: 3, ref: "e5"))
        // A ref wins over a point, so a client may send both.
        XCTAssertEqual(try MCPArguments.call("tap", ["window": 3, "ref": "e5", "x": 0.2, "y": 0.4]),
                       .tapRef(window: 3, ref: "e5"))
        XCTAssertThrowsError(try MCPArguments.call("tap", ["window": 3]))
        XCTAssertThrowsError(try MCPArguments.call("tap", ["window": 3, "x": 0.5]))
        XCTAssertThrowsError(try MCPArguments.call("tap", ["window": 3, "ref": ""]))
    }

    // MARK: argument validation, every tool

    func testEveryToolValidatesItsArguments() throws {
        let cases: [(String, [String: Any], MCPCall)] = [
            ("phone_status", [:], .phoneStatus),
            ("list_apps", [:], .listApps()),
            ("open_app", ["app": "com.android.settings"], .openApp("com.android.settings", newWindow: false)),
            ("open_app", ["app": "com.android.chrome", "newWindow": true],
             .openApp("com.android.chrome", newWindow: true)),
            ("list_windows", [:], .listWindows),
            ("screenshot", ["window": 3], .screenshot(window: 3, ref: nil)),
            ("screenshot", ["window": 3, "ref": "e1"], .screenshot(window: 3, ref: "e1")),
            ("ui_tree", ["window": 3], .uiTree(window: 3)),
            ("wait", ["window": 3, "ms": 1000],
             .wait(window: 3, mode: .clock(ms: 1000), timeoutMs: 10000, observe: .tree)),
            ("tap", ["window": 3, "x": 0.25, "y": 1], .tap(window: 3, x: 0.25, y: 1)),
            ("tap", ["window": 3, "x": 0, "y": 0.5, "holdMs": 3000],
             .tap(window: 3, x: 0, y: 0.5, holdMs: 3000)),
            ("swipe", ["window": 3, "x1": 0.1, "y1": 0.2, "x2": 0.9, "y2": 0.8, "ms": 2000],
             .swipe(window: 3, x1: 0.1, y1: 0.2, x2: 0.9, y2: 0.8, ms: 2000)),
            ("swipe", ["window": 3, "direction": "down", "ref": "e2"],
             .swipeDirection(window: 3, direction: .down, ref: "e2", ms: 300)),
            ("type_text", ["window": 3, "text": "hello"], .typeText(window: 3, text: "hello")),
            ("press_key", ["window": 3, "key": "enter"], .pressKey(window: 3, key: .enter)),
            ("input_probe", ["window": 3, "x": 0.5, "y": 0.5],
             .inputProbe(window: 3, x: 0.5, y: 0.5, width: nil, height: nil)),
            ("input_probe", ["window": 3, "x": 0.5, "y": 0.5, "w": 0.4, "h": 0.4],
             .inputProbe(window: 3, x: 0.5, y: 0.5, width: 0.4, height: 0.4)),
            ("close_window", ["window": 3], .closeWindow(window: 3)),
            ("close_window", ["window": 3, "force": true], .closeWindow(window: 3, force: true)),
            ("send_link", ["url": "https://example.com"], .sendLink("https://example.com")),
            ("send_file", ["path": "/tmp/a.bin"], .sendFile("/tmp/a.bin")),
        ]
        XCTAssertEqual(Set(cases.map { $0.0 }), Set(toolNames()))
        for (name, args, expected) in cases {
            XCTAssertEqual(try MCPArguments.call(name, args, devTools: true), expected, name)
        }
    }

    func testEveryToolRejectsMissingRequiredArguments() {
        for tool in MCPTools.all {
            let required = tool.schema["required"] as? [String] ?? []
            guard !required.isEmpty else { continue }
            XCTAssertThrowsError(try MCPArguments.call(tool.name.rawValue, [:], devTools: true), tool.name.rawValue) { error in
                XCTAssertTrue(error is MCPArgumentError)
            }
        }
    }

    func testCoordinatesMustBeInsideTheWindow() {
        for bad in [-0.01, 1.01, 42.0] {
            XCTAssertThrowsError(try MCPArguments.call("tap", ["window": 1, "x": bad, "y": 0.5]))
            XCTAssertThrowsError(try MCPArguments.call("tap", ["window": 1, "x": 0.5, "y": bad]))
        }
        XCTAssertThrowsError(try MCPArguments.call("swipe",
            ["window": 1, "x1": 0, "y1": 0, "x2": 2, "y2": 1]))
        XCTAssertThrowsError(try MCPArguments.call("input_probe",
            ["window": 1, "x": 0.5, "y": 0.5, "w": 0.01], devTools: true))
        XCTAssertThrowsError(try MCPArguments.call("input_probe",
            ["window": 1, "x": 0.5, "y": 0.5, "h": 1.01], devTools: true))
    }

    func testWindowMustBeAPositiveInteger() {
        for bad: Any in [0, -1, 1.5, "1", true] {
            XCTAssertThrowsError(try MCPArguments.call("tap",
                ["window": bad, "x": 0.5, "y": 0.5]), "\(bad)")
        }
        XCTAssertThrowsError(try MCPArguments.call("screenshot", ["window": 1_000_001]))
    }

    func testGestureDurationsAreCapped() {
        XCTAssertThrowsError(try MCPArguments.call("tap",
            ["window": 1, "x": 0.5, "y": 0.5, "holdMs": 3001]))
        XCTAssertThrowsError(try MCPArguments.call("tap",
            ["window": 1, "x": 0.5, "y": 0.5, "holdMs": 0]))
        XCTAssertThrowsError(try MCPArguments.call("swipe",
            ["window": 1, "x1": 0, "y1": 0, "x2": 1, "y2": 1, "ms": 2001]))
    }

    func testTextIsCappedAtTwoThousandCharacters() {
        XCTAssertNoThrow(try MCPArguments.call("type_text",
            ["window": 1, "text": String(repeating: "a", count: 2000)]))
        XCTAssertThrowsError(try MCPArguments.call("type_text",
            ["window": 1, "text": String(repeating: "a", count: 2001)]))
        XCTAssertThrowsError(try MCPArguments.call("type_text", ["window": 1, "text": 7]))
    }

    func testPressKeyOnlyAcceptsTheDocumentedKeys() {
        for key in MCPKey.allCases {
            XCTAssertNoThrow(try MCPArguments.call("press_key", ["window": 1, "key": key.rawValue]))
        }
        XCTAssertThrowsError(try MCPArguments.call("press_key", ["window": 1, "key": "volume_up"]))
    }

    func testUnknownArgumentsAreRefused() {
        XCTAssertThrowsError(try MCPArguments.call("tap",
            ["window": 1, "x": 0.5, "y": 0.5, "pressure": 2])) { error in
            XCTAssertEqual((error as? MCPArgumentError)?.message, "unknown argument “pressure”")
        }
    }

    // MARK: tools/call over the dispatcher

    private func callRequest(_ name: String, _ arguments: [String: Any]) -> Data {
        request(9, "tools/call", ["name": name, "arguments": arguments])
    }

    func testToolCallReachesTheExecutorWithValidatedArguments() async throws {
        let recorder = Recorder()
        let response = try decode(await MCPDispatcher.handle(
            line: callRequest("tap", ["window": 4, "x": 0.5, "y": 0.75]),
            client: MCPClientID(1), perform: { call, _ in recorder.add(call); return .answer(["ok": true]) }))
        XCTAssertEqual(recorder.calls, [.tap(window: 4, x: 0.5, y: 0.75)])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        XCTAssertEqual(content.first?["text"] as? String, #"{"ok":true}"#)
    }

    func testRuntimeFailureIsAToolErrorNotAProtocolError() async throws {
        let response = try decode(await MCPDispatcher.handle(
            line: callRequest("screenshot", ["window": 7]),
            client: MCPClientID(1), perform: { _, _ in .failure(.noWindow(7)) }))
        XCTAssertNil(response["error"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let error = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "no_window")
        XCTAssertEqual(error["message"] as? String, "No window 7. Call list_windows to see what is open.")
    }

    func testImageResultCarriesBase64PNG() async throws {
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        let response = try decode(await MCPDispatcher.handle(
            line: callRequest("screenshot", ["window": 1]),
            client: MCPClientID(1), perform: { _, _ in .image(png, ["window": 1]) }))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "image")
        XCTAssertEqual(content.first?["mimeType"] as? String, "image/png")
        XCTAssertEqual(Data(base64Encoded: content.first?["data"] as? String ?? ""), png)
    }

    // MARK: Answers, errors and the log line (plan T1)

    private func call(_ name: String, _ args: [String: Any],
                      _ result: MCPToolResult) async throws -> [String: Any] {
        let response = try decode(await MCPDispatcher.handle(
            line: callRequest(name, args), client: MCPClientID(1),
            perform: { _, _ in result }))
        return try XCTUnwrap(response["result"] as? [String: Any])
    }

    // [MCP-5]
    func testEveryAnswerIsStructuredAndMirroredAsText() async throws {
        let data = await MCPDispatcher.handle(
            line: callRequest("list_windows", [:]), client: MCPClientID(1),
            perform: { _, _ in .answer(["window": 3]) })
        let text = String(decoding: try XCTUnwrap(data), as: UTF8.self)
        XCTAssertTrue(text.contains(
            #""result":{"content":[{"text":"{\"window\":3}","type":"text"}],"isError":false,"structuredContent":{"window":3}}"#),
            text)
        let result = try await call("list_windows", [:], .answer(["window": 3]))
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual((result["structuredContent"] as? [String: Any])?["window"] as? Int, 3)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, #"{"window":3}"#)
        // No 17-digit doubles: a point prints as it was written.
        let point = try await call("list_windows", [:], .answer(["x": 0.651]))
        let pointText = (point["content"] as? [[String: Any]])?.first?["text"] as? String
        XCTAssertEqual(pointText, #"{"x":0.651}"#)
    }

    // [MCP-5]
    func testImageAnswerPutsTheImageFirst() async throws {
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        let result = try await call("screenshot", ["window": 3], .image(png, ["window": 3]))
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "image")
        XCTAssertEqual(content[0]["mimeType"] as? String, "image/png")
        XCTAssertEqual(Data(base64Encoded: content[0]["data"] as? String ?? ""), png)
        XCTAssertEqual(content[1]["type"] as? String, "text")
        XCTAssertEqual(content[1]["text"] as? String, #"{"window":3}"#)
        XCTAssertEqual((result["structuredContent"] as? [String: Any])?["window"] as? Int, 3)
    }

    // [MCP-5]
    func testToolListDeclaresAnOutputSchemaForEveryTool() async throws {
        let response = try decode(await MCPDispatcher.handle(
            line: request(2, "tools/list"), client: MCPClientID(1), devTools: true,
            perform: { _, _ in .answer([:]) }))
        let tools = try XCTUnwrap((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, MCPToolName.allCases.count)
        for tool in tools {
            let schema = try XCTUnwrap(tool["outputSchema"] as? [String: Any], "\(tool["name"] ?? "?")")
            XCTAssertEqual(schema["type"] as? String, "object")
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            XCTAssertFalse(properties.isEmpty, "\(tool["name"] ?? "?")")
        }
    }

    // [MCP-4] [MCP-5] Every tool's sample answer — the shape each tool makes
    // today — validates against that tool's own `outputSchema`: every `required`
    // key present and no key outside `properties`. A field a tool emits and the
    // schema never names (`ui_tree`'s `omitted`) is refused by any client that
    // validates, which is what broke after #206.
    func testEveryToolsSampleAnswerMatchesItsOutputSchema() throws {
        let samples = MCPCoreTests.sampleAnswers()
        XCTAssertEqual(Set(samples.keys), Set(MCPToolName.allCases),
                       "a tool with no sample answer is never checked")
        for (tool, answer) in samples {
            let schema = MCPOutputSchemas.schema(for: tool)
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false,
                           "\(tool.rawValue)'s outputSchema does not name its keys")
            XCTAssertEqual(MCPCoreTests.schemaProblems(answer, schema), [],
                           "\(tool.rawValue) breaks its outputSchema")
        }
        // The sample that broke: a tree read carries `omitted`, so the schema
        // must name it.
        let tree = try XCTUnwrap(samples[.uiTree])
        XCTAssertNotNil(tree["omitted"])
    }

    /// A recursive check of one answer against its schema (the JSON Schema
    /// subset `tools/list` declares): the type, `required` and — since an
    /// `outputSchema` names every field a tool may answer — `properties`, so a
    /// key outside them is a break. `items` is checked for each row.
    static func schemaProblems(_ value: Any, _ schema: [String: Any],
                               _ at: String = "answer") -> [String] {
        var out: [String] = []
        let kinds: [String] = (schema["type"] as? String).map { [$0] }
            ?? (schema["type"] as? [String] ?? [])
        if !kinds.isEmpty, !kinds.contains(where: { kindFits(value, $0) }) {
            return ["\(at) is not one of \(kinds.joined(separator: "/"))"]
        }
        if let object = value as? [String: Any] {
            for key in schema["required"] as? [String] ?? [] where object[key] == nil {
                out.append("\(at) lacks required “\(key)”")
            }
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for key in object.keys.sorted() where properties[key] == nil {
                out.append("\(at) answers “\(key)”, which its schema does not declare")
            }
            for (key, sub) in properties {
                if let held = object[key], let declared = sub as? [String: Any] {
                    out += schemaProblems(held, declared, "\(at).\(key)")
                }
            }
        }
        if let rows = value as? [Any], let items = schema["items"] as? [String: Any] {
            for (row, item) in rows.enumerated() {
                out += schemaProblems(item, items, "\(at)[\(row)]")
            }
        }
        return out
    }

    private static func kindFits(_ value: Any, _ kind: String) -> Bool {
        switch kind {
        case "null": return value is NSNull
        case "boolean": return MCPValue.isBool(value)
        case "integer":
            return (value as? NSNumber).map { !MCPValue.isBool($0) && $0.doubleValue == $0.doubleValue.rounded() } ?? false
        case "number": return value is NSNumber && !MCPValue.isBool(value)
        case "string": return value is String
        case "array": return value is [Any]
        case "object": return value is [String: Any]
        default: return true
        }
    }

    /// One answer per tool, made by the same builders the tools answer with,
    /// carrying every field they may add.
    static func sampleAnswers() -> [MCPToolName: [String: Any]] {
        let state = "live"
        let frame = FrameClock.object(seq: 1340, ageMs: 35)
        let settle = MCPActMachine.Settle(state: "settled", waitedMs: 412)
        let tree: [String: Any] = [
            "window": 3, "ok": true, "displayId": 64, "snapshot": 8, "truncated": false,
            "size": [1080, 2364], "omitted": 41, "loading": false, "note": "…",
            "matched": 1, "total": 87, "state": state, "frame": frame,
            "layers": [["i": 0, "title": "Wikipedia", "type": "app", "active": true]],
            "nodes": [["i": 0, "ref": "e3", "role": "TextView", "text": "Ada Lovelace", "desc": "…",
                       "id": "…", "heading": true, "box": [48, 420, 1032, 520], "at": [0.5, 0.196],
                       "off": true, "click": true, "edit": true, "scroll": true, "check": true,
                       "sel": true, "focus": true, "disabled": true, "pwd": true, "p": 1, "l": 0,
                       "loading": true, "hint": true, "hintText": "…", "hidden": [0, 41],
                       "covered": "e31", "in": "e20"]],
        ]
        let treeJSON = MCPJSON.string(tree)
        let acted = MCPActEnvelope.answer(
            window: 3, did: MCPActDid.swipe(from: [0.5, 0.9], to: [0.5, 0.2], ms: 300, direction: .up),
            frameAtInput: 1302,
            result: MCPActMachine.Answer(settle: settle, state: state, tree: treeJSON))
            .merging(["frame": frame]) { a, _ in a }
        let typed = MCPActEnvelope.answer(
            window: 3, did: MCPActDid.type(characters: 2, clear: false, submit: false), frameAtInput: nil,
            result: MCPActMachine.Answer(settle: settle, state: state, entry: "inserted", via: "keys"))
            .merging(["frame": frame]) { a, _ in a }
        var waited = MCPWaitAnswer(waitedMs: 5004, until: "met",
                                   match: ["ref": "e14", "text": "00:05.02"])
        waited.tree = tree
        let opened = MCPOpenAnswer.answer(window: 5, kind: .app, package: "com.example.shop", label: "Shop",
                                          opened: .new, openedBy: "you", size: [590, 1280],
                                          result: MCPActMachine.Answer(settle: settle, state: state, tree: treeJSON))
            .merging(["frame": frame]) { a, _ in a }
        let status = MCPToolHost.statusAnswer(
            MCPStatusInput(connected: true, name: "My phone", battery: 81, charging: false, windows: 2,
                           maxWindows: 4,
                           phone: MCPStatusPhone(locked: true, screen: .off, lockSource: .broadcast,
                                                 lockChangedAt: .now),
                           foreground: .pkg("org.example.browser"), apps: []), now: .now)
        return [
            .phoneStatus: status,
            .listApps: ["apps": [["label": "Calculator", "package": "com.google.android.calculator"]],
                        "total": 1],
            .openApp: opened, .sendLink: opened,
            .listWindows: [
                "windows": [["id": 3, "kind": "app", "package": "com.google.android.calculator",
                             "size": [590, 1280], "state": state, "frame": frame, "openedBy": "you",
                             "openedAgoMs": 42000]],
                "recentlyClosed": [["id": 2, "kind": "link", "package": NSNull(), "reason": "closed",
                                    "closedBy": "another_agent", "closedAgoMs": 5100]],
            ],
            .screenshot: ["window": 3, "state": state, "frame": frame, "image": [1280, 740],
                          "size": [2860, 1654], "crop": [130, 1052, 1310, 1148], "blank": true,
                          "settle": MCPActEnvelope.settle(settle)],
            .uiTree: tree,
            .wait: waited.object(window: 3).merging(["state": state, "frame": frame]) { a, _ in a },
            .tap: acted, .swipe: acted, .pressKey: acted,
            .typeText: typed,
            .inputProbe: ["ok": true, "window": 3, "frames": 4, "sent_ms": 1823344.2,
                          "changed_ms": 48.1, "state": state, "frame": frame],
            .closeWindow: ["window": 3, "closed": ["reason": "closed", "closedBy": "you"]],
            .sendFile: ["bytes": 1_048_576, "state": "delivered"],
        ]
    }

    // [MCP-64] `ui_tree` and `screenshot` with `wait: "settle"` carry `settle`:
    // both outputSchemas declare it.
    func testTreeAndScreenshotDeclareSettle_MCP64() throws {
        for tool: MCPToolName in [.screenshot, .uiTree] {
            let schema = MCPOutputSchemas.schema(for: tool)
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            XCTAssertNotNil(properties["settle"], tool.rawValue)
        }
    }

    // [MCP-20] [MCP-21] Every answer that reflects a window's screen declares
    // `state` and `frame` as required, and the stamp fills them in.
    func testScreenAnswersRequireStateAndFrame() throws {
        for tool: MCPToolName in [.screenshot, .uiTree, .tap, .swipe, .typeText,
                                  .pressKey, .inputProbe] {
            let schema = MCPOutputSchemas.schema(for: tool)
            let required = schema["required"] as? [String] ?? []
            XCTAssertTrue(required.contains("state") && required.contains("frame"), "\(tool)")
            let frame = (schema["properties"] as? [String: Any])?["frame"] as? [String: Any]
            XCTAssertEqual(frame?["required"] as? [String], ["seq", "ageMs"], "\(tool)")
        }
        let windows = MCPOutputSchemas.schema(for: .listWindows)
        let row = ((windows["properties"] as? [String: Any])?["windows"] as? [String: Any])?["items"]
            as? [String: Any]
        XCTAssertEqual(Set(row?["required"] as? [String] ?? []),
                       ["id", "package", "size", "state", "frame"])
        let screenshot = MCPOutputSchemas.schema(for: .screenshot)["required"] as? [String] ?? []
        XCTAssertEqual(Set(screenshot), ["window", "state", "frame", "image", "size"])

        let stamped = MCPFreshness.stamp(["ok": true, "window": 3], state: "paused",
                                         frame: FrameClock.object(seq: 0, ageMs: nil))
        XCTAssertEqual(stamped["state"] as? String, "paused")
        XCTAssertEqual((stamped["frame"] as? [String: Any])?["seq"] as? Int, 0)
        XCTAssertTrue((stamped["frame"] as? [String: Any])?["ageMs"] is NSNull)
        XCTAssertEqual(stamped["ok"] as? Bool, true)
    }

    // [MCP-14]
    func testTheLogLineCarriesNameDurationCodeAndWindowOnly() async throws {
        final class Box: @unchecked Sendable {
            var entries: [(MCPToolName, TimeInterval, MCPErrorCode?, Int?)] = []
        }
        let box = Box()
        _ = await MCPDispatcher.handle(
            line: callRequest("type_text", ["window": 3, "text": "secret"]), client: MCPClientID(1),
            perform: { _, _ in .answer(["window": 3, "characters": 6]) },
            log: { tool, duration, code, window in box.entries.append((tool, duration, code, window)) })
        XCTAssertEqual(box.entries.count, 1)
        let entry = try XCTUnwrap(box.entries.first)
        XCTAssertEqual(entry.0, .typeText)
        XCTAssertGreaterThanOrEqual(entry.1, 0)
        XCTAssertNil(entry.2)
        XCTAssertEqual(entry.3, 3)
        let line = MCPLogLine.format(tool: entry.0, duration: entry.1, code: entry.2, window: entry.3)
        XCTAssertFalse(line.contains("secret"), line)
        XCTAssertTrue(line.hasPrefix("mcp type_text "), line)
        XCTAssertTrue(line.contains("window=3"), line)

        _ = await MCPDispatcher.handle(
            line: callRequest("ui_tree", ["window": 9]), client: MCPClientID(1),
            perform: { _, _ in .failure(.noWindow(9)) },
            log: { tool, duration, code, window in box.entries.append((tool, duration, code, window)) })
        XCTAssertEqual(box.entries.last?.2, .noWindow)
        let failed = MCPLogLine.format(tool: .uiTree, duration: 0.012, code: .noWindow, window: 9)
        XCTAssertEqual(failed, "mcp ui_tree 12 ms code=no_window window=9")
        XCTAssertFalse(failed.contains("No window"), failed)
    }

    func testUnknownToolIsInvalidParams() async throws {
        let data = await MCPDispatcher.handle(
            line: callRequest("teleport", ["window": 1]),
            client: MCPClientID(1), perform: { _, _ in .answer([:]) })
        XCTAssertEqual(try errorCode(data), -32602)
    }

    func testInvalidArgumentsAreInvalidParams() async throws {
        let data = await MCPDispatcher.handle(
            line: callRequest("tap", ["window": 1, "x": 9, "y": 0.5]),
            client: MCPClientID(1), perform: { _, _ in .answer([:]) })
        XCTAssertEqual(try errorCode(data), -32602)
    }

    func testUnknownMethodIsMethodNotFound() async throws {
        let data = await MCPDispatcher.handle(
            line: request(3, "resources/list"), client: MCPClientID(1), perform: { _, _ in .answer([:]) })
        XCTAssertEqual(try errorCode(data), -32601)
    }

    // MARK: protocol faults

    func testMalformedJSONIsAParseError() async throws {
        let data = await MCPDispatcher.handle(
            line: Data("{not json\n".utf8), client: MCPClientID(1), perform: { _, _ in .answer([:]) })
        XCTAssertEqual(try errorCode(data), -32700)
    }

    func testNonObjectAndWrongVersionAreInvalidRequests() async throws {
        let array = await MCPDispatcher.handle(
            line: Data("[1,2]\n".utf8), client: MCPClientID(1), perform: { _, _ in .answer([:]) })
        XCTAssertEqual(try errorCode(array), -32600)
        let version = await MCPDispatcher.handle(
            line: line(["jsonrpc": "1.0", "id": 1, "method": "ping"]),
            client: MCPClientID(1), perform: { _, _ in .answer([:]) })
        XCTAssertEqual(try errorCode(version), -32600)
        let badId = await MCPDispatcher.handle(
            line: line(["jsonrpc": "2.0", "id": 1.5, "method": "ping"]),
            client: MCPClientID(1), perform: { _, _ in .answer([:]) })
        XCTAssertEqual(try errorCode(badId), -32600)
    }

    func testAnOversizedLineIsRefused() async throws {
        let oversized = Data(repeating: 0x20, count: MCPProtocol.maxLineBytes + 1)
        let data = await MCPDispatcher.handle(line: oversized, client: MCPClientID(1), perform: { _, _ in .answer([:]) })
        XCTAssertEqual(try errorCode(data), -32600)
    }
    // [MCP-71] Review: a ref that is not a key is an argument error.
    func testARefMustBeAKey() async throws {
        for (tool, ref) in [("tap", "s3e1"), ("tap", "x"), ("screenshot", "s3e1"), ("screenshot", "x")] {
            let data = await MCPDispatcher.handle(
                line: callRequest(tool, ["window": 3, "ref": ref]),
                client: MCPClientID(1), perform: { _, _ in .answer([:]) })
            XCTAssertEqual(try errorCode(data), -32602, "\(tool) \(ref)")
            let message = try XCTUnwrap((try decode(data)["error"] as? [String: Any])?["message"] as? String)
            XCTAssertTrue(message.contains("ref must look like e12: use a ref from ui_tree"), message)
        }
        let response = try decode(await MCPDispatcher.handle(
            line: request(2, "tools/list", [:]),
            client: MCPClientID(1), perform: { _, _ in .answer([:]) }))
        let tools = try XCTUnwrap((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        for name in ["tap", "screenshot"] {
            let tool = try XCTUnwrap(tools.first { $0["name"] as? String == name })
            let ref = ((tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["ref"] as? [String: Any]
            XCTAssertEqual(ref?["pattern"] as? String, "^e[0-9]+$", name)
        }
    }

    // [MCP-71] T10: the tap and ui_tree descriptions state the key rule.
    func testTheRefRuleIsOneSentence() async throws {
        let target = "A ref names one element for as long as it is on screen, across reads; a ref whose element is gone is refused."
        let s1 = "A ref works only from the window's latest tree; an older one is refused."
        let response = try decode(await MCPDispatcher.handle(
            line: request(2, "tools/list", [:]),
            client: MCPClientID(1), perform: { _, _ in .answer([:]) }))
        let tools = try XCTUnwrap((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        for name in ["tap", "ui_tree"] {
            let tool = try XCTUnwrap(tools.first { $0["name"] as? String == name })
            let text = MCPJSON.string(tool)
            XCTAssertTrue(text.contains(target), name)
            XCTAssertFalse(text.contains(s1), name)
        }
    }

    // MARK: descriptions and the tool set (plan T2, #172)

    private func listedTools(devTools: Bool) async throws -> [[String: Any]] {
        let response = try decode(await MCPDispatcher.handle(
            line: request(2, "tools/list", [:]), client: MCPClientID(1), devTools: devTools,
            perform: { _, _ in .answer([:]) }))
        return try XCTUnwrap((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
    }

    /// A tool's own description and every argument's.
    private func descriptions(_ tool: [String: Any]) -> [String] {
        var texts = [tool["description"] as? String ?? ""]
        let properties = (tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        for (_, property) in properties {
            if let text = (property as? [String: Any])?["description"] as? String { texts.append(text) }
        }
        return texts
    }

    // [MCP-7] "window" for any window; "Phone Mirror" only where it means the
    // phone's own screen: press_key's home and recents.
    func testNoDescriptionCallsEveryWindowAPhoneMirror() async throws {
        let allowed = "home and recents act only in the Phone Mirror"
        let tools = try await listedTools(devTools: true)
        for tool in tools {
            let name = tool["name"] as? String ?? "?"
            for text in descriptions(tool) {
                let rest = name == "press_key" ? text.replacingOccurrences(of: allowed, with: "") : text
                XCTAssertFalse(rest.contains("Phone Mirror"), "\(name): \(text)")
            }
        }
        let press = try XCTUnwrap(tools.first { $0["name"] as? String == "press_key" })
        XCTAssertTrue((press["description"] as? String ?? "").contains(allowed))
    }

    /// The tools table of docs/design/mcp.md: name → description cell.
    private func designDocDescriptions() throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("docs/design/mcp.md"), encoding: .utf8)
        var rows: [String: String] = [:]
        var inTools = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") { inTools = line == "## Tools"; continue }
            guard inTools, line.hasPrefix("| `"), line.hasSuffix(" |") else { continue }
            let body = line.dropFirst(2).dropLast(2)
            guard let nameEnd = body.range(of: " | "),
                  let descriptionStart = body.range(of: " | ", options: .backwards) else { continue }
            let name = body[..<nameEnd.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            rows[name] = String(body[descriptionStart.upperBound...])
        }
        return rows
    }

    // [MCP-7] tools/list's descriptions are design/mcp.md's, byte for byte,
    // and the two name the same tools.
    func testDescriptionsMatchTheDesignDoc() async throws {
        let doc = try designDocDescriptions()
        XCTAssertFalse(doc.isEmpty, "no tools table in docs/design/mcp.md")
        var listed: [String: String] = [:]
        for tool in try await listedTools(devTools: true) {
            listed[tool["name"] as? String ?? "?"] = tool["description"] as? String ?? ""
        }
        XCTAssertEqual(Set(listed.keys), Set(doc.keys))
        for (name, description) in doc {
            XCTAssertEqual(listed[name], description, name)
        }
    }

    // [MCP-88] holdMs on tap is the long press; long_press is gone.
    func testTapHoldReplacesLongPress() async throws {
        let names = try await listedTools(devTools: true).compactMap { $0["name"] as? String }
        XCTAssertFalse(names.contains("long_press"))
        let gone = await MCPDispatcher.handle(
            line: callRequest("long_press", ["window": 3, "x": 0.5, "y": 0.5, "ms": 800]),
            client: MCPClientID(1), perform: { _, _ in .answer([:]) })
        XCTAssertEqual(try errorCode(gone), -32602)

        XCTAssertEqual(try MCPArguments.call("tap", ["window": 3, "x": 0.5, "y": 0.5, "holdMs": 800]),
                       .tap(window: 3, x: 0.5, y: 0.5, holdMs: 800))
        XCTAssertEqual(try MCPArguments.call("tap", ["window": 3, "ref": "e4", "holdMs": 800]),
                       .tapRef(window: 3, ref: "e4", holdMs: 800))
        XCTAssertEqual(try MCPArguments.call("tap", ["window": 3, "x": 0.5, "y": 0.5]),
                       .tap(window: 3, x: 0.5, y: 0.5, holdMs: nil))
        for bad: Any in [3001, 0, 1.5, "800"] {
            let data = await MCPDispatcher.handle(
                line: callRequest("tap", ["window": 3, "x": 0.5, "y": 0.5, "holdMs": bad]),
                client: MCPClientID(1), perform: { _, _ in .answer([:]) })
            XCTAssertEqual(try errorCode(data), -32602, "holdMs \(bad)")
        }
    }

    // [MCP-90] The points form and the direction form are exclusive.
    func testSwipeTakesPointsOrADirectionNotBoth() async throws {
        let refused: [[String: Any]] = [
            ["window": 3, "direction": "up", "x1": 0.1],
            ["window": 3, "direction": "up", "x1": 0.1, "y1": 0.1, "x2": 0.9, "y2": 0.9],
            ["window": 3, "ref": "e1"],
            ["window": 3, "ref": "e1", "x1": 0.1, "y1": 0.1, "x2": 0.9, "y2": 0.9],
            ["window": 3],
            ["window": 3, "direction": "sideways"],
            ["window": 3, "x1": 0.1, "y1": 0.1, "x2": 0.9],
        ]
        for args in refused {
            let data = await MCPDispatcher.handle(line: callRequest("swipe", args), client: MCPClientID(1),
                                                  perform: { _, _ in .answer([:]) })
            XCTAssertEqual(try errorCode(data), -32602, "\(args)")
        }
        XCTAssertEqual(try MCPArguments.call("swipe", ["window": 3, "direction": "up"]),
                       .swipeDirection(window: 3, direction: .up, ref: nil, ms: 300))
        XCTAssertEqual(try MCPArguments.call("swipe", ["window": 3, "direction": "left", "ref": "e1", "ms": 500]),
                       .swipeDirection(window: 3, direction: .left, ref: "e1", ms: 500))
        XCTAssertEqual(try MCPArguments.call("swipe", ["window": 3, "x1": 0.1, "y1": 0.2, "x2": 0.9, "y2": 0.8]),
                       .swipe(window: 3, x1: 0.1, y1: 0.2, x2: 0.9, y2: 0.8, ms: 300))
    }

    // [MCP-99] input_probe exists only while the app runs with --mcp-dev-tools.
    func testInputProbeIsListedOnlyWithDevTools() async throws {
        let without = try await listedTools(devTools: false).compactMap { $0["name"] as? String }
        XCTAssertEqual(without.count, 14, "\(without)")
        XCTAssertFalse(without.contains("input_probe"))
        let probe = ["window": 3, "x": 0.5, "y": 0.5] as [String: Any]
        let refused = await MCPDispatcher.handle(line: callRequest("input_probe", probe), client: MCPClientID(1),
                                                 perform: { _, _ in .answer([:]) })
        XCTAssertEqual(try errorCode(refused), -32602)
        let message = (try decode(refused)["error"] as? [String: Any])?["message"] as? String
        XCTAssertEqual(message, "Unknown tool: input_probe")

        let with = try await listedTools(devTools: true).compactMap { $0["name"] as? String }
        XCTAssertEqual(with.count, 15, "\(with)")
        XCTAssertTrue(with.contains("input_probe"))
        let recorder = Recorder()
        let accepted = try decode(await MCPDispatcher.handle(
            line: callRequest("input_probe", probe), client: MCPClientID(1), devTools: true,
            perform: { call, _ in recorder.add(call); return .answer(["ok": true]) }))
        XCTAssertNil(accepted["error"])
        XCTAssertEqual(recorder.calls, [.inputProbe(window: 3, x: 0.5, y: 0.5, width: nil, height: nil)])
    }

    // MARK: wait (plan T11)

    // [MCP-96]
    func testWaitNeedsMsOrText() async throws {
        let none = await MCPDispatcher.handle(line: callRequest("wait", ["window": 3]),
                                              client: MCPClientID(1), perform: { _, _ in .answer([:]) })
        XCTAssertEqual(try errorCode(none), -32602)
        let error = try XCTUnwrap(try decode(none)["error"] as? [String: Any])
        XCTAssertEqual(error["message"] as? String, "wait needs ms, text or settle")
        let long = await MCPDispatcher.handle(line: callRequest("wait", ["window": 3, "ms": 30001]),
                                              client: MCPClientID(1), perform: { _, _ in .answer([:]) })
        XCTAssertEqual(try errorCode(long), -32602)
        XCTAssertEqual(try MCPArguments.call("wait", ["window": 3, "ms": 5000]),
                       .wait(window: 3, mode: .clock(ms: 5000), timeoutMs: 10000, observe: .tree))
        XCTAssertEqual(try MCPArguments.call("wait", ["window": 3, "text": "Continue", "gone": true,
                                                      "timeoutMs": 1500]),
                       .wait(window: 3, mode: .text("Continue", gone: true), timeoutMs: 1500, observe: .tree))
        XCTAssertThrowsError(try MCPArguments.call("wait", ["window": 3, "text": "a", "timeoutMs": 30001]))
    }

    // [MCP-111]
    func testSettleTakesNoMsOrText() async throws {
        let data = await MCPDispatcher.handle(
            line: callRequest("wait", ["window": 3, "settle": true, "ms": 500]),
            client: MCPClientID(1), perform: { _, _ in .answer([:]) })
        XCTAssertEqual(try errorCode(data), -32602)
        XCTAssertThrowsError(try MCPArguments.call("wait", ["window": 3, "settle": true, "text": "a"]))
        XCTAssertEqual(try MCPArguments.call("wait", ["window": 3, "settle": true]),
                       .wait(window: 3, mode: .settle, timeoutMs: 10000, observe: .tree))
    }
}

// MARK: - T5: wait and observe on every action (MCP-64, MCP-80, MCP-82)

final class MCPActArgumentTests: XCTestCase {
    func testObserveDefaultsToTree_MCP82() throws {
        XCTAssertEqual(try MCPArguments.call("tap", ["window": 3, "x": 0.5, "y": 0.5]),
                       .tap(window: 3, x: 0.5, y: 0.5, wait: .settle, observe: .tree))
        XCTAssertEqual(try MCPArguments.call("press_key", ["window": 3, "key": "back"]),
                       .pressKey(window: 3, key: .back, wait: .settle, observe: .tree))
        XCTAssertEqual(try MCPArguments.call("ui_tree", ["window": 3]), .uiTree(window: 3, wait: .none))
        XCTAssertEqual(try MCPArguments.call("screenshot", ["window": 3]),
                       .screenshot(window: 3, ref: nil, wait: .none))
    }

    func testShapeIsPhoneOrWindow_MCP100() throws {
        XCTAssertEqual(try MCPArguments.call("open_app", ["app": "Shop"]),
                       .openApp("Shop", newWindow: false, shape: .phone))
        XCTAssertEqual(try MCPArguments.call("open_app", ["app": "Shop", "shape": "window"]),
                       .openApp("Shop", newWindow: false, shape: .window))
        XCTAssertEqual(try MCPArguments.call("send_link", ["url": "https://example.com"]),
                       .sendLink("https://example.com", shape: .phone))
        XCTAssertEqual(try MCPArguments.call("send_link", ["url": "https://example.com", "shape": "window"]),
                       .sendLink("https://example.com", shape: .window))
        XCTAssertThrowsError(try MCPArguments.call("open_app", ["app": "Shop", "shape": "tablet"])) {
            XCTAssertTrue($0 is MCPArgumentError)
        }
        let schema = MCPTools.tool("open_app")?.schema["properties"] as? [String: Any]
        let shape = schema?["shape"] as? [String: Any]
        XCTAssertEqual(shape?["enum"] as? [String], ["phone", "window"])
    }

    func testWaitAndObserveAreTakenOnEveryAction_MCP81_MCP82() throws {
        let act: [String: Any] = ["wait": "none", "observe": "none"]
        func with(_ args: [String: Any]) -> [String: Any] { args.merging(act) { a, _ in a } }
        XCTAssertEqual(try MCPArguments.call("tap", with(["window": 3, "ref": "e2"])),
                       .tapRef(window: 3, ref: "e2", wait: .none, observe: .none))
        XCTAssertEqual(try MCPArguments.call("tap", with(["window": 3, "x": 0, "y": 1, "holdMs": 10])),
                       .tap(window: 3, x: 0, y: 1, holdMs: 10, wait: .none, observe: .none))
        XCTAssertEqual(try MCPArguments.call("swipe", with(["window": 3, "direction": "up"])),
                       .swipeDirection(window: 3, direction: .up, ref: nil, ms: 300, wait: .none, observe: .none))
        XCTAssertEqual(try MCPArguments.call("swipe", with(["window": 3, "x1": 0, "y1": 0, "x2": 1, "y2": 1, "ms": 10])),
                       .swipe(window: 3, x1: 0, y1: 0, x2: 1, y2: 1, ms: 10, wait: .none, observe: .none))
        XCTAssertEqual(try MCPArguments.call("type_text", with(["window": 3, "text": "a"])),
                       .typeText(window: 3, text: "a", wait: .none, observe: .none))
        XCTAssertEqual(try MCPArguments.call("screenshot", ["window": 3, "wait": "settle"]),
                       .screenshot(window: 3, ref: nil, wait: .settle))
        XCTAssertEqual(try MCPArguments.call("ui_tree", ["window": 3, "wait": "settle"]),
                       .uiTree(window: 3, wait: .settle))
        XCTAssertThrowsError(try MCPArguments.call("tap", ["window": 3, "x": 0.5, "y": 0.5, "wait": "forever"]))
        XCTAssertThrowsError(try MCPArguments.call("tap", ["window": 3, "x": 0.5, "y": 0.5, "observe": 1]))
        XCTAssertThrowsError(try MCPArguments.call("ui_tree", ["window": 3, "observe": "tree"]))
    }

    /// [MCP-84] `alsoActed` can name only the person: every agent input is
    /// sent by the call holding the window's turn, so no call can see another
    /// agent's input (#262).
    func testAlsoActedNamesOnlyThePerson_MCP84() {
        for tool: MCPToolName in [.tap, .swipe, .typeText, .pressKey] {
            let properties = MCPOutputSchemas.schema(for: tool)["properties"] as? [String: Any] ?? [:]
            let items = (properties["alsoActed"] as? [String: Any])?["items"] as? [String: Any]
            XCTAssertEqual(items?["enum"] as? [String], ["person"], "\(tool)")
        }
    }

    func testInputAnswersDeclareTheEnvelopeAndNoOk_MCP80() {
        for tool: MCPToolName in [.tap, .swipe, .typeText, .pressKey] {
            let schema = MCPOutputSchemas.schema(for: tool)
            let properties = schema["properties"] as? [String: Any] ?? [:]
            XCTAssertNil(properties["ok"], "\(tool)")
            XCTAssertEqual(Set(schema["required"] as? [String] ?? []),
                           ["window", "did", "on", "settle", "state", "frame"], "\(tool)")
            for key in ["alsoActed", "closed", "tree", "treeError"] {
                XCTAssertNotNil(properties[key], "\(tool) \(key)")
            }
        }
    }
}
