// The edge rule behind every control the Mac sets on the phone
// (docs/specs/controls.md): a Mac intent is applied on its edge, not
// re-asserted. The person's change on the phone stands until the Mac-side
// intent changes again, and a reconnect sends a value only when it changed
// while the two were apart. One machine, shared by every control whose value a
// person can also change on the phone.

import Foundation

/// The controls the Mac sets and the phone can change back. The name is the
/// one in the log line and in the profile's defaults key.
enum ControlKind: String, CaseIterable {
    case dnd
    case panel
}

/// What this Mac last sent one phone for one control. The value is a wire token
/// from that control's closed set (`priority`, `off`, …), never anything a
/// person typed.
enum ControlIntentState: Equatable {
    /// The phone's last report was this value: the phone is in it.
    case applied(String)
    /// This is the last value we sent, and the phone reported something else
    /// since: the person changed it on the phone, so their value stands.
    case overridden(String)

    /// The last value this phone received. A connect compares the Mac's intent
    /// against it: equal means there is nothing new to apply.
    var lastSent: String {
        switch self {
        case .applied(let value): return value
        case .overridden(let value): return value
        }
    }
}

enum ControlIntentEvent: Equatable {
    /// The Mac's intent changed: a Focus started or ended, or its parameters
    /// changed. Always an edge, even when the value repeats.
    case intentChanged(String)
    /// The person used the control on the Mac (menu, Shortcut, control, MCP,
    /// the window's button). Always an edge: they asked again.
    case personAction(String)
    /// The phone reported what it holds now.
    case phoneReported(String)
    /// This phone can take the control now: a new session's first state, or a
    /// phone window that opened. Applies only what the phone has not had.
    case connected(String)

    /// The event's name for the log: a closed token, never a value.
    var token: String {
        switch self {
        case .intentChanged: return "intent"
        case .personAction: return "action"
        case .phoneReported: return "report"
        case .connected: return "connect"
        }
    }
}

enum ControlIntentAction: Equatable {
    case send(String)
}

enum ControlIntentMachine {
    /// The next state (nil = this phone has no memory yet) and what to run.
    static func transition(_ state: ControlIntentState?,
                            _ event: ControlIntentEvent) -> (state: ControlIntentState?, actions: [ControlIntentAction]) {
        switch event {
        case .intentChanged(let value), .personAction(let value):
            return (.applied(value), [.send(value)])

        case .phoneReported(let value):
            guard let state else { return (nil, []) }
            guard value != state.lastSent else { return (.applied(value), []) }
            return (.overridden(state.lastSent), [])

        case .connected(let wanted):
            guard let state else {
                // This phone never received one: its first connect is the edge.
                return (.applied(wanted), [.send(wanted)])
            }
            guard state.lastSent != wanted else { return (state, []) }
            return (.applied(wanted), [.send(wanted)])
        }
    }
}

/// The names the state machine logs: closed tokens, no values.
enum ControlIntentLabel {
    static func state(_ state: ControlIntentState?) -> String {
        switch state {
        case nil: return "none"
        case .applied: return "applied"
        case .overridden: return "overridden"
        }
    }
}

/// The live side for one control: reads this phone's memory, applies one event,
/// logs the path as closed tokens and returns what to send.
struct ControlIntentRecorder {
    let store: ControlIntentStore

    @MainActor
    func record(_ event: ControlIntentEvent, deviceId: String) -> [ControlIntentAction] {
        let before = store.load(deviceId: deviceId)
        let step = ControlIntentMachine.transition(before, event)
        store.save(step.state, deviceId: deviceId)
        let sends = step.actions.contains { action in
            if case .send = action { return true }
            return false
        }
        Log.session.notice("controlintent \(store.control.rawValue, privacy: .public): \(ControlIntentLabel.state(before), privacy: .public) --\(event.token, privacy: .public)--> \(ControlIntentLabel.state(step.state), privacy: .public) \(sends ? "send" : "none", privacy: .public)")
        return step.actions
    }
}

/// The Mac's memory of the edge, per control and per phone, in the profile's
/// defaults: it must outlive the app, because a reconnect is what re-asserts.
/// The phone's own `setByMac` is the restore memory and is cleared when the
/// person changes the control; this one decides whether a connect has anything
/// new to send, so it holds the last value this phone received.
struct ControlIntentStore {
    private let defaults: UserDefaults
    let control: ControlKind

    init(defaults: UserDefaults, control: ControlKind) {
        self.defaults = defaults
        self.control = control
    }

    private var key: String { "controlIntent.\(control.rawValue)" }

    func load(deviceId: String) -> ControlIntentState? {
        guard !deviceId.isEmpty else { return nil }
        let all = defaults.dictionary(forKey: key) as? [String: String]
        guard let raw = all?[deviceId] else { return nil }
        if raw.hasPrefix("a:") { return .applied(String(raw.dropFirst(2))) }
        if raw.hasPrefix("o:") { return .overridden(String(raw.dropFirst(2))) }
        return nil
    }

    func save(_ state: ControlIntentState?, deviceId: String) {
        guard !deviceId.isEmpty else { return }
        var all = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        switch state {
        case .applied(let value)?: all[deviceId] = "a:" + value
        case .overridden(let value)?: all[deviceId] = "o:" + value
        case nil: all.removeValue(forKey: deviceId)
        }
        if all.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(all, forKey: key) }
    }
}
