// The Devices tab's pure half (docs/specs/settings-devices.md): what a phone
// row says, the section titles that name their phone, and the muted-apps list.
// No SwiftUI here, so the strings and the ordering are unit-tested (K2).

import Foundation

/// What a phone's row says, from `Link` for the phone in use and from what this
/// Mac remembers for the others. Never colour alone: every case has its words.
enum DevicePresence: Equatable {
    case connected
    case connecting
    case reconnecting
    case offline(Date?)
    case pairAgain

    init(_ link: Link) {
        switch link {
        case .online: self = .connected
        case .connecting: self = .connecting
        case .reconnecting: self = .reconnecting
        case .needsPairing: self = .pairAgain
        case .offline: self = .offline(nil)
        case .idle, .pairing: self = .offline(nil)
        }
    }

    var text: String {
        switch self {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .offline: return "Offline"
        case .pairAgain: return "Pair again"
        }
    }

    var isLive: Bool { self == .connected }
}

/// One row of the Phones section. `id` is the phone's device id: every
/// per-phone section is keyed by it, never by "the phone".
struct DevicePhoneRow: Equatable, Identifiable {
    let id: String
    let name: String
    let model: String
    let presenceText: String
    let lastSeenText: String?
    let inUse: Bool
    /// False for the in-use phone and for one whose key is gone.
    let canUseThisPhone: Bool
    let pairAgain: Bool
}

/// An app's two lines: its name and, for a system package without a friendly
/// name of its own, the package name underneath.
struct AppName: Equatable {
    let title: String
    let packageBelow: String?
}

struct MutedAppRow: Equatable, Identifiable {
    let pkg: String
    let title: String
    let packageBelow: String?
    /// Sent at least one notification this session.
    let seen: Bool
    let muted: Bool

    var id: String { pkg }
}

enum DevicesTabModel {

    struct Labels: Sendable {
        let searchField = "Search apps"
        let mutedColumn = "Muted"
        let inUse = "In use"
        let addPhone = "Add Phone…"
        func mute(_ name: String) -> String { "Mute \(name)" }
        func details(_ name: String) -> String { "Settings for \(name)" }
        func sent(_ name: String) -> String { "\(name) sent a notification this session" }
    }

    static let labels = Labels()

    static func phoneRow(id: String, name: String, model: String, presence: DevicePresence,
                         lastSeen: String, inUse: Bool) -> DevicePhoneRow {
        DevicePhoneRow(
            id: id, name: name, model: model, presenceText: presence.text,
            lastSeenText: presence.isLive ? nil : lastSeen,
            inUse: inUse,
            // A phone whose key is gone reads Pair again, so it is the one case
            // that can be reached but not used.
            canUseThisPhone: !inUse && presence != .pairAgain,
            pairAgain: presence == .pairAgain)
    }

    static func mutedCountText(_ count: Int) -> String {
        count == 0 ? "None" : "\(count)"
    }

    /// System packages have no launcher label; the list names them anyway.
    private static let friendlySystemNames: [String: String] = [
        "com.android.systemui": "System UI",
        "com.android.shell": "Shell",
        "android": "Android System",
    ]

    static func appName(pkg: String, label: String?) -> AppName {
        if let label, !label.isEmpty, label != pkg {
            return AppName(title: label, packageBelow: nil)
        }
        if let friendly = friendlySystemNames[pkg] {
            return AppName(title: friendly, packageBelow: pkg)
        }
        return AppName(title: pkg, packageBelow: nil)
    }

    /// Every app the Mac knows for this phone plus the muted and seen packages,
    /// muted first, then by the name the row shows, filtered by the search text.
    static func mutedRows(apps: [AppInfo], seen: Set<String>, muted: Set<String>,
                          query: String) -> [MutedAppRow] {
        var labels: [String: String] = [:]
        for app in apps { labels[app.pkg] = app.label }
        var packages = Set(apps.map(\.pkg))
        packages.formUnion(seen)
        packages.formUnion(muted)
        let rows = packages.map { pkg -> MutedAppRow in
            let name = appName(pkg: pkg, label: labels[pkg])
            return MutedAppRow(pkg: pkg, title: name.title, packageBelow: name.packageBelow,
                               seen: seen.contains(pkg), muted: muted.contains(pkg))
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let matching = rows.filter { row in
            trimmed.isEmpty
                || row.title.localizedCaseInsensitiveContains(trimmed)
                || row.pkg.localizedCaseInsensitiveContains(trimmed)
        }
        return matching.sorted { a, b in
            if a.muted != b.muted { return a.muted }
            let order = a.title.localizedStandardCompare(b.title)
            if order != .orderedSame { return order == .orderedAscending }
            return a.pkg < b.pkg
        }
    }

    /// The Mac's row says why nothing is forwarded even though sharing is on.
    static func accessHint(noAccess: Bool) -> String? {
        noAccess ? "Allow notification access on the phone." : nil
    }
}
