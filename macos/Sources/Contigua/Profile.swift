// The namespace for everything Contigua keeps on this Mac.
//
// `default` is the user's own app and keeps today's storage (standard
// defaults, the same folders), so existing
// pairings and caches stay where they are. Any other name is a separate copy
// of that state: the test harness runs under its own profile and can never
// read or delete the user's pairings, cached phones or icons.

import Foundation

struct Profile: Equatable {
    static let defaultName = "default"
    static let bundleId = "app.contigua.mac"
    static let `default` = Profile(validatedName: defaultName)

    /// The profile of this process. Set once at launch, before any state is
    /// touched; the process-wide singletons (icon cache, latency log) read it.
    static var active: Profile = .default

    let name: String

    private init(validatedName: String) { name = validatedName }

    /// nil when the name cannot be used in a defaults suite or a folder name:
    /// lowercase letters, digits and `-`, 1–32 chars.
    init?(name: String) {
        guard Self.isValidName(name) else { return nil }
        self.name = name
    }

    static func isValidName(_ name: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        return (1...32).contains(name.count) && name.allSatisfy { allowed.contains($0) }
    }

    var isDefault: Bool { name == Self.defaultName }

    /// This profile's Application Support folder: identity.json, pins.json,
    /// files-ids.json and the rest live here.
    var supportDirectoryUrl: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(supportDirectoryName, isDirectory: true)
    }

    /// The app-owned identifier ↔ path map for phone files in Finder (design
    /// §3, S4): one small JSON per profile, 0600.
    var filesIdMapUrl: URL {
        supportDirectoryUrl.appendingPathComponent("files-ids.json")
    }

    /// Name of the UserDefaults suite; nil means the standard defaults.
    var defaultsSuiteName: String? { isDefault ? nil : "\(Self.bundleId).\(name)" }

    var defaults: UserDefaults {
        // The suite name always has a suffix, so it is never the app's own
        // bundle id (for which UserDefaults(suiteName:) returns nil).
        guard let suite = defaultsSuiteName else { return .standard }
        return UserDefaults(suiteName: suite)!
    }

    /// Prefixed to CoreSpotlight domain and item identifiers, so one profile's
    /// index entries never replace or delete another profile's.
    var spotlightDomainPrefix: String { isDefault ? "" : "\(name)." }

    /// Folder name under ~/Library/Caches (icons), ~/Library/Logs (latency) and
    /// ~/Library/Application Support (pair keys).
    var supportDirectoryName: String { isDefault ? "Contigua" : "Contigua-\(name)" }
}
