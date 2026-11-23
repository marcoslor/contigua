// The automation server's gate (docs/design/mcp.md): one setting per profile,
// the socket's lifetime tied to it, the connected-client count the menu bar and
// Settings show, and the configuration snippet a person pastes into an MCP
// client. Off by default; while off no socket exists.

import Foundation
import Observation

@MainActor
@Observable
final class MCPAutomation {
    static let enabledKey = "automation.allowAgents"

    /// "Allow AI agents to control your phone".
    private(set) var enabled = false
    private(set) var clientCount = 0
    /// Set when the socket could not be created; Settings shows it.
    private(set) var lastError: String?

    @ObservationIgnored private var profile: Profile = .active
    @ObservationIgnored private var defaults: UserDefaults = .standard
    @ObservationIgnored private var server: MCPSocketServer?
    /// The app side of a tool call; nil while shutting down.
    @ObservationIgnored var hostProvider: (@MainActor () -> MCPToolHost?)?
    @ObservationIgnored var onClientClosed: (@MainActor (MCPClientID) -> Void)?

    /// `forced` is the e2e hook (`--mcp-enable`, test builds only): it turns
    /// the setting on in this profile without asking, then the normal path runs.
    func configure(profile: Profile, forced: Bool) {
        self.profile = profile
        defaults = profile.defaults
        if forced { defaults.set(true, forKey: Self.enabledKey) }
        enabled = defaults.bool(forKey: Self.enabledKey)
    }

    /// Start listening if the setting is on. Called once at launch; the toggle
    /// calls `setEnabled`.
    func start() {
        guard enabled else {
            if let path = socketPath {
                MCPSocketServer.removeStaleSocket(at: path)
            }
            return
        }
        guard server == nil, let path = socketPath else { return }
        let server = MCPSocketServer(path: path) { [weak self] line, client in
            guard let self else { return nil }
            return await self.handle(line, client: client)
        }
        server.onClientCountChanged = { [weak self] count in
            self?.clientCount = count
        }
        server.onClientClosed = { [weak self] client in
            self?.onClientClosed?(client)
        }
        do {
            try server.start()
            self.server = server
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Log.app.error("mcp server: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        defaults.set(on, forKey: Self.enabledKey)
        if on {
            start()
        } else {
            stop()
        }
    }

    func stop() {
        server?.stop()
        server = nil
        clientCount = 0
    }

    /// The menu bar's "Disconnect agent": every client goes, the listener stays
    /// so a person can turn the setting off from Settings without a race.
    func disconnectAgents() {
        server?.disconnectClients()
    }

    /// The socket file of the active profile.
    var socketPath: String? {
        let manager = FileManager.default
        guard let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent(profile.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("mcp.sock").path
    }

    /// What a person pastes into an MCP client. The default profile is the
    /// documented command; another profile names itself explicitly.
    var configSnippet: String {
        let command = "/Applications/Contigua.app/Contents/Helpers/contigua-mcp"
        if profile.isDefault {
            return #"{"command": "\#(command)"}"#
        }
        return #"{"command": "\#(command)", "args": ["--profile", "\#(profile.name)"]}"#
    }

    // MARK: Dispatch

    private func handle(_ line: Data, client: MCPClientID) async -> Data? {
        await MCPDispatcher.handle(line: line, client: client, perform: { [weak self] call, client in
            guard let self else { return .failure(Self.shuttingDown) }
            return await self.perform(call, client: client)
        }, log: { tool, seconds, code, window in
            // Name, duration, outcome code and window only: never arguments,
            // text, URLs, file names, the client's name or pixels (MCP-14).
            let line = MCPLogLine.format(tool: tool, duration: seconds, code: code, window: window)
            Log.app.notice("\(line, privacy: .public)")  // log-ok: tool name, duration, closed code and window id only (MCPLogLine)
        })
    }

    private static let shuttingDown = MCPToolError.failed("Contigua is shutting down.")

    @MainActor
    private func perform(_ call: MCPCall, client: MCPClientID) async -> MCPToolResult {
        guard let host = hostProvider?() else {
            return .failure(Self.shuttingDown)
        }
        return await host.perform(call, client: client)
    }
}
