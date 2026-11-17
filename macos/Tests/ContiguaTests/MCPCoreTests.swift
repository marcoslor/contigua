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
            "wait", "tap", "long_press", "swipe", "type_text", "press_key",
            "input_probe", "close_window", "send_link", "send_file",
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
                // MCP-81, MCP-82 (T5).
                "wait": ["type": "string", "enum": ["settle", "none"],
                         "description": "settle (the default for an action) waits until the window's accessibility tree has not changed for 300 ms and nothing on it is loading, at most 2 s; none answers at once."],
                "observe": ["type": "string", "enum": ["tree", "none"],
                            "description": "tree (the default) returns the ui_tree answer read after the settle; none returns no screen."],
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
            ("list_apps", [:], .listApps),
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
            ("long_press", ["window": 3, "x": 0, "y": 0.5, "ms": 3000],
             .longPress(window: 3, x: 0, y: 0.5, ms: 3000)),
            ("swipe", ["window": 3, "x1": 0.1, "y1": 0.2, "x2": 0.9, "y2": 0.8, "ms": 2000],
             .swipe(window: 3, x1: 0.1, y1: 0.2, x2: 0.9, y2: 0.8, ms: 2000)),
            ("type_text", ["window": 3, "text": "hello"], .typeText(window: 3, text: "hello")),
            ("press_key", ["window": 3, "key": "enter"], .pressKey(window: 3, key: .enter)),
            ("input_probe", ["window": 3, "x": 0.5, "y": 0.5],
             .inputProbe(window: 3, x: 0.5, y: 0.5, width: nil, height: nil)),
            ("input_probe", ["window": 3, "x": 0.5, "y": 0.5, "w": 0.4, "h": 0.4],
             .inputProbe(window: 3, x: 0.5, y: 0.5, width: 0.4, height: 0.4)),
            ("close_window", ["window": 3], .closeWindow(window: 3)),
            ("send_link", ["url": "https://example.com"], .sendLink("https://example.com")),
            ("send_file", ["path": "/tmp/a.bin"], .sendFile("/tmp/a.bin")),
        ]
        XCTAssertEqual(Set(cases.map { $0.0 }), Set(toolNames()))
        for (name, args, expected) in cases {
            XCTAssertEqual(try MCPArguments.call(name, args), expected, name)
        }
    }

    func testEveryToolRejectsMissingRequiredArguments() {
        for tool in MCPTools.all {
            let required = tool.schema["required"] as? [String] ?? []
            guard !required.isEmpty else { continue }
            XCTAssertThrowsError(try MCPArguments.call(tool.name.rawValue, [:]), tool.name.rawValue) { error in
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
            ["window": 1, "x": 0.5, "y": 0.5, "w": 0.01]))
        XCTAssertThrowsError(try MCPArguments.call("input_probe",
            ["window": 1, "x": 0.5, "y": 0.5, "h": 1.01]))
    }

    func testWindowMustBeAPositiveInteger() {
        for bad: Any in [0, -1, 1.5, "1", true] {
            XCTAssertThrowsError(try MCPArguments.call("tap",
                ["window": bad, "x": 0.5, "y": 0.5]), "\(bad)")
        }
        XCTAssertThrowsError(try MCPArguments.call("screenshot", ["window": 1_000_001]))
    }

    func testGestureDurationsAreCapped() {
        XCTAssertThrowsError(try MCPArguments.call("long_press",
            ["window": 1, "x": 0.5, "y": 0.5, "ms": 3001]))
        XCTAssertThrowsError(try MCPArguments.call("long_press",
            ["window": 1, "x": 0.5, "y": 0.5, "ms": 0]))
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
            line: request(2, "tools/list"), client: MCPClientID(1),
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
        for tool: MCPToolName in [.screenshot, .uiTree, .tap, .longPress, .swipe, .typeText,
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
        XCTAssertEqual(try MCPArguments.call("long_press", with(["window": 3, "x": 0, "y": 1, "ms": 10])),
                       .longPress(window: 3, x: 0, y: 1, ms: 10, wait: .none, observe: .none))
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

    func testInputAnswersDeclareTheEnvelopeAndNoOk_MCP80() {
        for tool: MCPToolName in [.tap, .longPress, .swipe, .typeText, .pressKey] {
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
