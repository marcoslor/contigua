// list_windows and close_window (docs/design/mcp.md, MCP-50…54).

import Foundation

extension MCPToolHost {
    func listWindows() -> [String: Any] {
        let windows: [[String: Any]] = controller.windows.openStreams.compactMap { stream in
            guard let window = controller.windows.controller(for: stream) else { return nil }
            var row: [String: Any] = [
                "id": Int(stream),
                "width": Int(window.videoView.videoSize.width.rounded()),
                "height": Int(window.videoView.videoSize.height.rounded()),
            ]
            row["package"] = package(of: window).map { $0 as Any } ?? NSNull()
            return row
        }
        return ["windows": windows]
    }

    func package(of window: StreamWindowController) -> String? {
        if let app = window as? AppWindowController { return app.pkg }
        if let link = window as? LinkWindowController { return link.pkg }
        if let handoff = window as? HandoffWindowController { return handoff.pkg }
        return nil
    }

    func closeWindow(_ id: Int) throws -> [String: Any] {
        let window = try requireWindow(id)
        window.window?.close()
        return ["ok": true, "window": id]
    }
}
