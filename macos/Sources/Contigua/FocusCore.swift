// The decisions behind Focus sync (docs/design/focus.md): what a Focus filter
// asks for, what a connection reconciles, and what a menu click sends. No
// AppIntents or AppKit import: the filter, the menu and the unit tests share
// this core.

import Foundation

/// The phone's Do Not Disturb mode, named as `phone.dnd` and `state.dnd` do.
enum PhoneDndMode: String, CaseIterable, Equatable {
    case off
    case priority
    case alarms
    case none

    var isOn: Bool { self != .off }
}

/// The Focus filter's "Allow" parameter (docs/design/focus.md).
enum FocusAllow: String, CaseIterable, Equatable {
    case priority
    case alarms
    case nothing

    var dnd: PhoneDndMode {
        switch self {
        case .priority: return .priority
        case .alarms: return .alarms
        case .nothing: return .none
        }
    }
}

/// What the system last told Contigua about its Focus filter.
struct FocusFilterValues: Equatable {
    /// A Focus runs perform() with the filter.
    var enabled = false
    /// "Silence my phone"; off is the person turning the filter's action off.
    var silence = true
    var allow: FocusAllow = .priority

    /// nil = not wanted, which the phone treats as the restore rule.
    var wanted: PhoneDndMode? {
        guard enabled, silence else { return nil }
        return allow.dnd
    }
}

/// The stored filter values, in the profile's defaults (never the phone's).
final class FocusStore {
    private enum Key {
        static let enabled = "focusFilterEnabled"
        static let silence = "focusFilterSilence"
        static let allow = "focusFilterAllow"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    convenience init(profile: Profile) { self.init(defaults: profile.defaults) }

    func load() -> FocusFilterValues {
        var values = FocusFilterValues()
        values.enabled = defaults.bool(forKey: Key.enabled)
        // A profile with no stored value keeps the filter's documented default.
        values.silence = defaults.object(forKey: Key.silence) as? Bool ?? true
        values.allow = (defaults.string(forKey: Key.allow)).flatMap(FocusAllow.init(rawValue:)) ?? .priority
        return values
    }

    func save(_ values: FocusFilterValues) {
        defaults.set(values.enabled, forKey: Key.enabled)
        defaults.set(values.silence, forKey: Key.silence)
        defaults.set(values.allow.rawValue, forKey: Key.allow)
    }

    func clear() {
        defaults.removeObject(forKey: Key.enabled)
        defaults.removeObject(forKey: Key.silence)
        defaults.removeObject(forKey: Key.allow)
    }
}

enum FocusReconciler {
    /// A menu click: on becomes priority, on becomes off; nil (no phone or no
    /// DND support) does nothing.
    static func menuCommand(current: PhoneDndMode?) -> PhoneDndMode? {
        guard let current else { return nil }
        return current.isOn ? .off : .priority
    }

    /// The Shortcuts intent: on uses the chosen mode (off means priority), off
    /// always sends off and lets the phone's restore rule decide.
    static func intentCommand(on: Bool, mode: PhoneDndMode) -> PhoneDndMode {
        guard on else { return .off }
        return mode == .off ? .priority : mode
    }
}

/// The hidden e2e hooks (PD_TEST_HOOKS only). They parse the flag values and
/// feed the same controller methods the filter and the menu use.
enum FocusDebugCommand {
    /// `"on"` or `"on priority|alarms|none"` or `"off"`; nil for anything else.
    static func parseFilter(_ raw: String) -> FocusFilterValues? {
        let words = raw.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard let first = words.first else { return nil }
        switch first {
        case "off":
            guard words.count == 1 else { return nil }
            return FocusFilterValues(enabled: false, silence: true, allow: .priority)
        case "on":
            guard words.count <= 2 else { return nil }
            let allow: FocusAllow
            switch words.count == 2 ? words[1] : "priority" {
            case "priority": allow = .priority
            case "alarms": allow = .alarms
            case "none", "nothing": allow = .nothing
            default: return nil
            }
            return FocusFilterValues(enabled: true, silence: true, allow: allow)
        default:
            return nil
        }
    }

    /// `"on"` or `"off"` for the menu item's action.
    static func parseDnd(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "on": return true
        case "off": return false
        default: return nil
        }
    }
}

/// One JSON line per hidden focus command, on stderr (the harness keeps it in
/// app.log). Values are mode names and booleans only.
enum FocusDebugLog {
    static func write(focus: String, ok: Bool, fields: [String: Any] = [:]) {
        var object: [String: Any] = ["focus": focus, "ok": ok]
        for (key, value) in fields { object[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
