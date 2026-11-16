// The automation server's tools (docs/design/mcp.md): validated `MCPCall`s are
// carried out over the same layers the UI uses — IntentsBridge for phone/app/
// link/file resolution, WindowManager for windows, Session for input, FrameGrab
// for a screenshot. Nothing here synthesizes NSEvents or reimplements a policy.
//
// This file is the dispatch and the shared helpers; each tool family lives in
// an `MCPTools+<Family>.swift` extension. Every throw becomes one closed code
// (MCPToolError, MCP-6).

import Foundation

@MainActor
struct MCPToolHost {
    unowned let controller: ConnectionController

    /// `client` is the connection the call came on; no tool uses it yet.
    func perform(_ call: MCPCall, client: MCPClientID) async -> MCPToolResult {
        // MCP-22: the hold runs from the call's start until 15 s after its end.
        hold(call)
        defer { hold(call) }
        return await run(call)
    }

    private func run(_ call: MCPCall) async -> MCPToolResult {
        do {
            switch call {
            case .phoneStatus:
                return .answer(phoneStatus())
            case .listApps:
                return .answer(try listApps())
            case .openApp(let query, let newWindow):
                return .answer(try openApp(query, newWindow: newWindow))
            case .listWindows:
                return .answer(listWindows())
            case .screenshot(let window):
                return try await screenshot(window)
            case .uiTree(let window):
                return .answer(try await uiTree(window))
            case .tap(let window, let x, let y):
                return .answer(try tap(window: window, x: x, y: y))
            case .tapRef(let window, let ref):
                return .answer(try tap(window: window, ref: ref))
            case .longPress(let window, let x, let y, let ms):
                return .answer(try await longPress(window: window, x: x, y: y, ms: ms))
            case .swipe(let window, let x1, let y1, let x2, let y2, let ms):
                return .answer(try await swipe(window: window, x1: x1, y1: y1, x2: x2, y2: y2, ms: ms))
            case .typeText(let window, let text):
                return .answer(try typeText(window: window, text: text))
            case .pressKey(let window, let key):
                return .answer(try pressKey(window: window, key: key))
            case .inputProbe(let window, let x, let y, let width, let height):
                return .answer(try await inputProbe(window: window, x: x, y: y,
                                                    width: width, height: height))
            case .closeWindow(let window):
                return .answer(try closeWindow(window))
            case .sendLink(let url):
                return .answer(try sendLink(url))
            case .sendFile(let path):
                return .answer(try sendFile(path))
            }
        } catch {
            return .failure(MCPToolError.mapping(error, phone: phoneName))
        }
    }

    // MARK: Helpers

    /// MCP-22: a call naming an open window holds its stream unpaused.
    func hold(_ call: MCPCall) {
        guard let id = call.window, let window = controller.windows.controller(for: UInt32(id))
        else { return }
        window.agentCalled()
    }

    /// MCP-20: the window's `frame` object now.
    func frameObject(for window: StreamWindowController) -> [String: Any] {
        window.frameClock.object(now: ProcessInfo.processInfo.systemUptime)
    }

    /// MCP-21: the window's closed state token.
    func stateToken(for window: StreamWindowController) -> String {
        MCPWindowState.token(window.mcpLifecycle)
    }

    /// The phone's name for a sentence's blank; never logged (MCP-14).
    var phoneName: String? {
        (try? IntentsBridge.resolve(nil))?.name
    }

    func requireWindow(_ id: Int) throws -> StreamWindowController {
        guard let window = controller.windows.controller(for: UInt32(id)) else {
            throw MCPToolError.noWindow(id)
        }
        return window
    }

    func requireInputWindow(_ id: Int) throws -> StreamWindowController {
        let window = try requireWindow(id)
        guard controller.link.isOnline else { throw IntentFailure.phoneNotConnected }
        return window
    }

    // MARK: Pure decisions (unit-tested)

    /// MCP-33: an empty list is "not arrived yet", never an empty answer.
    nonisolated static func appsAnswer(_ apps: [AppInfo]) throws -> [String: Any] {
        guard !apps.isEmpty else { throw MCPToolError.appsNotReady }
        let sorted = IntentAppCatalog.search("", in: apps, limit: 10_000)
        return ["apps": sorted.map { ["label": $0.label, "package": $0.pkg] }]
    }

    /// MCP-33/MCP-40: the app `open_app` names, or its closed failure.
    nonisolated static func chooseApp(_ query: String, in apps: [AppInfo]) throws -> AppInfo {
        guard !apps.isEmpty else { throw MCPToolError.appsNotReady }
        switch IntentAppCatalog.app(named: query, in: apps) {
        case .app(let app): return app
        case .ambiguous(let matches): throw MCPToolError.ambiguous(query, matches: matches)
        case .none: throw MCPToolError.notFound(query)
        }
    }
}

/// MCP-21: a window's closed set of state tokens. The three link-down steps
/// all read `offline` to a client.
enum MCPWindowState {
    enum Lifecycle: Equatable {
        case opening, live, paused, stalled, linkDown, reconnecting, offline, closed
    }

    static func token(_ state: Lifecycle) -> String {
        switch state {
        case .opening: return "opening"
        case .live: return "live"
        case .paused: return "paused"
        case .stalled: return "stalled"
        case .linkDown, .reconnecting, .offline: return "offline"
        case .closed: return "closed"
        }
    }
}
