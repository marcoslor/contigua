// The Focus filter and the manual DND intent (docs/design/focus.md). The
// decisions live in FocusCore, the app side in FocusBridge; here is only the
// system-facing shape. Both run the same controller methods as the menu bar
// item and the hidden e2e hooks.

import AppIntents
import Foundation

/// The filter's "Allow" picker.
enum FocusAllowEntity: String, AppEnum {
    case priority
    case alarms
    case nothing

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Allow")
    static var caseDisplayRepresentations: [FocusAllowEntity: DisplayRepresentation] = [
        .priority: DisplayRepresentation(title: "Priority notifications"),
        .alarms: DisplayRepresentation(title: "Alarms only"),
        .nothing: DisplayRepresentation(title: "Nothing"),
    ]

    var core: FocusAllow {
        switch self {
        case .priority: return .priority
        case .alarms: return .alarms
        case .nothing: return .nothing
        }
    }
}

/// The manual intent's mode picker.
enum PhoneDndEntity: String, AppEnum {
    case priority
    case alarms
    case none

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "DND mode")
    static var caseDisplayRepresentations: [PhoneDndEntity: DisplayRepresentation] = [
        .priority: DisplayRepresentation(title: "Priority"),
        .alarms: DisplayRepresentation(title: "Alarms only"),
        .none: DisplayRepresentation(title: "Nothing"),
    ]

    var core: PhoneDndMode {
        switch self {
        case .priority: return .priority
        case .alarms: return .alarms
        case .none: return .none
        }
    }
}

/// "PocketDeck" in a Focus's filter list: silences the phone while that Focus
/// runs. `perform()` stores the wanted state; a disconnected phone gets it when
/// it connects.
struct PocketDeckFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Use PocketDeck"
    static var description = IntentDescription(
        "Silences your phone while this Focus is on, and lets it speak again when the Focus ends.")

    @Parameter(title: "Silence my phone", default: true)
    var silence: Bool

    @Parameter(title: "Allow", default: FocusAllowEntity.priority)
    var allow: FocusAllowEntity

    var displayRepresentation: DisplayRepresentation {
        if !silence { return DisplayRepresentation(title: "Phone stays as it is") }
        switch allow {
        case .priority: return DisplayRepresentation(title: "Silence my phone", subtitle: "Priority notifications")
        case .alarms: return DisplayRepresentation(title: "Silence my phone", subtitle: "Alarms only")
        case .nothing: return DisplayRepresentation(title: "Silence my phone", subtitle: "Nothing")
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        FocusBridge.apply(FocusFilterValues(enabled: true, silence: silence, allow: allow.core))
        return .result()
    }
}

/// Shortcuts/Siri: turn the phone's DND on (in a mode) or off by hand.
struct SetPhoneDNDIntent: AppIntent {
    static var title: LocalizedStringResource = "Phone Do Not Disturb"
    static var description = IntentDescription(
        "Turns your phone's Do Not Disturb on or off. Off only undoes what PocketDeck turned on.")

    @Parameter(title: "On", default: true)
    var on: Bool

    @Parameter(title: "Mode", default: PhoneDndEntity.priority)
    var mode: PhoneDndEntity

    @Parameter(title: "Phone")
    var phone: PhoneEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = try IntentsBridge.resolve(phone?.id)
        return .result(dialog: "\(try IntentsBridge.setPhoneDnd(on: on, mode: mode.core, on: target))")
    }
}

/// The bridge both intents use, so the debug hooks and the system paths are one
/// code path. Main-actor: the controller owns the session and the menu state.
@MainActor
enum FocusBridge {
    static func apply(_ values: FocusFilterValues) {
        AppEnvironment.shared.controller.setFocusFilter(values)
    }

    /// The system's current filter, or "no Focus has it". Called at launch and
    /// before a new connection reconciles. Stores only: the connection's one
    /// reconcile is what sends, so a refresh never duplicates it.
    static func refreshFromSystem() async {
        do {
            let current = try await PocketDeckFocusFilter.current
            AppEnvironment.shared.controller.storeFocusValues(
                FocusFilterValues(enabled: true, silence: current.silence, allow: current.allow.core))
        } catch SetFocusFilterIntentError.notFound {
            // No Focus has this filter (or the Focus ended while the app was
            // not running): "not wanted", which the phone reads as restore.
            var values = AppEnvironment.shared.controller.focusValues
            values.enabled = false
            AppEnvironment.shared.controller.storeFocusValues(values)
        } catch {
            // No Focus on this Mac, or the system cannot answer: keep what the
            // last perform() stored rather than guessing.
        }
    }
}
