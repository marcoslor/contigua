// phone_status and list_apps (docs/design/mcp.md, MCP-30…34).

import Foundation

/// What the Mac knows of the phone's lock and screen (MCP-31).
struct MCPStatusPhone {
    var locked: Bool
    var screen: PhoneScreen?
    var lockSource: PhoneLockSource?
    var lockChangedAt: ContinuousClock.Instant
}

/// Everything `phone_status` answers from, read once per call.
struct MCPStatusInput {
    var connected: Bool
    var name: String?
    var battery: Int?
    var charging: Bool
    var windows: Int
    var maxWindows: Int
    /// nil with no phone online.
    var phone: MCPStatusPhone?
    /// nil when no `task.front` was asked (no phone online).
    var foreground: FrontRead?
    var apps: [AppInfo]
}

extension MCPToolHost {
    nonisolated static let lockInput =
        "App windows take input whether or not the phone is locked; the Phone Mirror shows the lock screen until the person unlocks it."

    func phoneStatus() async -> [String: Any] {
        let windows = controller.windows.openStreams.count
        let maxWindows = controller.windows.maxWindows
        guard let phone = try? IntentsBridge.resolve(nil, in: controller) else {
            return Self.statusAnswer(MCPStatusInput(connected: false, name: nil, battery: nil, charging: false,
                                                    windows: windows, maxWindows: maxWindows, phone: nil,
                                                    foreground: nil, apps: []), now: .now)
        }
        let online = controller.link.isOnline
        let foreground: FrontRead? = online ? await controller.frontReads.read() : nil
        let battery = IntentsBridge.battery(for: phone, in: controller)
        var state: MCPStatusPhone?
        if online, let status = controller.status {
            state = MCPStatusPhone(locked: status.locked, screen: status.screen ?? .on,
                                   lockSource: status.lockSource,
                                   lockChangedAt: controller.lockChangedAt ?? .now)
        }
        return Self.statusAnswer(MCPStatusInput(connected: online, name: phone.name,
                                                battery: battery.level, charging: battery.charging,
                                                windows: windows, maxWindows: maxWindows,
                                                phone: state, foreground: foreground,
                                                apps: controller.apps), now: .now)
    }

    /// MCP-31/32's answer, pure.
    nonisolated static func statusAnswer(_ input: MCPStatusInput, now: ContinuousClock.Instant) -> [String: Any] {
        var answer: [String: Any] = [
            "connected": input.connected,
            "name": input.name.map { $0 as Any } ?? NSNull(),
            "battery": input.battery.map { $0 as Any } ?? NSNull(),
            "charging": input.charging,
            "windows": input.windows,
            "maxWindows": input.maxWindows,
            "input": lockInput,
            "locked": NSNull(),
            "screen": NSNull(),
            "foreground": NSNull(),
        ]
        if let phone = input.phone {
            answer["locked"] = phone.locked
            answer["screen"] = (phone.screen ?? .on).rawValue
            answer["lockSource"] = phone.lockSource.map { $0.rawValue as Any } ?? NSNull()
            let ago = now - phone.lockChangedAt
            answer["lockChangedAgoMs"] = Int(ago.components.seconds) * 1000
                + Int(ago.components.attoseconds / 1_000_000_000_000_000)
        }
        switch input.foreground {
        case .pkg(let pkg):
            let label = input.apps.first { $0.pkg == pkg }?.label
            answer["foreground"] = ["package": pkg, "label": label.map { $0 as Any } ?? NSNull()]
        case .notSupported:
            answer["foregroundError"] = "not_supported"
        case .timeout:
            answer["foregroundError"] = "timeout"
        case .none?, nil:
            break
        }
        return answer
    }

    func listApps() throws -> [String: Any] {
        let phone = try IntentsBridge.resolve(nil)
        return try Self.appsAnswer(IntentsBridge.apps(for: phone))
    }
}
