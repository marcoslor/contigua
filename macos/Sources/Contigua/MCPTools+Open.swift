// open_app, send_link and send_file (docs/design/mcp.md, MCP-40…44).

import Foundation

extension MCPToolHost {
    func openApp(_ query: String, newWindow: Bool) throws -> [String: Any] {
        let phone = try IntentsBridge.resolve(nil)
        guard controller.link.isOnline, controller.link.phone?.id == phone.id else {
            throw IntentFailure.phoneNotConnected
        }
        let app = try Self.chooseApp(query, in: IntentsBridge.apps(for: phone))
        controller.intentsOpenApp(app.pkg, on: phone.id, newWindow: newWindow)
        // The window is created synchronously above; the newest stream for
        // that package is the one this call opened.
        let stream = controller.windows.openStreams
            .filter { (controller.windows.controller(for: $0) as? AppWindowController)?.pkg == app.pkg }
            .max()
        guard let stream else {
            throw MCPToolError.failed("The app couldn't open a window. Call list_windows, then try open_app again.")
        }
        return ["window": Int(stream), "package": app.pkg, "label": app.label]
    }

    /// The refusal for `newWindow: true` (MCP-40); nil lets the open go on.
    nonisolated static func newWindowRefusal(app: String, windowCount: Int, blocker: NewWindowBlocker?) -> MCPToolError? {
        nil
    }

    func sendLink(_ url: String) throws -> [String: Any] {
        let phone = try IntentsBridge.resolve(nil)
        return ["message": try IntentsBridge.sendLink(url, on: phone)]
    }

    func sendFile(_ path: String) throws -> [String: Any] {
        let phone = try IntentsBridge.resolve(nil)
        return ["message": try IntentsBridge.sendFiles([path], on: phone)]
    }
}
