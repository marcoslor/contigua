// phone_status and list_apps (docs/design/mcp.md, MCP-30…34).

import Foundation

extension MCPToolHost {
    func phoneStatus() -> [String: Any] {
        let windows = controller.windows.openStreams.count
        guard let phone = try? IntentsBridge.resolve(nil) else {
            return ["connected": false, "name": NSNull(), "battery": NSNull(),
                    "charging": false, "locked": false, "windows": windows]
        }
        let battery = IntentsBridge.battery(for: phone)
        return [
            "connected": controller.link.isOnline,
            "name": phone.name,
            "battery": battery.level.map { $0 as Any } ?? NSNull(),
            "charging": battery.charging,
            "locked": controller.link.isOnline ? (controller.status?.locked ?? false) : false,
            "windows": windows,
        ]
    }

    func listApps() throws -> [String: Any] {
        let phone = try IntentsBridge.resolve(nil)
        return try Self.appsAnswer(IntentsBridge.apps(for: phone))
    }
}
