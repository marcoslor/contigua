// list_windows and close_window (docs/design/mcp.md, MCP-50…54).

import Foundation

extension MCPToolHost {
    func listWindows() -> [String: Any] {
        let now = ProcessInfo.processInfo.systemUptime
        let ledger = controller.windows.ledger
        let windows: [[String: Any]] = controller.windows.openStreams.compactMap { stream in
            guard let window = controller.windows.controller(for: stream) else { return nil }
            var row: [String: Any] = ledger.row(stream, asker: client, now: now)
                ?? ["kind": "app", "openedBy": "person", "openedAgoMs": 0]
            row["id"] = Int(stream)
            row["size"] = { let size = pixelSize(of: window); return [size.0, size.1] }()
            row["state"] = stateToken(for: window)
            row["frame"] = frameObject(for: window)
            row["package"] = package(of: window).map { $0 as Any } ?? NSNull()
            return row
        }
        return ["windows": windows, "recentlyClosed": ledger.recentlyClosed(asker: client, now: now)]
    }

    func package(of window: StreamWindowController) -> String? {
        WindowManager.ledgerPackage(window)
    }

    /// MCP-54: closes as the close button does; the answer names the close.
    /// A window the person opened closes only with `force`, so an agent never
    /// takes away a window it did not ask for by mistake.
    func closeWindow(_ id: Int, force: Bool) throws -> [String: Any] {
        let window = try requireWindow(id)
        if !force, controller.windows.ledger.openedBy(UInt32(id), asker: client) == "person" {
            throw MCPToolError.failed("Window \(id) was opened by the person. Pass force: true to close it anyway.",
                                      window: id)
        }
        window.closedBy = client
        window.window?.close()
        return ["window": id, "closed": ["reason": "closed", "closedBy": "you"]]
    }
}
