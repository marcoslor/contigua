// What a click on a phone notification does (ROADMAP D2, docs/design/notify.md).
//
// The setting lives next to the per-phone `notify.<deviceId>` toggle and is
// stored as `notify.click.<deviceId>`. The default opens the app on the Mac and
// runs the notification's own action on that window's virtual display; the
// other choices run it on the phone's screen or only dismiss the banner.

import Foundation

/// The three choices of "When I click a phone notification".
enum NotifyClickTarget: String, CaseIterable, Identifiable {
    case mac
    case phone
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mac: return "Open on Mac"
        case .phone: return "Open on phone"
        case .none: return "Do nothing"
        }
    }

    /// Stored per phone, beside the notification toggle.
    static func key(deviceId: String) -> String { "notify.click.\(deviceId)" }

    /// A phone with no stored value opens on the Mac.
    static func stored(deviceId: String, defaults: UserDefaults) -> NotifyClickTarget {
        defaults.string(forKey: key(deviceId: deviceId))
            .flatMap(NotifyClickTarget.init(rawValue:)) ?? .mac
    }

    /// What the click does. Kept separate from the view so the mapping is
    /// unit-tested and "Do nothing" can never reach the open path.
    var action: NotifyClickAction {
        switch self {
        case .mac: return .openOnMac
        case .phone: return .openOnPhone
        case .none: return .dismiss
        }
    }
}

enum NotifyClickAction: Equatable {
    case openOnMac
    case openOnPhone
    case dismiss
}

/// The ordered steps of one click. The Mac window opens *before* `notify.open`
/// is sent, so a phone that does not know the message still ends up with
/// today's behaviour (the app's window at its launcher activity).
enum NotifyClickStep: Equatable {
    case openWindow
    case send(NotifyOpenTarget)
}

enum NotifyClickPlan {
    static func steps(for target: NotifyClickTarget) -> [NotifyClickStep] {
        switch target.action {
        case .openOnMac: return [.openWindow, .send(.window)]
        case .openOnPhone: return [.send(.phone)]
        case .dismiss: return []
        }
    }
}

/// The wire message (docs/PROTOCOL.md): the forwarded id and where to run it.
/// The action itself never crosses the wire.
enum NotifyOpenTarget: String {
    case window
    case phone
}

enum NotifyOpenMessage {
    static func make(id: String, target: NotifyOpenTarget, stream: UInt32? = nil) -> [String: Any] {
        var message: [String: Any] = ["t": "notify.open", "id": id, "target": target.rawValue]
        if target == .window, let stream {
            message["stream"] = Int(stream)
        }
        return message
    }
}

/// Per-app mute (docs/design/notify.md, part 2): a package the person muted on
/// this phone is dropped before the Mac posts it. Stored per phone in the
/// profile's defaults as a sorted array of package names (never any text).
enum NotifyMute {

    static func key(deviceId: String) -> String { "notify.mute.\(deviceId)" }

    static func muted(deviceId: String, defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: key(deviceId: deviceId)) ?? [])
    }

    static func isMuted(_ pkg: String, deviceId: String, defaults: UserDefaults) -> Bool {
        muted(deviceId: deviceId, defaults: defaults).contains(pkg)
    }

    static func setMuted(_ muted: Bool, pkg: String, deviceId: String, defaults: UserDefaults) {
        var set = self.muted(deviceId: deviceId, defaults: defaults)
        if muted { set.insert(pkg) } else { set.remove(pkg) }
        defaults.set(set.sorted(), forKey: key(deviceId: deviceId))
    }
}

