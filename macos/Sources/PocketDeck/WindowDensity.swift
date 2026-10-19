// Density: the Settings default, the per-app overrides the View ▸ Density
// submenu and ⌘+/⌘-/⌘0 write, and the rules both follow.
//
// Everything here is pure apart from the store's defaults reads and writes:
// the windows, the menu and the unit tests read the same numbers.

import Foundation

enum WindowDensity {
    static let key = "defaultDensity"
    static let options: [(label: String, value: Double)] = [("75%", 0.75), ("100%", 1.0), ("125%", 1.25), ("150%", 1.5)]

    /// Unset or unreadable is 100%.
    static func value(in defaults: UserDefaults) -> Double {
        let stored = defaults.double(forKey: key)
        return stored == 0 ? 1.0 : stored
    }
}

/// Where each app's density override lives: one key per package, the same
/// scheme as the style store. The phone window has no package and no override.
struct WindowDensityStore {
    static let prefix = "chrome.density."

    let defaults: UserDefaults

    /// nil for a window that shows no app (the phone window, or a link window
    /// before the phone names its package).
    static func key(forPackage package: String?) -> String? {
        guard let package, !package.isEmpty else { return nil }
        return prefix + package
    }

    /// nil when the app follows the Settings default.
    func override(forKey key: String?) -> Double? {
        guard let key, defaults.object(forKey: key) != nil else { return nil }
        let value = defaults.double(forKey: key)
        return value > 0 ? value : nil
    }

    /// nil clears the override.
    func set(_ value: Double?, forKey key: String?) {
        guard let key else { return }
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// Every app's override, package → value.
    func all() -> [String: Double] {
        var result: [String: Double] = [:]
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) {
            let package = String(key.dropFirst(Self.prefix.count))
            let value = defaults.double(forKey: key)
            if !package.isEmpty, value > 0 { result[package] = value }
        }
        return result
    }

    func clearAll() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) {
            defaults.removeObject(forKey: key)
        }
    }
}

/// One app's stored override, as Settings → General lists it.
struct DensityOverride: Identifiable, Equatable {
    let pkg: String
    let value: Double
    var id: String { pkg }
}

/// The effective density a window uses and the keyboard steps.
enum DensityRules {
    static let range = 0.75...1.5
    /// One ⌘+/⌘- step.
    static let step = 0.25

    /// An app's override, else the Settings default.
    static func effective(override: Double?, settings: Double) -> Double {
        (override ?? settings).clamped(to: range)
    }

    /// The value one ⌘+/⌘- step lands on: clamped to the range and rounded to
    /// three places, so 0.75 + 0.25 is exactly 1.
    static func stepped(from value: Double, by delta: Double) -> Double {
        (value + delta).rounded(toPlaces: 3).clamped(to: range)
    }

    static func percentLabel(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

/// Which View ▸ Density item carries the check mark.
enum DensityCheck: Equatable {
    /// The app follows the Settings default.
    case defaultItem
    /// The app's override is exactly this value (one of the options).
    case value(Double)
    /// An override no option names (⌘+/⌘- can land between them).
    case none

    static func forOverride(_ override: Double?,
                            options: [Double] = WindowDensity.options.map(\.value)) -> DensityCheck {
        guard let override else { return .defaultItem }
        let rounded = override.rounded(toPlaces: 3)
        guard let match = options.first(where: { abs($0 - rounded) < 0.0005 }) else { return .none }
        return .value(match)
    }
}
