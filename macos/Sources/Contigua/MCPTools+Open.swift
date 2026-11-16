// open_app, send_link and send_file (docs/design/mcp.md, MCP-40…44).

import Foundation

extension MCPToolHost {
    func openApp(_ query: String, newWindow: Bool) throws -> [String: Any] {
        let phone = try IntentsBridge.resolve(nil)
        guard controller.link.isOnline, controller.link.phone?.id == phone.id else {
            throw IntentFailure.phoneNotConnected
        }
        let app = try Self.chooseApp(query, in: IntentsBridge.apps(for: phone))
        if newWindow {
            let windows = controller.windows
            if let refusal = Self.newWindowRefusal(
                app: app.label,
                windowCount: windows.appWindows(pkg: app.pkg, deviceId: phone.id).count,
                blocker: windows.newWindowItem(for: app.pkg, deviceId: phone.id).blocker) {
                throw refusal
            }
        }
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
    /// With no window open the flag opens the first one, so nothing refuses;
    /// an app that opens one window at a time and has one refuses naming the
    /// flag. The cap and a window still opening are not settled (MCP-40's
    /// [NEEDS CLARIFICATION]) and keep today's answer: the app's window.
    nonisolated static func newWindowRefusal(app: String, windowCount: Int, blocker: NewWindowBlocker?) -> MCPToolError? {
        guard windowCount > 0, blocker == .oneWindow else { return nil }
        return .failed("\(app) does not open several windows at once; call open_app without newWindow to bring its window forward.")
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
