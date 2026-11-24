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
    static let serverName = "contigua"
    /// The app's own version: `VERSION`, which bundle.sh writes into Info.plist,
    /// so a bump stays one edit (MCP-3).
    static let serverVersion = appVersion(Bundle.main.infoDictionary)
    static func appVersion(_ info: [String: Any]?) -> String {
        guard let version = info?["CFBundleShortVersionString"] as? String, !version.isEmpty
        else { return "unknown" }
        return version
    }
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
    case uiTree = "ui_tree"
    case wait
    case tap
    case swipe
    case typeText = "type_text"
    case pressKey = "press_key"
    case inputProbe = "input_probe"
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

/// The way the finger moves in a `swipe {direction}` (MCP-90).
enum MCPSwipeDirection: String, CaseIterable {
    case up, down, left, right
}

/// A validated tool call: exactly what the tools layer may execute.
enum MCPCall: Equatable {
    case phoneStatus
    case listApps
    /// An open answers like an action: first frame, settle, tree (MCP-41).
    case openApp(String, newWindow: Bool, shape: MCPWindowShape = .phone, wait: MCPWait = .settle, observe: MCPObserve = .tree)
    case listWindows
    /// `wait: settle` settles the window first (MCP-64).
    case screenshot(window: Int, ref: String?, wait: MCPWait = .none)
    /// WIN-79: the display's accessibility tree, for finding a node by its text.
    case uiTree(window: Int, wait: MCPWait = .none)
    /// MCP-96, MCP-97, MCP-111: a clock, a text condition or the settle.
    case wait(window: Int, mode: MCPWaitMode, timeoutMs: Int, observe: MCPObserve)
    // Every input tool settles and observes (MCP-81, MCP-82): `wait` defaults
    // to settle and `observe` to tree.
    /// `holdMs` holds the press: the long press (MCP-88).
    case tap(window: Int, x: Double, y: Double, holdMs: Int? = nil,
             wait: MCPWait = .settle, observe: MCPObserve = .tree)
    /// WIN-79: tap the element a `ui_tree` ref named.
    case tapRef(window: Int, ref: String, holdMs: Int? = nil,
                wait: MCPWait = .settle, observe: MCPObserve = .tree)
    case swipe(window: Int, x1: Double, y1: Double, x2: Double, y2: Double, ms: Int,
               wait: MCPWait = .settle, observe: MCPObserve = .tree)
    /// MCP-90: through the centre of the ref's box, else the window's.
    case swipeDirection(window: Int, direction: MCPSwipeDirection, ref: String?, ms: Int,
                        wait: MCPWait = .settle, observe: MCPObserve = .tree)
    case typeText(window: Int, text: String, clear: Bool = false, submit: Bool = false,
                  wait: MCPWait = .settle, observe: MCPObserve = .tree)
    case pressKey(window: Int, key: MCPKey, wait: MCPWait = .settle, observe: MCPObserve = .tree)
    /// P0 (pmaxx): tap, then time the first displayed frame that changed.
    case inputProbe(window: Int, x: Double, y: Double, width: Double?, height: Double?)
    /// MCP-54: a window the person opened closes only with `force`.
    case closeWindow(window: Int, force: Bool = false)
    case sendLink(String, shape: MCPWindowShape = .phone, wait: MCPWait = .settle, observe: MCPObserve = .tree)
    case sendFile(String)
}

extension MCPCall {
    /// The window a call names, for the log line (MCP-14); nil for phone-level calls.
    var window: Int? {
        switch self {
        case .phoneStatus, .listApps, .openApp, .listWindows, .sendLink, .sendFile:
            return nil
        case .screenshot(let window, _, _), .uiTree(let window, _), .closeWindow(let window, _),
             .wait(let window, _, _, _),
             .tap(let window, _, _, _, _, _), .tapRef(let window, _, _, _, _),
             .swipe(let window, _, _, _, _, _, _, _), .swipeDirection(let window, _, _, _, _, _),
             .typeText(let window, _, _, _, _, _), .pressKey(let window, _, _, _),
             .inputProbe(let window, _, _, _, _):
            return window
        }
    }
}

/// What executing a call gave (MCP-5, MCP-6): an answer object, PNG bytes with
/// their answer, or one closed-code failure.
enum MCPToolResult {
    case answer([String: Any])
    case image(Data, [String: Any])
    case failure(MCPToolError)
}

/// One connection to the server, counted by the server (plan T1). Tools may
/// tell their callers apart by it; it is never logged with the client's name.
struct MCPClientID: Hashable, Sendable {
    let value: Int
    init(_ value: Int) { self.value = value }
}

/// The one log line per tool call (MCP-14): name, duration, outcome code and
/// window id. Nothing else reaches it.
enum MCPLogLine {
    static func format(tool: MCPToolName, duration: TimeInterval,
                       code: MCPErrorCode?, window: Int?) -> String {
        var line = "mcp \(tool.rawValue) \(Int((duration * 1000).rounded())) ms"
        if let code { line += " code=\(code.rawValue)" }
        if let window { line += " window=\(window)" }
        return line
    }
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
        ["name": name.rawValue, "description": description, "inputSchema": schema,
         "outputSchema": MCPOutputSchemas.schema(for: name)]
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

    /// MCP-100: `shape` on `open_app` and `send_link`.
    static let shape: [String: Any] = [
        "type": "string", "enum": MCPWindowShape.allCases.map(\.rawValue),
        "description": "phone (the default) opens a new window at the phone's portrait shape and its own dp width, at most 1280 px on the long side; window opens it as a person's window. A raised window keeps the shape it has.",
    ]

    /// MCP-81: `wait` on a tool that acts or reads.
    static let wait: [String: Any] = [
        "type": "string", "enum": MCPWait.allCases.map(\.rawValue),
        "description": "settle (the default for an action) waits until the window's accessibility tree has not changed for 300 ms and nothing on it is loading, at most 2 s; none answers at once.",
    ]
    /// MCP-82: `observe` on a tool that acts.
    static let observe: [String: Any] = [
        "type": "string", "enum": MCPObserve.allCases.map(\.rawValue),
        "description": "tree (the default) returns the ui_tree answer read after the settle; none returns no screen.",
    ]

    private static func duration(_ maximum: Int, default fallback: Int) -> [String: Any] {
        ["type": "integer", "minimum": 1, "maximum": maximum,
         "description": "How long the gesture lasts, in milliseconds (at most \(maximum), default \(fallback))."]
    }

    /// MCP-88: the longest `holdMs`.
    static let maxHoldMs = 3000
    /// MCP-90: a swipe's `ms` when the call gives none.
    static let defaultSwipeMs = 300

    /// The list `tools/list` returns, in a fixed order.
    static let all: [MCPTool] = [
        MCPTool(name: .phoneStatus,
                description: "The phone in use: connected or not, its name, battery, screen and lock state, the app in front on the phone's own screen, and how many windows are open. App windows take input whether or not the phone is locked.",
                schema: object([:], required: [])),
        MCPTool(name: .listApps,
                description: "Apps on the phone that can be opened, as label and package.",
                schema: object([:], required: [])),
        MCPTool(name: .openApp,
                description: "Open a phone app in a window on this Mac, or bring its window to the front if it has one, and return that window and the screen it shows. The app opens on whatever screen it last showed. A new window has the phone's shape unless shape is \"window\"; a window brought to the front keeps its shape, and size says what it is. newWindow: true opens a second window of an app that allows it.",
                schema: object([
                    "app": ["type": "string", "minLength": 1, "maxLength": 200,
                            "description": "Package name or app label (or a unique prefix)."],
                    "newWindow": ["type": "boolean",
                                  "description": "Open another window of an app that opens several at a time, instead of raising its window."],
                    "shape": shape, "wait": wait, "observe": observe,
                ], required: ["app"])),
        MCPTool(name: .listWindows,
                description: "Every open window: its id, what it shows, who opened it (you, another agent, the person or the app itself), its state and how fresh its picture is, and the windows that closed in the last 10 minutes with the reason. A window id is a handle, never reused for another window while Contigua runs.",
                schema: object([:], required: [])),
        MCPTool(name: .screenshot,
                description: "A PNG of the window, from a frame the phone sends after this call (never an older one), longest side at most 1280 px. ui_tree's box values are in the window's pixels (size), not the image's. Pass ref to get only that element.",
                schema: object([
                    "window": window,
                    "ref": ["type": "string", "minLength": 1, "maxLength": 32, "pattern": "^e[0-9]+$",
                            "description": "Element ref from ui_tree, e.g. \"e5\". Crop the picture to that element's box plus 8 px."],
                    "wait": wait,
                ], required: ["window"])),
        MCPTool(name: .uiTree,
                description: "What the window shows, as accessibility nodes in reading order: text, role, view id, states, a tap point (at, 0..1) and a ref for tap; box is in the display's pixels (size). A ref names one element for as long as it is on screen, across reads; a ref whose element is gone is refused. Only what is on screen is listed: a list says how many items it hides before and after; swipe the list to reach them. A field showing its hint has hint: true and no text. loading: true means the screen is still loading. Exact, and cheaper than a screenshot for finding what to press.",
                schema: object(["window": window, "wait": wait], required: ["window"])),
        MCPTool(name: .wait,
                description: "Wait on a window: for ms milliseconds, until text appears on it (with gone: true, until it disappears), or with settle: true until it stops changing and nothing on it is loading, at most timeoutMs; if timeoutMs ends first, reason says whether it was still loading. Use this instead of sleeping or re-reading the tree as a clock.",
                schema: object([
                    "window": window,
                    "ms": ["type": "integer", "minimum": 1, "maximum": 30000,
                           "description": "Wait this many milliseconds (1 to 30000)."],
                    "text": ["type": "string", "minLength": 1, "maxLength": 200,
                             "description": "Wait until a node's text or description contains this. The tree is read at most twice a second."],
                    "gone": ["type": "boolean",
                             "description": "With text: wait until no node contains it."],
                    "settle": ["type": "boolean",
                               "description": "true: wait until the window stops changing and nothing on it is loading."],
                    "timeoutMs": ["type": "integer", "minimum": 1, "maximum": 30000,
                                  "description": "For text or settle: give up after this long (default 10000); until is then timeout, which is not an error."],
                    "observe": observe,
                ], required: ["window"])),
        MCPTool(name: .tap,
                description: "Tap an element by its ref from ui_tree (preferred), or a point x, y (0..1 of the window); holdMs makes it a long press. A ref names one element for as long as it is on screen, across reads; a ref whose element is gone is refused. A ref whose element is off screen or covered is refused too, and nothing is pressed. The answer names what was pressed (its role and label). By default the call waits for the screen to settle and returns the new tree.",
                schema: object([
                    "window": window, "x": pointX, "y": pointY,
                    "ref": ["type": "string", "minLength": 1, "maxLength": 32, "pattern": "^e[0-9]+$",
                            "description": "Element ref from ui_tree, e.g. \"e5\". Takes precedence over x and y."],
                    "holdMs": ["type": "integer", "minimum": 1, "maximum": MCPTools.maxHoldMs,
                               "description": "Hold the press this many milliseconds (1 to 3000): a long press."],
                    "wait": wait, "observe": observe,
                ], required: ["window"])),
        MCPTool(name: .swipe,
                description: "Swipe in a window. direction is the way the finger moves (swipe up to see what is further down), through the centre of ref's element or of the window; or give the points x1,y1 to x2,y2. By default the call waits for the screen to settle and returns the new tree.",
                schema: object([
                    "window": window,
                    "direction": ["type": "string", "enum": MCPSwipeDirection.allCases.map(\.rawValue),
                                  "description": "The way the finger moves, through the centre of ref's element or of the window, over 60 % of it. Not with x1, y1, x2, y2."],
                    "ref": ["type": "string", "minLength": 1, "maxLength": 32, "pattern": "^e[0-9]+$",
                            "description": "With direction: element ref from ui_tree, e.g. \"e5\", to swipe through (a list)."],
                    "x1": pointX, "y1": pointY, "x2": pointX, "y2": pointY,
                    "ms": duration(2000, default: MCPTools.defaultSwipeMs), "wait": wait, "observe": observe,
                ], required: ["window"])),
        MCPTool(name: .typeText,
                description: "Type text into the window's focused field at the cursor: what is there stays, and entry in the answer says inserted. clear: true replaces the field's text instead (entry: replaced); submit: true presses Enter after. The phone's clipboard is never used. Tap the field first if nothing is focused.",
                schema: object([
                    "window": window,
                    "text": ["type": "string", "maxLength": 2000,
                             "description": "Up to 2000 characters."],
                    "clear": ["type": "boolean",
                              "description": "Replace the field's text instead of inserting at the cursor."],
                    "submit": ["type": "boolean", "description": "Press Enter after the text."],
                    "wait": wait, "observe": observe,
                ], required: ["window", "text"])),
        MCPTool(name: .pressKey,
                description: "Press one key in a window. back, home and recents are the phone's navigation; home and recents act only in the Phone Mirror. back on an app's last screen closes the window, and the answer says so. The rest (enter, delete, tab, escape, up, down, left, right) are keys.",
                schema: object([
                    "window": window,
                    "key": ["type": "string",
                            "enum": MCPKey.allCases.map(\.rawValue),
                            "description": "back, home and recents are navigation; the rest are keys. back on an app's last screen closes the window, and the answer says so."],
                    "wait": wait, "observe": observe,
                ], required: ["window", "key"])),
        MCPTool(name: .inputProbe,
                description: "Measurement: tap a point and return the milliseconds until the window's picture changed (input-to-photon), or null after 2 s. Not for driving an app. (Listed only when Contigua runs with --mcp-dev-tools.)",
                schema: object([
                    "window": window, "x": pointX, "y": pointY,
                    "w": ["type": "number", "minimum": 0.05, "maximum": 1,
                          "description": "Watched width, 0.05 to 1 of the picture (default: the whole picture)."],
                    "h": ["type": "number", "minimum": 0.05, "maximum": 1,
                          "description": "Watched height, 0.05 to 1 of the picture (default: the whole picture)."],
                ], required: ["window", "x", "y"])),
        MCPTool(name: .closeWindow,
                description: "Close a window. On the phone this ends the app's screen on that window's own display; the app is not uninstalled and its data (a browser's tabs, a document) stays. A window the person opened needs force: true.",
                schema: object([
                    "window": window,
                    "force": ["type": "boolean",
                              "description": "true closes a window the person opened, too."],
                ], required: ["window"])),
        MCPTool(name: .sendLink,
                description: "Open a link (http, https, geo, tel or mailto) on the phone in a new window, in the app the phone picks, and return that window and the screen it shows. The window has the phone's shape unless shape is \"window\".",
                schema: object([
                    "url": ["type": "string", "minLength": 1, "maxLength": 8192,
                            "description": "The link to open on the phone."],
                    "shape": shape, "wait": wait, "observe": observe,
                ], required: ["url"])),
        MCPTool(name: .sendFile,
                description: "Copy one file from this Mac to the phone's Download/Contigua folder and wait until the phone has it. Nothing on the phone is replaced or removed.",
                schema: object([
                    "path": ["type": "string", "minLength": 1, "maxLength": 4096,
                             "description": "Absolute path of a regular, readable file."],
                ], required: ["path"])),
    ]

    /// MCP-99: the tools a client sees and may call. `input_probe` is
    /// measurement, there only while the app runs with `--mcp-dev-tools`.
    static func listed(devTools: Bool) -> [MCPTool] {
        devTools ? all : all.filter { $0.name != .inputProbe }
    }

    static func tool(_ name: String, devTools: Bool = true) -> MCPTool? {
        listed(devTools: devTools).first { $0.name.rawValue == name }
    }
}

// MARK: - Output schemas (MCP-5)

/// The answer shapes of the tools as they are today (design/mcp.md "Answer
/// shapes"); each later task updates its own tool's.
enum MCPOutputSchemas {
    private static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    private static let integer: [String: Any] = ["type": "integer"]
    private static let number: [String: Any] = ["type": "number"]
    private static let boolean: [String: Any] = ["type": "boolean"]
    private static let string: [String: Any] = ["type": "string"]
    private static func nullable(_ type: String) -> [String: Any] { ["type": [type, "null"]] }
    private static func array(_ items: [String: Any]) -> [String: Any] { ["type": "array", "items": items] }

    /// MCP-20's `frame` object, carried by every answer that reflects a screen.
    private static let frameObject = object(["seq": integer, "ageMs": nullable("integer")],
                                            required: ["seq", "ageMs"])
    /// MCP-21's closed state token.
    private static let stateToken: [String: Any] = [
        "type": "string", "enum": ["opening", "live", "paused", "stalled", "offline", "closed"]]

    /// MCP-81's settle: a closed state, how long it waited, and why it stopped.
    private static let settleObject = object([
        "state": ["type": "string",
                  "enum": ["settled", "still_changing", "not_waited", "not_ready", "unavailable",
                           "window_closed", "interrupted"]],
        "waitedMs": integer,
        "reason": ["type": "string", "enum": ["changes", "loading"]],
    ], required: ["state"])

    /// MCP-80: the act envelope every input tool answers. No `ok`.
    private static let actEnvelope = object([
        "window": integer,
        "did": object(["action": string], required: ["action"]),
        "on": object(["snapshot": nullable("integer"), "frame": nullable("integer")],
                     required: ["snapshot", "frame"]),
        "settle": settleObject,
        "state": stateToken,
        "frame": frameObject,
        "alsoActed": array(["type": "string", "enum": ["person", "another_agent"]]),
        "closed": object(["reason": string, "closedBy": string], required: ["reason", "closedBy"]),
        "tree": ["type": "object"],
        "treeError": string,
    ], required: ["window", "did", "on", "settle", "state", "frame"])

    /// MCP-41: `open_app` and `send_link`'s answer.
    private static let openedWindow = object([
        "window": integer, "kind": ["type": "string", "enum": ["app", "link"]],
        "package": nullable("string"), "label": nullable("string"),
        "opened": ["type": "string", "enum": ["new", "raised"]], "openedBy": string,
        "size": array(integer), "settle": settleObject, "state": stateToken, "frame": frameObject,
        "tree": ["type": "object"], "treeError": string,
    ], required: ["window", "kind", "package", "label", "opened", "openedBy", "size", "settle",
                  "state", "frame"])

    /// `type_text`'s envelope: `did` says how it typed and never the text
    /// (MCP-92, MCP-109).
    private static let typeEnvelope: [String: Any] = {
        var envelope = actEnvelope
        var properties = envelope["properties"] as? [String: Any] ?? [:]
        properties["did"] = object([
            "action": string, "characters": integer, "clear": boolean, "submit": boolean,
            "entry": ["type": "string", "enum": ["inserted", "replaced", "unknown"]],
            "via": ["type": "string", "enum": ["keys", "set_text"]],
        ], required: ["action", "characters", "clear", "submit"])
        envelope["properties"] = properties
        return envelope
    }()

    static func schema(for tool: MCPToolName) -> [String: Any] {
        switch tool {
        case .phoneStatus:
            return object(["connected": boolean, "name": nullable("string"),
                           "battery": nullable("integer"), "charging": boolean,
                           "locked": nullable("boolean"), "screen": nullable("string"),
                           "lockSource": nullable("string"), "lockChangedAgoMs": integer,
                           "input": string, "maxWindows": integer, "windows": integer,
                           "foreground": ["type": ["object", "null"]],
                           "foregroundError": ["type": "string", "enum": ["not_supported", "timeout"]]],
                          required: ["connected", "name", "battery", "charging", "locked", "screen",
                                     "input", "foreground", "windows", "maxWindows"])
        case .listApps:
            return object(["apps": array(object(["label": string, "package": string],
                                                required: ["label", "package"]))],
                          required: ["apps"])
        case .openApp, .sendLink:
            return openedWindow
        case .listWindows:
            return object(["windows": array(object(["id": integer, "package": nullable("string"),
                                                    "size": array(integer), "state": stateToken,
                                                    "frame": frameObject, "kind": string,
                                                    "openedBy": string, "openedAgoMs": integer],
                                                   required: ["id", "package", "size", "state", "frame"])),
                           "recentlyClosed": array(object(["id": integer, "kind": string,
                                                           "package": nullable("string"),
                                                           "reason": string, "closedBy": string,
                                                           "closedAgoMs": integer],
                                                          required: ["id", "kind", "package", "reason",
                                                                     "closedBy", "closedAgoMs"]))],
                          required: ["windows", "recentlyClosed"])
        case .screenshot:
            return object(["window": integer, "state": stateToken, "frame": frameObject,
                           "image": array(integer), "size": array(integer),
                           "blank": boolean, "crop": array(integer), "settle": settleObject],
                          required: ["window", "state", "frame", "image", "size"])
        case .uiTree:
            return object(["window": integer, "ok": boolean, "displayId": integer,
                           "snapshot": integer, "size": array(integer), "truncated": boolean,
                           "layers": array(["type": "object"]), "nodes": array(["type": "object"]),
                           "note": string, "loading": boolean, "settle": settleObject,
                           "state": stateToken, "frame": frameObject],
                          required: ["window", "ok", "truncated", "layers", "nodes",
                                     "state", "frame"])
        case .wait:
            return object(["window": integer, "waitedMs": integer,
                           "until": ["type": "string", "enum": ["met", "timeout"]],
                           "match": object(["ref": string, "text": string]),
                           "reason": ["type": "string", "enum": ["changes", "loading"]],
                           "state": stateToken, "frame": frameObject,
                           "tree": ["type": "object"], "treeError": string],
                          required: ["window", "waitedMs", "state", "frame"])
        case .tap, .swipe, .pressKey:
            return actEnvelope
        case .typeText:
            return typeEnvelope
        case .inputProbe:
            return object(["ok": boolean, "window": integer, "frames": integer,
                           "sent_ms": nullable("number"), "changed_ms": nullable("number"),
                           "state": stateToken, "frame": frameObject],
                          required: ["ok", "window", "frames", "sent_ms", "changed_ms",
                                     "state", "frame"])
        case .closeWindow:
            return object(["window": integer,
                           "closed": object(["reason": string, "closedBy": string],
                                            required: ["reason", "closedBy"])],
                          required: ["window", "closed"])
        case .sendFile:
            return object(["bytes": integer, "state": ["type": "string", "enum": ["delivered", "sending"]]],
                          required: ["bytes", "state"])
        }
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

    private static func boolean(_ args: [String: Any], _ key: String, default fallback: Bool) throws -> Bool {
        guard let raw = args[key] else { return fallback }
        guard MCPValue.isBool(raw), let value = raw as? NSNumber else {
            throw MCPArgumentError(message: "“\(key)” must be true or false")
        }
        return value.boolValue
    }

    private static func token<T: RawRepresentable & CaseIterable>(
        _ args: [String: Any], _ key: String, default fallback: T
    ) throws -> T where T.RawValue == String {
        guard let raw = args[key] else { return fallback }
        guard let text = raw as? String, let value = T(rawValue: text) else {
            let allowed = T.allCases.map(\.rawValue).joined(separator: " or ")
            throw MCPArgumentError(message: "“\(key)” must be \(allowed)")
        }
        return value
    }

    private static func wait(_ args: [String: Any], default fallback: MCPWait = .settle) throws -> MCPWait {
        try token(args, "wait", default: fallback)
    }

    private static func observe(_ args: [String: Any]) throws -> MCPObserve {
        try token(args, "observe", default: MCPObserve.tree)
    }

    private static func coordinate(_ args: [String: Any], _ key: String) throws -> Double {
        let value = try number(args, key)
        guard (0...1).contains(value) else {
            throw MCPArgumentError(message: "“\(key)” must be between 0 and 1")
        }
        return value
    }

    /// MCP-100: `shape`, `phone` (the default) or `window`; nothing else.
    private static func shape(_ args: [String: Any]) throws -> MCPWindowShape {
        guard let raw = args["shape"] else { return .phone }
        guard let text = raw as? String, let shape = MCPWindowShape(rawValue: text) else {
            throw MCPArgumentError(message: "“shape” must be one of \(MCPWindowShape.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return shape
    }

    /// An optional normalized size: absent means "the whole picture", present
    /// must still leave a region a luma grid can be taken from.
    private static func optionalDimension(_ args: [String: Any], _ key: String) throws -> Double? {
        guard args[key] != nil else { return nil }
        let value = try number(args, key)
        guard (0.05...1).contains(value) else {
            throw MCPArgumentError(message: "“\(key)” must be between 0.05 and 1")
        }
        return value
    }

    /// A ref is the phone's key, `e<k>` (MCP-71); anything else is an argument
    /// error, never a refusal from the tool.
    static func key(_ args: [String: Any], _ key: String) throws -> String {
        let value = try string(args, key, maximum: 32)
        guard value.count >= 2, value.first == "e", value.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw MCPArgumentError(message: "ref must look like e12: use a ref from ui_tree")
        }
        return value
    }

    /// MCP-96, MCP-97, MCP-111: exactly one of `ms`, `text` or `settle: true`.
    private static func waitCall(_ args: [String: Any]) throws -> MCPCall {
        let window = try integer(args, "window", minimum: 1, maximum: 1_000_000)
        let settle = try boolean(args, "settle", default: false)
        let hasMs = args["ms"] != nil
        let hasText = args["text"] != nil
        if settle && (hasMs || hasText) {
            throw MCPArgumentError(message: "wait takes settle without ms or text")
        }
        if hasMs && hasText { throw MCPArgumentError(message: "wait takes ms or text, not both") }
        if args["gone"] != nil && !hasText { throw MCPArgumentError(message: "gone needs text") }
        let timeoutMs = args["timeoutMs"] != nil
            ? try integer(args, "timeoutMs", minimum: 1, maximum: MCPWaitPlan.maxMs)
            : MCPWaitPlan.defaultTimeoutMs
        let mode: MCPWaitMode
        if settle {
            mode = .settle
        } else if hasMs {
            mode = .clock(ms: try integer(args, "ms", minimum: 1, maximum: MCPWaitPlan.maxMs))
        } else if hasText {
            mode = .text(try string(args, "text", maximum: 200),
                         gone: try boolean(args, "gone", default: false))
        } else {
            throw MCPArgumentError(message: "wait needs ms, text or settle")
        }
        return .wait(window: window, mode: mode, timeoutMs: timeoutMs, observe: try observe(args))
    }

    /// MCP-88: `holdMs`, absent for a plain tap.
    private static func holdMs(_ args: [String: Any]) throws -> Int? {
        guard args["holdMs"] != nil else { return nil }
        return try integer(args, "holdMs", minimum: 1, maximum: MCPTools.maxHoldMs)
    }

    /// MCP-90: the points form (`x1`,`y1`,`x2`,`y2`) or the direction form
    /// (`direction`, `ref`?), never both.
    private static func swipeCall(_ args: [String: Any]) throws -> MCPCall {
        let window = try integer(args, "window", minimum: 1, maximum: 1_000_000)
        let ms = args["ms"] != nil ? try integer(args, "ms", minimum: 1, maximum: 2000) : MCPTools.defaultSwipeMs
        let points = ["x1", "y1", "x2", "y2"].filter { args[$0] != nil }
        if args["direction"] != nil {
            guard points.isEmpty else {
                throw MCPArgumentError(message: "swipe takes direction or x1, y1, x2, y2, not both")
            }
            let direction: MCPSwipeDirection = try token(args, "direction", default: .up)
            let ref = args["ref"] != nil ? try key(args, "ref") : nil
            return .swipeDirection(window: window, direction: direction, ref: ref, ms: ms,
                                   wait: try wait(args), observe: try observe(args))
        }
        if args["ref"] != nil { throw MCPArgumentError(message: "ref needs direction") }
        guard !points.isEmpty else { throw MCPArgumentError(message: "swipe needs direction or x1, y1, x2, y2") }
        return .swipe(window: window,
                      x1: try coordinate(args, "x1"), y1: try coordinate(args, "y1"),
                      x2: try coordinate(args, "x2"), y2: try coordinate(args, "y2"),
                      ms: ms, wait: try wait(args), observe: try observe(args))
    }

    /// Validate `arguments` for a tool the client may call (`devTools`:
    /// whether the app runs with `--mcp-dev-tools`, MCP-99). Throws
    /// `MCPArgumentError`; the dispatcher turns that into `-32602`.
    static func call(_ name: String, _ args: [String: Any], devTools: Bool = false) throws -> MCPCall {
        guard let tool = MCPTools.tool(name, devTools: devTools) else {
            throw MCPArgumentError(message: "Unknown tool: \(name)")
        }
        try rejectUnknown(args, tool)
        switch tool.name {
        case .phoneStatus:
            return .phoneStatus
        case .listApps:
            return .listApps
        case .openApp:
            return .openApp(try string(args, "app", maximum: 200),
                            newWindow: try boolean(args, "newWindow", default: false),
                            shape: try shape(args), wait: try wait(args), observe: try observe(args))
        case .listWindows:
            return .listWindows
        case .screenshot:
            let window = try integer(args, "window", minimum: 1, maximum: 1_000_000)
            let ref = args["ref"] != nil ? try key(args, "ref") : nil
            return .screenshot(window: window, ref: ref, wait: try wait(args, default: .none))
        case .uiTree:
            return .uiTree(window: try integer(args, "window", minimum: 1, maximum: 1_000_000),
                           wait: try wait(args, default: .none))
        case .wait:
            return try waitCall(args)
        case .tap:
            let window = try integer(args, "window", minimum: 1, maximum: 1_000_000)
            if args["ref"] != nil {
                return .tapRef(window: window, ref: try key(args, "ref"), holdMs: try holdMs(args),
                               wait: try wait(args), observe: try observe(args))
            }
            return .tap(window: window,
                        x: try coordinate(args, "x"), y: try coordinate(args, "y"), holdMs: try holdMs(args),
                        wait: try wait(args), observe: try observe(args))
        case .swipe:
            return try swipeCall(args)
        case .typeText:
            return .typeText(window: try integer(args, "window", minimum: 1, maximum: 1_000_000),
                             text: try string(args, "text", minimum: 0, maximum: 2000),
                             clear: try boolean(args, "clear", default: false),
                             submit: try boolean(args, "submit", default: false),
                             wait: try wait(args), observe: try observe(args))
        case .pressKey:
            let window = try integer(args, "window", minimum: 1, maximum: 1_000_000)
            let raw = try string(args, "key", maximum: 20)
            guard let key = MCPKey(rawValue: raw) else {
                throw MCPArgumentError(message: "“key” must be one of \(MCPKey.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return .pressKey(window: window, key: key, wait: try wait(args), observe: try observe(args))
        case .inputProbe:
            return .inputProbe(window: try integer(args, "window", minimum: 1, maximum: 1_000_000),
                               x: try coordinate(args, "x"), y: try coordinate(args, "y"),
                               width: try optionalDimension(args, "w"),
                               height: try optionalDimension(args, "h"))
        case .closeWindow:
            return .closeWindow(window: try integer(args, "window", minimum: 1, maximum: 1_000_000),
                                force: try boolean(args, "force", default: false))
        case .sendLink:
            return .sendLink(try string(args, "url", maximum: 8192), shape: try shape(args),
                             wait: try wait(args), observe: try observe(args))
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
    /// The log hook: tool, duration, outcome code (nil on success), window.
    typealias Log = (MCPToolName, TimeInterval, MCPErrorCode?, Int?) -> Void

    /// `devTools`: the app runs with `--mcp-dev-tools` (MCP-99).
    static func handle(line: Data,
                       client: MCPClientID,
                       devTools: Bool = false,
                       perform: (MCPCall, MCPClientID) async -> MCPToolResult,
                       log: Log? = nil) async -> Data? {
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
            return resultLine(id: id, result: ["tools": MCPTools.listed(devTools: devTools).map(\.object)])
        case "tools/call":
            return await toolCall(id: id, params: request.params, client: client, devTools: devTools,
                                  perform: perform, log: log)
        default:
            return errorLine(id: id, code: -32601, message: "Method not found: \(request.method)")
        }
    }

    private static func toolCall(id: MCPID, params: [String: Any], client: MCPClientID, devTools: Bool,
                                 perform: (MCPCall, MCPClientID) async -> MCPToolResult,
                                 log: Log?) async -> Data {
        guard let name = params["name"] as? String, !name.isEmpty else {
            return errorLine(id: id, code: mcpInvalidParams, message: "tools/call needs a tool name")
        }
        let arguments = params["arguments"] ?? [String: Any]()
        guard let args = arguments as? [String: Any] else {
            return errorLine(id: id, code: mcpInvalidParams, message: "arguments must be an object")
        }
        let call: MCPCall
        do {
            call = try MCPArguments.call(name, args, devTools: devTools)
        } catch let argumentError as MCPArgumentError {
            return errorLine(id: id, code: mcpInvalidParams, message: argumentError.message)
        } catch {
            return errorLine(id: id, code: mcpInvalidParams, message: "Invalid arguments")
        }
        guard let tool = MCPToolName(rawValue: name) else {
            return errorLine(id: id, code: mcpInvalidParams, message: "Unknown tool: \(name)")
        }
        let started = ProcessInfo.processInfo.systemUptime
        let outcome = await perform(call, client)
        if let log {
            var code: MCPErrorCode?
            if case .failure(let failure) = outcome { code = failure.code }
            log(tool, ProcessInfo.processInfo.systemUptime - started, code, call.window)
        }
        return resultLine(id: id, result: resultBody(outcome))
    }

    /// MCP-5/MCP-6: an answer is structured content mirrored as one text
    /// block (after the image, for a screenshot); a failure is the error
    /// object as text, with no structured content.
    static func resultBody(_ outcome: MCPToolResult) -> [String: Any] {
        switch outcome {
        case .answer(let answer):
            return ["content": [["type": "text", "text": MCPJSON.string(answer)]],
                    "structuredContent": answer, "isError": false]
        case .image(let data, let answer):
            return ["content": [["type": "image", "data": data.base64EncodedString(),
                                 "mimeType": "image/png"],
                                ["type": "text", "text": MCPJSON.string(answer)]],
                    "structuredContent": answer, "isError": false]
        case .failure(let failure):
            return ["content": [["type": "text", "text": MCPJSON.string(failure.object)]],
                    "isError": true]
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
        return MCPJSON.data(object) + Data("\n".utf8)
    }
}
