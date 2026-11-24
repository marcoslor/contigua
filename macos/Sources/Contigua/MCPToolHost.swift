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
    /// The connection the call came on: its window turns (MCP-84).
    var client: MCPClientID?

    init(controller: ConnectionController, client: MCPClientID? = nil) {
        self.controller = controller
        self.client = client
    }

    func perform(_ call: MCPCall, client: MCPClientID) async -> MCPToolResult {
        var host = self
        host.client = client
        // MCP-22: the hold runs from the call's start until 15 s after its end.
        host.hold(call)
        defer { host.hold(call) }
        return host.stamped(await host.run(call), for: call)
    }

    /// MCP-20/21: the tree and every input answer carry the window's `state`
    /// and `frame` as they are when the answer is made.
    private func stamped(_ result: MCPToolResult, for call: MCPCall) -> MCPToolResult {
        switch call {
        case .uiTree, .inputProbe:
            guard case .answer(let answer) = result, let id = call.window,
                  let window = controller.windows.controller(for: UInt32(id)) else { return result }
            return .answer(MCPFreshness.stamp(answer, state: stateToken(for: window),
                                              frame: frameObject(for: window)))
        case .phoneStatus, .listApps, .openApp, .listWindows, .screenshot, .closeWindow,
             .sendLink, .sendFile:
            return result
        case .tap, .tapRef, .longPress, .swipe, .typeText, .pressKey:
            // The envelope stamps itself: a window that closed during the call
            // keeps `state: closed` and the frame it last had (MCP-83).
            return result
        }
    }

    private func run(_ call: MCPCall) async -> MCPToolResult {
        do {
            switch call {
            case .phoneStatus:
                return .answer(await phoneStatus())
            case .listApps:
                return .answer(try listApps())
            case .openApp(let query, let newWindow):
                return .answer(try openApp(query, newWindow: newWindow))
            case .listWindows:
                return .answer(listWindows())
            case .screenshot(let window, let ref, let wait):
                return try await screenshot(window, ref: ref, wait: wait)
            case .uiTree(let window, let wait):
                return .answer(try await uiTree(window, wait: wait))
            case .tap(let window, let x, let y, let wait, let observe):
                return .answer(try await tap(window: window, x: x, y: y, wait: wait, observe: observe))
            case .tapRef(let window, let ref, let wait, let observe):
                return .answer(try await tap(window: window, ref: ref, wait: wait, observe: observe))
            case .longPress(let window, let x, let y, let ms, let wait, let observe):
                return .answer(try await longPress(window: window, x: x, y: y, ms: ms,
                                                   wait: wait, observe: observe))
            case .swipe(let window, let x1, let y1, let x2, let y2, let ms, let wait, let observe):
                return .answer(try await swipe(window: window, x1: x1, y1: y1, x2: x2, y2: y2, ms: ms,
                                               wait: wait, observe: observe))
            case .typeText(let window, let text, let wait, let observe):
                return .answer(try await typeText(window: window, text: text, wait: wait, observe: observe))
            case .pressKey(let window, let key, let wait, let observe):
                return .answer(try await pressKey(window: window, key: key, wait: wait, observe: observe))
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

    /// MCP-50/62: the window's pixel space, the one `ui_tree`'s `box` is in:
    /// the display's pixels for that window, not the stream's.
    func pixelSize(of window: StreamWindowController) -> (Int, Int) {
        let stream = (Int(window.videoView.videoSize.width.rounded()),
                      Int(window.videoView.videoSize.height.rounded()))
        return MCPWindowSize.pixels(treeSize: controller.uiTreeSize(stream: window.stream),
                                    mirrorScreen: (window as? PhoneWindowController)?.phoneScreen,
                                    stream: stream)
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
            throw noWindow(id)
        }
        return window
    }

    /// MCP-53: `no_window`, with the close record when the window is in
    /// `recentlyClosed`.
    func noWindow(_ id: Int) -> MCPToolError {
        let closed = controller.windows.ledger.closeRecord(UInt32(id), asker: client,
                                                           now: ProcessInfo.processInfo.systemUptime)
        return MCPToolError.noWindow(id, closed: closed)
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

/// MCP-20/21: the freshness fields an answer about a window's screen carries.
enum MCPFreshness {
    static func stamp(_ answer: [String: Any], state: String, frame: [String: Any]) -> [String: Any] {
        var answer = answer
        answer["state"] = state
        answer["frame"] = frame
        return answer
    }
}
