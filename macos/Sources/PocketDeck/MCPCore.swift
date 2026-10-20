// The pure half of the automation server (docs/design/mcp.md): MCP revision
// 2025-06-18 over newline-delimited JSON-RPC 2.0. Parsing, the initialize /
// tools/list / tools/call dispatch, the tool schemas and argument validation
// live here, with no AppKit, no session and no socket: the unit tests drive this
// directly and the app's socket server hands it lines.
//
// Everything an agent is allowed to ask for becomes one `MCPCall` with validated
// arguments; anything malformed stays a JSON-RPC protocol error. Failures from
// the moment a call runs are tool results with `isError: true` instead.

import Foundation

enum MCPProtocol {
    /// The revision this server implements.
    static let version = "2025-06-18"
    static let serverName = "pocketdeck"
    static let serverVersion = "0.2.0"
    /// One request per line; a longer line is refused unread.
    static let maxLineBytes = 1 << 20
}

/// JSON values bridge NSNumber to Bool for 0/1, so "is this a boolean" must ask
/// CoreFoundation's type, not Swift's.
enum MCPValue {
    static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

// MARK: - Tools

enum MCPToolName: String, CaseIterable {
    case phoneStatus = "phone_status"
    case listApps = "list_apps"
    case openApp = "open_app"
    case listWindows = "list_windows"
    case screenshot
    case tap
    case longPress = "long_press"
    case swipe
    case typeText = "type_text"
    case pressKey = "press_key"
    case closeWindow = "close_window"
    case sendLink = "send_link"
    case sendFile = "send_file"
}

/// One key `press_key` may send. back/home/recents are the session's nav
/// actions, the rest are Android keycodes (docs/PROTOCOL.md "KEY").
enum MCPKey: String, CaseIterable {
    case back, home, recents, enter, delete, tab, escape, up, down, left, right

    /// Android KEYCODE_*, nil for the nav actions.
    var keycode: UInt32? {
        switch self {
        case .back, .home, .recents: return nil
        case .enter: return 66
        case .delete: return 67
        case .tab: return 61
        case .escape: return 111
        case .up: return 19
        case .down: return 20
        case .left: return 21
        case .right: return 22
        }
    }

    /// The nav action for the three keys that are not KEY frames.
    var navAction: String? {
        switch self {
        case .back, .home, .recents: return rawValue
        default: return nil
        }
    }
}

/// A validated tool call: exactly what the tools layer may execute.
enum MCPCall: Equatable {
    case phoneStatus
    case listApps
    case openApp(String)
    case listWindows
    case screenshot(window: Int)
    case tap(window: Int, x: Double, y: Double)
    case longPress(window: Int, x: Double, y: Double, ms: Int)
    case swipe(window: Int, x1: Double, y1: Double, x2: Double, y2: Double, ms: Int)
    case typeText(window: Int, text: String)
    case pressKey(window: Int, key: MCPKey)
    case closeWindow(window: Int)
    case sendLink(String)
    case sendFile(String)
}

/// What executing a call gave. `.image` is PNG bytes.
enum MCPToolResult: Equatable {
    case text(String)
    case image(Data)
    case error(String)
}

/// Argument validation errors are protocol faults (`-32602`), not tool errors.
struct MCPArgumentError: Error, Equatable {
    let message: String
}

// MARK: - Schemas

struct MCPTool {
    let name: MCPToolName
    let description: String
    let schema: [String: Any]

    var object: [String: Any] {
        ["name": name.rawValue, "description": description, "inputSchema": schema]
    }
}

enum MCPTools {
    static let window: [String: Any] = [
        "type": "integer", "minimum": 1, "maximum": 1_000_000,
        "description": "Window id from list_windows.",
    ]
    static let pointX: [String: Any] = [
        "type": "number", "minimum": 0, "maximum": 1,
        "description": "Horizontal position, 0 (left) to 1 (right), in the window's video rect.",
    ]
    static let pointY: [String: Any] = [
        "type": "number", "minimum": 0, "maximum": 1,
        "description": "Vertical position, 0 (top) to 1 (bottom), in the window's video rect.",
    ]

    private static func object(_ properties: [String: Any], required: [String]) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties,
                                     "additionalProperties": false]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    private static func duration(_ maximum: Int) -> [String: Any] {
        ["type": "integer", "minimum": 1, "maximum": maximum,
         "description": "How long the gesture lasts, in milliseconds (at most \(maximum))."]
    }

    /// The list `tools/list` returns, in a fixed order.
    static let all: [MCPTool] = [
        MCPTool(name: .phoneStatus,
                description: "The connected phone: name, battery, charging, lock state and open windows.",
                schema: object([:], required: [])),
        MCPTool(name: .listApps,
                description: "Every app the phone reports, with its label and package name.",
                schema: object([:], required: [])),
        MCPTool(name: .openApp,
                description: "Open a phone app in a PocketDeck window; returns that window's id.",
                schema: object([
                    "app": ["type": "string", "minLength": 1, "maxLength": 200,
                            "description": "Package name or app label (or a unique prefix)."],
                ], required: ["app"])),
        MCPTool(name: .listWindows,
                description: "The open phone windows: id, package, and stream size in pixels.",
                schema: object([:], required: [])),
        MCPTool(name: .screenshot,
                description: "PNG of the last frame the window displayed, longest side at most 1280 px.",
                schema: object(["window": window], required: ["window"])),
        MCPTool(name: .tap,
                description: "Tap a point in a phone window.",
                schema: object(["window": window, "x": pointX, "y": pointY],
                               required: ["window", "x", "y"])),
        MCPTool(name: .longPress,
                description: "Press and hold a point in a phone window.",
                schema: object(["window": window, "x": pointX, "y": pointY,
                                "ms": duration(3000)],
                               required: ["window", "x", "y"])),
        MCPTool(name: .swipe,
                description: "Swipe from one point to another in a phone window.",
                schema: object([
                    "window": window, "x1": pointX, "y1": pointY, "x2": pointX, "y2": pointY,
                    "ms": duration(2000),
                ], required: ["window", "x1", "y1", "x2", "y2"])),
        MCPTool(name: .typeText,
                description: "Type text into a phone window, on the same path as the keyboard.",
                schema: object([
                    "window": window,
                    "text": ["type": "string", "maxLength": 2000,
                             "description": "Up to 2000 characters."],
                ], required: ["window", "text"])),
        MCPTool(name: .pressKey,
                description: "Press one key in a phone window.",
                schema: object([
                    "window": window,
                    "key": ["type": "string",
                            "enum": MCPKey.allCases.map(\.rawValue),
                            "description": "back, home and recents are navigation; the rest are keys."],
                ], required: ["window", "key"])),
        MCPTool(name: .closeWindow,
                description: "Close a phone window the way its close button does.",
                schema: object(["window": window], required: ["window"])),
        MCPTool(name: .sendLink,
                description: "Send a link to the phone (http, https, geo, tel or mailto).",
                schema: object([
                    "url": ["type": "string", "minLength": 1, "maxLength": 8192,
                            "description": "The link to open on the phone."],
                ], required: ["url"])),
        MCPTool(name: .sendFile,
                description: "Send one local file to the phone's Download/PocketDeck folder.",
                schema: object([
                    "path": ["type": "string", "minLength": 1, "maxLength": 4096,
                             "description": "Absolute path of a regular, readable file."],
                ], required: ["path"])),
    ]

    static func tool(_ name: String) -> MCPTool? {
        all.first { $0.name.rawValue == name }
    }
}

// MARK: - Argument validation

enum MCPArguments {
    private static func rejectUnknown(_ args: [String: Any], _ tool: MCPTool) throws {
        let properties = tool.schema["properties"] as? [String: Any] ?? [:]
        let known = Set(properties.keys)
        if let extra = Set(args.keys).subtracting(known).sorted().first {
            throw MCPArgumentError(message: "unknown argument “\(extra)”")
        }
    }

    private static func number(_ args: [String: Any], _ key: String) throws -> Double {
        guard let raw = args[key] else { throw MCPArgumentError(message: "missing “\(key)”") }
        guard !MCPValue.isBool(raw), let value = raw as? NSNumber else {
            throw MCPArgumentError(message: "“\(key)” must be a number")
        }
        let number = value.doubleValue
        guard number.isFinite else { throw MCPArgumentError(message: "“\(key)” must be a finite number") }
        return number
    }

    private static func string(_ args: [String: Any], _ key: String,
                               minimum: Int = 1, maximum: Int) throws -> String {
        guard let raw = args[key] else { throw MCPArgumentError(message: "missing “\(key)”") }
        guard let value = raw as? String else {
            throw MCPArgumentError(message: "“\(key)” must be a string")
        }
        guard value.count >= minimum else {
            throw MCPArgumentError(message: "“\(key)” must not be empty")
        }
        guard value.count <= maximum else {
            throw MCPArgumentError(message: "“\(key)” is longer than \(maximum) characters")
        }
        return value
    }

    private static func integer(_ args: [String: Any], _ key: String,
                                minimum: Int, maximum: Int) throws -> Int {
        let value = try number(args, key)
        guard value == value.rounded(), value >= Double(minimum), value <= Double(maximum) else {
            throw MCPArgumentError(message: "“\(key)” must be an integer from \(minimum) to \(maximum)")
        }
        return Int(value)
    }

    private static func coordinate(_ args: [String: Any], _ key: String) throws -> Double {
        let value = try number(args, key)
        guard (0...1).contains(value) else {
            throw MCPArgumentError(message: "“\(key)” must be between 0 and 1")
        }
        return value
    }

    /// Validate `arguments` for a known tool. Throws `MCPArgumentError`; the
    /// dispatcher turns that into `-32602`.
    static func call(_ name: String, _ args: [String: Any]) throws -> MCPCall {
        guard let tool = MCPTools.tool(name) else {
            throw MCPArgumentError(message: "Unknown tool: \(name)")
        }
        try rejectUnknown(args, tool)
        switch tool.name {
        case .phoneStatus:
            return .phoneStatus
        case .listApps:
            return .listApps
        case .openApp:
            return .openApp(try string(args, "app", maximum: 200))
        case .listWindows:
            return .listWindows
        case .screenshot:
            return .screenshot(window: try integer(args, "window", minimum: 1, maximum: 1_000_000))
        case .tap:
            return .tap(window: try integer(args, "window", minimum: 1, maximum: 1_000_000),
                        x: try coordinate(args, "x"), y: try coordinate(args, "y"))
        case .longPress:
            return .longPress(window: try integer(args, "window", minimum: 1, maximum: 1_000_000),
                              x: try coordinate(args, "x"), y: try coordinate(args, "y"),
                              ms: try integer(args, "ms", minimum: 1, maximum: 3000))
        case .swipe:
            return .swipe(window: try integer(args, "window", minimum: 1, maximum: 1_000_000),
                          x1: try coordinate(args, "x1"), y1: try coordinate(args, "y1"),
                          x2: try coordinate(args, "x2"), y2: try coordinate(args, "y2"),
                          ms: try integer(args, "ms", minimum: 1, maximum: 2000))
        case .typeText:
            return .typeText(window: try integer(args, "window", minimum: 1, maximum: 1_000_000),
                             text: try string(args, "text", minimum: 0, maximum: 2000))
        case .pressKey:
            let window = try integer(args, "window", minimum: 1, maximum: 1_000_000)
            let raw = try string(args, "key", maximum: 20)
            guard let key = MCPKey(rawValue: raw) else {
                throw MCPArgumentError(message: "“key” must be one of \(MCPKey.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return .pressKey(window: window, key: key)
        case .closeWindow:
            return .closeWindow(window: try integer(args, "window", minimum: 1, maximum: 1_000_000))
        case .sendLink:
            return .sendLink(try string(args, "url", maximum: 8192))
        case .sendFile:
            return .sendFile(try string(args, "path", maximum: 4096))
        }
    }
}

// MARK: - JSON-RPC

enum MCPID: Equatable {
    case string(String)
    case number(Int)
}

private struct MCPRequest {
    let id: MCPID?
    let method: String
    let params: [String: Any]
}

private enum MCPParseError: Error {
    case parse
    case request(String)
    case params(String)
}

/// The JSON-RPC code for an argument or tool-name fault.
private let mcpInvalidParams = -32602

enum MCPDispatcher {
    /// Handle one line. Returns nil for notifications (no `id`), otherwise one
    /// response line ending in a newline.
    static func handle(line: Data,
                       perform: (MCPCall) async -> MCPToolResult,
                       log: ((MCPToolName, TimeInterval) -> Void)? = nil) async -> Data? {
        guard line.count <= MCPProtocol.maxLineBytes else {
            return errorLine(id: nil, code: -32600,
                             message: "Request line is longer than 1 MiB")
        }
        let request: MCPRequest
        do {
            request = try parse(line)
        } catch MCPParseError.parse {
            return errorLine(id: nil, code: -32700, message: "Parse error")
        } catch MCPParseError.request(let message) {
            return errorLine(id: nil, code: -32600, message: message)
        } catch MCPParseError.params(let message) {
            return errorLine(id: nil, code: mcpInvalidParams, message: message)
        } catch {
            return errorLine(id: nil, code: -32700, message: "Parse error")
        }
        guard let id = request.id else { return nil }
        switch request.method {
        case "initialize":
            return resultLine(id: id, result: [
                "protocolVersion": MCPProtocol.version,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": MCPProtocol.serverName,
                               "version": MCPProtocol.serverVersion],
            ])
        case "ping":
            return resultLine(id: id, result: [:])
        case "tools/list":
            return resultLine(id: id, result: ["tools": MCPTools.all.map(\.object)])
        case "tools/call":
            return await toolCall(id: id, params: request.params, perform: perform, log: log)
        default:
            return errorLine(id: id, code: -32601, message: "Method not found: \(request.method)")
        }
    }

    private static func toolCall(id: MCPID, params: [String: Any],
                                 perform: (MCPCall) async -> MCPToolResult,
                                 log: ((MCPToolName, TimeInterval) -> Void)?) async -> Data {
        guard let name = params["name"] as? String, !name.isEmpty else {
            return errorLine(id: id, code: mcpInvalidParams, message: "tools/call needs a tool name")
        }
        let arguments = params["arguments"] ?? [String: Any]()
        guard let args = arguments as? [String: Any] else {
            return errorLine(id: id, code: mcpInvalidParams, message: "arguments must be an object")
        }
        let call: MCPCall
        do {
            call = try MCPArguments.call(name, args)
        } catch let argumentError as MCPArgumentError {
            return errorLine(id: id, code: mcpInvalidParams, message: argumentError.message)
        } catch {
            return errorLine(id: id, code: mcpInvalidParams, message: "Invalid arguments")
        }
        guard let tool = MCPToolName(rawValue: name) else {
            return errorLine(id: id, code: mcpInvalidParams, message: "Unknown tool: \(name)")
        }
        let started = ProcessInfo.processInfo.systemUptime
        let outcome = await perform(call)
        if let log {
            log(tool, ProcessInfo.processInfo.systemUptime - started)
        }
        return resultLine(id: id, result: resultBody(outcome))
    }

    private static func resultBody(_ outcome: MCPToolResult) -> [String: Any] {
        switch outcome {
        case .text(let text):
            return ["content": [["type": "text", "text": text]]]
        case .image(let data):
            return ["content": [["type": "image", "data": data.base64EncodedString(),
                                 "mimeType": "image/png"]]]
        case .error(let message):
            return ["content": [["type": "text", "text": message]], "isError": true]
        }
    }

    // MARK: Parsing and encoding

    private static func parse(_ line: Data) throws -> MCPRequest {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: line)
        } catch {
            throw MCPParseError.parse
        }
        guard let object = raw as? [String: Any] else {
            throw MCPParseError.request("Request must be a JSON object")
        }
        guard object["jsonrpc"] as? String == "2.0" else {
            throw MCPParseError.request("jsonrpc must be “2.0”")
        }
        guard let method = object["method"] as? String, !method.isEmpty else {
            throw MCPParseError.request("Request needs a method")
        }
        var id: MCPID?
        if let rawId = object["id"], !(rawId is NSNull) {
            if let string = rawId as? String {
                id = .string(string)
            } else if let number = rawId as? NSNumber, !MCPValue.isBool(rawId),
                      number.doubleValue == number.doubleValue.rounded() {
                id = .number(number.intValue)
            } else {
                throw MCPParseError.request("id must be a string or an integer")
            }
        }
        var params: [String: Any] = [:]
        if let rawParams = object["params"], !(rawParams is NSNull) {
            guard let dictionary = rawParams as? [String: Any] else {
                throw MCPParseError.params("params must be an object")
            }
            params = dictionary
        }
        return MCPRequest(id: id, method: method, params: params)
    }

    private static func resultLine(id: MCPID, result: [String: Any]) -> Data {
        encode(id: id, body: ["result": result])
    }

    private static func errorLine(id: MCPID?, code: Int, message: String) -> Data {
        encode(id: id, body: ["error": ["code": code, "message": message]])
    }

    private static func encode(id: MCPID?, body: [String: Any]) -> Data {
        var object = body
        object["jsonrpc"] = "2.0"
        switch id {
        case .string(let value): object["id"] = value
        case .number(let value): object["id"] = value
        case nil: object["id"] = NSNull()
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return data + Data("\n".utf8)
    }
}
