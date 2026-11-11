// Several windows of one app on one phone (docs/specs/app-windows.md
// WIN-24…WIN-36): the rules as values.
//
// Three things here have states the person reads:
//   * whether "New <App> Window" can act, and the one sentence that says why
//     not (WIN-25, WIN-27, WIN-32, WIN-34);
//   * how a window is named: the short form while the app has one window, the
//     task's label from the second on (WIN-3, WIN-28);
//   * the link's phase, which the New items and every window's pill follow
//     ("Reconnecting…" after 1 s, "Phone offline" after 15 s; WIN-16, WIN-34).
//
// Everything is a pure value over what the phone reported, so the menus, the
// Deck cell, the Dock shim and the tests all read the same answer.

import Foundation

// MARK: - The link's phase

/// What the New items call the link while it is down. The windows' own pill
/// reads the same two sentences.
enum PhoneLinkPhase: Equatable {
    case up
    /// The link dropped less than `offlineAfter` ago: "Reconnecting…".
    case reconnecting
    /// It has been down for `offlineAfter`: "Phone offline".
    case offline

    /// The sentence an item carries while it cannot act (nil when up).
    var sentence: String? {
        switch self {
        case .up: return nil
        case .reconnecting: return "Reconnecting…"
        case .offline: return "Phone offline"
        }
    }
}

/// The one clock behind `PhoneLinkPhase`: pure, so the 1 s / 15 s rule is a
/// transition table rather than two timers that can drift.
struct LinkPhaseClock: Equatable {
    /// The window's pill shows "Reconnecting…" after this long.
    static let reconnectingAfter: TimeInterval = 1
    /// ...and says the phone is away after this long.
    static let offlineAfter: TimeInterval = 15

    private(set) var phase = PhoneLinkPhase.up
    /// When the link dropped; nil while it is up.
    private(set) var downAt: TimeInterval?

    /// The link dropped at `now`. A second drop while it is down changes
    /// nothing: the phase keeps counting from the first.
    mutating func linkLost(at now: TimeInterval) -> PhoneLinkPhase {
        guard downAt == nil else { return phase }
        downAt = now
        phase = .reconnecting
        return phase
    }

    mutating func linkRestored() -> PhoneLinkPhase {
        downAt = nil
        phase = .up
        return phase
    }

    /// Folds the elapsed time in: reconnecting becomes offline at 15 s.
    mutating func tick(at now: TimeInterval) -> PhoneLinkPhase {
        guard let downAt, phase == .reconnecting,
              now - downAt >= Self.offlineAfter else { return phase }
        phase = .offline
        return phase
    }

    /// When the next phase change is due, for a one-shot timer (nil when up).
    func nextChange(at now: TimeInterval) -> (phase: PhoneLinkPhase, at: TimeInterval)? {
        guard let downAt else { return nil }
        switch phase {
        case .up: return nil
        case .reconnecting: return (.offline, downAt + Self.offlineAfter)
        case .offline: return nil
        }
    }
}

// MARK: - Whether a New Window item can act

/// Why a New Window item is disabled. Each case owns one sentence, because the
/// help tag, the VoiceOver hint and the Deck's banner must read the same words
/// (WIN-27, WIN-32, CONV-PD-09).
enum NewWindowBlocker: Equatable {
    /// The phone says this app opens one window (WIN-27).
    case oneWindow
    /// The phone is already at its window cap (WIN-27, WIN-32).
    case atCap
    /// A window of this app is still opening (WIN-27).
    case opening
    /// The link is down (WIN-34).
    case link(PhoneLinkPhase)
    /// Nothing to name: no phone, or no app window key (MENU-2).
    case noApp

    /// The exact sentence, or nil while the item may act.
    func sentence(app: String) -> String? {
        switch self {
        case .oneWindow: return "\(app) opens one window at a time."
        case .atCap: return "Close a \(app) window to open another."
        case .opening: return "Opening on your phone…"
        case .link(let phase): return phase.sentence
        case .noApp: return nil
        }
    }
}

/// The File ▸ New <App> Window item (and the Dock and Deck menus' first row):
/// its words, whether it may act, and the sentence when it may not.
struct NewWindowItem: Equatable {
    var title: String
    var enabled: Bool
    var help: String?
    /// Why it cannot act, for the callers that must tell the cap apart from
    /// the silent blocks (an adopted task at the cap shows the Deck's notice).
    var blocker: NewWindowBlocker? = nil

    /// The item for the key app, `app` being its label ("Chrome") or nil when
    /// no app window is key (then it reads "New Window").
    ///
    /// Precedence, in the order the person needs it: no app → nothing to open;
    /// link down → nothing can be sent; the app cannot do it at all → the
    /// permanent reason; a window is still opening → the temporary one; the
    /// phone is at its cap → open another only after closing one.
    static func make(app: String?, windowCount: Int, multi: Bool, opening: Bool,
                     cap: Int, link: PhoneLinkPhase) -> NewWindowItem {
        guard let app else {
            return NewWindowItem(title: "New Window", enabled: false, help: nil, blocker: .noApp)
        }
        let blocker: NewWindowBlocker?
        if link != .up {
            blocker = .link(link)
        } else if !multi {
            blocker = .oneWindow
        } else if opening {
            blocker = .opening
        } else if windowCount >= cap {
            blocker = .atCap
        } else {
            blocker = nil
        }
        return NewWindowItem(title: "New \(app) Window",
                             enabled: blocker == nil,
                             help: blocker?.sentence(app: app),
                             blocker: blocker)
    }
}

// MARK: - Titles

/// How a window and a menu row are named (WIN-3, WIN-26, WIN-28, WIN-29).
enum WindowTitles {
    /// "<App> (<phone>)"; the phone part is left out while no name is known.
    static func short(_ app: String, phone: String) -> String {
        phone.isEmpty ? app : "\(app) (\(phone))"
    }

    /// "<App> — <task label> (<phone>)": the task's label when the phone
    /// reported one, the app's own label when it did not (WIN-28).
    static func task(_ app: String, label: String?, phone: String) -> String {
        taskOnly(app, label: label).appending(phone.isEmpty ? "" : " (\(phone))")
    }

    /// "<App> — <task label>", the Dock shim's and the Deck cell's wording
    /// (WIN-26; those menus are per phone already).
    static func taskOnly(_ app: String, label: String?) -> String {
        let task = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(app) — \(task.isEmpty ? app : task)"
    }

    /// The window's title: its task while the app has two or more windows, the
    /// short form when it is alone (WIN-28).
    static func title(app: String, label: String?, phone: String, windowCount: Int) -> String {
        windowCount > 1 ? task(app, label: label, phone: phone) : short(app, phone: phone)
    }
}

// MARK: - The Dock shim's and the Deck cell's menu

/// One row of an app's window menu, as a value. The Dock shim's `NSMenu` and
/// the Deck cell's SwiftUI menu both render this list, so they cannot disagree
/// (WIN-26).
struct AppWindowMenuRow: Equatable {
    enum Action: Equatable {
        case newWindow
        case raise(stream: UInt32)
    }

    var title: String
    var action: Action
    var checked = false
    var enabled = true
    /// The sentence a disabled row carries as help tag and VoiceOver hint.
    var help: String?
    /// The item's key, for the menus that can carry one (⌘N).
    var key: String?

    var stream: UInt32? {
        if case .raise(let stream) = action { return stream }
        return nil
    }
}

enum AppWindowMenu {
    /// New <App> Window ⌘N, then the open windows front to back, the front one
    /// checked. No separator is part of the value: the menus draw one between
    /// the New item and the list only when there is a list.
    static func rows(app: String, windows: [(stream: UInt32, label: String?)],
                     newWindow: NewWindowItem) -> [AppWindowMenuRow] {
        var rows = [AppWindowMenuRow(title: newWindow.title, action: .newWindow,
                                     enabled: newWindow.enabled, help: newWindow.help,
                                     key: newWindow.enabled ? "n" : nil)]
        for (index, window) in windows.enumerated() {
            var row = AppWindowMenuRow(title: WindowTitles.taskOnly(app, label: window.label),
                                       action: .raise(stream: window.stream))
            row.checked = index == 0
            rows.append(row)
        }
        return rows
    }

    /// The row a pick runs: the first row with that title. A disabled row is
    /// not a pick at all (it sends nothing — WIN-27).
    static func pick(_ title: String, in rows: [AppWindowMenuRow]) -> AppWindowMenuRow? {
        guard let row = rows.first(where: { $0.title == title }), row.enabled else { return nil }
        return row
    }
}

// MARK: - The row as a message

// The host builds the rows and the Dock shim renders them, so the one shape
// they exchange is here, next to the rules (it is compiled into both programs).

extension AppWindowMenuRow {
    /// The dictionary a shim receives: property-list types only, because it
    /// travels in a distributed notification's userInfo.
    var message: [String: Any] {
        var message: [String: Any] = ["title": title, "enabled": enabled, "checked": checked]
        switch action {
        case .newWindow:
            message["action"] = "new"
            message["stream"] = 0
        case .raise(let stream):
            message["action"] = "raise"
            message["stream"] = Int(stream)
        }
        if let help { message["help"] = help }
        if let key { message["key"] = key }
        return message
    }

    init?(message: [String: Any]) {
        guard let title = message["title"] as? String,
              let action = message["action"] as? String else { return nil }
        let stream = UInt32(max(0, message["stream"] as? Int ?? 0))
        self.init(title: title,
                  action: action == "new" ? .newWindow : .raise(stream: stream),
                  checked: message["checked"] as? Bool ?? false,
                  enabled: message["enabled"] as? Bool ?? false,
                  help: message["help"] as? String,
                  key: message["key"] as? String)
    }
}
