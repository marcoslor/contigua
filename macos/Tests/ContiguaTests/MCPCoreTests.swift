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
            perform: { _ in .text("never") }))
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
            perform: { _ in .text("never") })
        XCTAssertNil(data)
    }

    func testPingAnswersAnEmptyResult() async throws {
        let response = try decode(await MCPDispatcher.handle(
            line: request(7, "ping"), perform: { _ in .text("never") }))
        XCTAssertEqual((response["result"] as? [String: Any])?.count, 0)
    }

    // MARK: tools/list

    func testToolListIsStable() async throws {
        let response = try decode(await MCPDispatcher.handle(
            line: request(2, "tools/list", [:]),
            perform: { _ in .text("never") }))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, [
            "phone_status", "list_apps", "open_app", "list_windows", "screenshot", "ui_tree",
            "tap", "long_press", "swipe", "type_text", "press_key",
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
                "ref": ["type": "string", "minLength": 1, "maxLength": 32,
                        "description": "Element ref from ui_tree, e.g. \"s13e5\". Takes precedence over x and y."],
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
            ("screenshot", ["window": 3], .screenshot(window: 3)),
            ("ui_tree", ["window": 3], .uiTree(window: 3)),
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
            perform: { call in recorder.add(call); return .text("ok") }))
        XCTAssertEqual(recorder.calls, [.tap(window: 4, x: 0.5, y: 0.75)])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNil(result["isError"])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        XCTAssertEqual(content.first?["text"] as? String, "ok")
    }

    func testRuntimeFailureIsAToolErrorNotAProtocolError() async throws {
        let response = try decode(await MCPDispatcher.handle(
            line: callRequest("screenshot", ["window": 7]),
            perform: { _ in .error("No window 7.") }))
        XCTAssertNil(response["error"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "No window 7.")
    }

    func testImageResultCarriesBase64PNG() async throws {
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        let response = try decode(await MCPDispatcher.handle(
            line: callRequest("screenshot", ["window": 1]),
            perform: { _ in .image(png) }))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "image")
        XCTAssertEqual(content.first?["mimeType"] as? String, "image/png")
        XCTAssertEqual(Data(base64Encoded: content.first?["data"] as? String ?? ""), png)
    }

    func testUnknownToolIsInvalidParams() async throws {
        let data = await MCPDispatcher.handle(
            line: callRequest("teleport", ["window": 1]),
            perform: { _ in .text("never") })
        XCTAssertEqual(try errorCode(data), -32602)
    }

    func testInvalidArgumentsAreInvalidParams() async throws {
        let data = await MCPDispatcher.handle(
            line: callRequest("tap", ["window": 1, "x": 9, "y": 0.5]),
            perform: { _ in .text("never") })
        XCTAssertEqual(try errorCode(data), -32602)
    }

    func testUnknownMethodIsMethodNotFound() async throws {
        let data = await MCPDispatcher.handle(
            line: request(3, "resources/list"), perform: { _ in .text("never") })
        XCTAssertEqual(try errorCode(data), -32601)
    }

    // MARK: protocol faults

    func testMalformedJSONIsAParseError() async throws {
        let data = await MCPDispatcher.handle(
            line: Data("{not json\n".utf8), perform: { _ in .text("never") })
        XCTAssertEqual(try errorCode(data), -32700)
    }

    func testNonObjectAndWrongVersionAreInvalidRequests() async throws {
        let array = await MCPDispatcher.handle(
            line: Data("[1,2]\n".utf8), perform: { _ in .text("never") })
        XCTAssertEqual(try errorCode(array), -32600)
        let version = await MCPDispatcher.handle(
            line: line(["jsonrpc": "1.0", "id": 1, "method": "ping"]),
            perform: { _ in .text("never") })
        XCTAssertEqual(try errorCode(version), -32600)
        let badId = await MCPDispatcher.handle(
            line: line(["jsonrpc": "2.0", "id": 1.5, "method": "ping"]),
            perform: { _ in .text("never") })
        XCTAssertEqual(try errorCode(badId), -32600)
    }

    func testAnOversizedLineIsRefused() async throws {
        let oversized = Data(repeating: 0x20, count: MCPProtocol.maxLineBytes + 1)
        let data = await MCPDispatcher.handle(line: oversized, perform: { _ in .text("never") })
        XCTAssertEqual(try errorCode(data), -32600)
    }
}
