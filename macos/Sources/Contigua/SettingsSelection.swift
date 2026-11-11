// The Settings window's one piece of navigation state (docs/specs/settings.md):
// which page the sidebar shows. One closed set of states, one pure transition
// function with its actions returned rather than performed, so the rules below
// are unit-tested without a window (SettingsSidebarTests).

import Foundation

/// A page the sidebar can show. A phone page carries its device id, never "the
/// phone", so two phones never share a page.
enum SettingsSelection: Hashable, Sendable {
    case general
    case input
    case automation
    case phone(String)

    /// The value stored in the profile's defaults.
    var storeValue: String {
        switch self {
        case .general: return "general"
        case .input: return "input"
        case .automation: return "automation"
        case .phone(let id): return "phone:\(id)"
        }
    }

    init?(storeValue: String) {
        switch storeValue {
        case "general": self = .general
        case "input": self = .input
        case "automation": self = .automation
        default:
            guard storeValue.hasPrefix("phone:") else { return nil }
            let id = String(storeValue.dropFirst("phone:".count))
            guard !id.isEmpty else { return nil }
            self = .phone(id)
        }
    }

    var isPhonePage: Bool {
        if case .phone = self { return true }
        return false
    }
}

enum SettingsSelectionEvent: Equatable {
    /// The window opened: a stored preference, else the phone in use, else the
    /// first phone, else General.
    case open(stored: String?, phones: [String], inUse: String?)
    /// A row was chosen. A phone that is not remembered is ignored.
    case choose(SettingsSelection, phones: [String])
    /// Add Phone… was chosen: the sheet opens, the selection does not move.
    case addPhone
    /// The remembered phones changed (paired, forgotten elsewhere, renamed).
    case phonesChanged(phones: [String], inUse: String?)
    /// This Mac forgot `deviceId`; if it was the page, the next phone takes it.
    case forgot(deviceId: String, phones: [String], inUse: String?)
}

/// What the window must do after a transition. The transition never performs
/// them itself, so the state rules stay pure.
enum SettingsSelectionAction: Equatable {
    /// The Deck's one add-phone sheet (`DeckWindow.show` + the sheet).
    case addPhoneSheet
    /// Store the page as this profile's last selection.
    case store
}

struct SettingsSelectionStep: Equatable {
    let selection: SettingsSelection
    let actions: [SettingsSelectionAction]
}

enum SettingsSelectionMachine {

    /// The page a phone selection falls back to: the phone in use, else the
    /// first remembered phone, else General (spec SET-WIN-03).
    static func phonePage(phones: [String], inUse: String?) -> SettingsSelection {
        if let inUse, phones.contains(inUse) { return .phone(inUse) }
        if let first = phones.first { return .phone(first) }
        return .general
    }

    static func step(from current: SettingsSelection, event: SettingsSelectionEvent) -> SettingsSelectionStep {
        switch event {
        case .open(let stored, let phones, let inUse):
            var page = phonePage(phones: phones, inUse: inUse)
            if let decoded = stored.flatMap(SettingsSelection.init(storeValue:)) {
                switch decoded {
                case .phone(let id):
                    // A stored phone that is gone is replaced by the phone rule.
                    if phones.contains(id) { page = .phone(id) }
                case .general, .input, .automation:
                    // A Mac section reopens even when no phone is remembered.
                    page = decoded
                }
            }
            return SettingsSelectionStep(selection: page, actions: [.store])

        case .choose(let page, let phones):
            if case .phone(let id) = page, !phones.contains(id) {
                return SettingsSelectionStep(selection: current, actions: [])
            }
            return SettingsSelectionStep(selection: page, actions: page == current ? [] : [.store])

        case .addPhone:
            return SettingsSelectionStep(selection: current, actions: [.addPhoneSheet])

        case .phonesChanged(let phones, let inUse):
            return replacement(for: current, phones: phones, inUse: inUse)

        case .forgot(_, let phones, let inUse):
            // The forgotten phone may be the page; the phone rule then picks
            // the next phone (or General). Forgetting another phone keeps it.
            return replacement(for: current, phones: phones, inUse: inUse)
        }
    }

    /// Keep the page while its phone exists; otherwise the phone rule.
    private static func replacement(for current: SettingsSelection, phones: [String],
                                    inUse: String?) -> SettingsSelectionStep {
        if case .phone(let id) = current, phones.contains(id) {
            return SettingsSelectionStep(selection: current, actions: [])
        }
        if current.isPhonePage {
            let page = phonePage(phones: phones, inUse: inUse)
            return SettingsSelectionStep(selection: page, actions: [.store])
        }
        return SettingsSelectionStep(selection: current, actions: [])
    }
}

/// The last selection, per profile (spec SET-WIN-04).
enum SettingsSelectionStore {
    static let key = "settings.selection"

    static func read(from defaults: UserDefaults) -> String? {
        defaults.string(forKey: key)
    }

    static func write(_ selection: SettingsSelection, to defaults: UserDefaults) {
        defaults.set(selection.storeValue, forKey: key)
    }
}
