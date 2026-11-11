// What the View, Navigate and Phone menus show about the key window. SwiftUI's
// menu commands cannot see AppKit windows, so the window controllers publish
// here. The key window is one explicit machine: only a stream window has the
// per-window values the stream-only items show, and any other key window drops
// them whole, so a value cannot outlive the window it described (MENU-4,
// MENU-6, MENU-9).

import CoreGraphics
import Observation

// MARK: - The values of a key stream window

/// Everything the stream-only menu items show about the key stream window.
/// Only a key stream window carries these: becoming key replaces the whole set
/// and any other key window drops it (ISS-88).
struct StreamMenuValues: Equatable {
    /// The stream, so a late resign from another window cannot clear this one.
    let stream: UInt32
    var style: WindowStyle = .standard
    var liveText = false
    var frozen = false
    var phoneOffline = false
    var phoneWindow = false
    var panelOff = false
    var densityPackage: String?
    var densityOverride: Double?

    init(stream: UInt32, style: WindowStyle = .standard, liveText: Bool = false,
         frozen: Bool = false, phoneOffline: Bool = false, phoneWindow: Bool = false,
         panelOff: Bool = false, densityPackage: String? = nil,
         densityOverride: Double? = nil) {
        self.stream = stream
        self.style = style
        self.liveText = liveText
        self.frozen = frozen
        self.phoneOffline = phoneOffline
        self.phoneWindow = phoneWindow
        self.panelOff = panelOff
        self.densityPackage = densityPackage
        self.densityOverride = densityOverride
    }
}

// MARK: - The machine

/// Which window the stream-only menu items follow. Closed states, one pure
/// `(state, event) -> (state, actions)` with an exhaustive switch: the menus
/// correct their items whenever a transition returns `.correctMenu`.
struct StreamMenuKeyMachine: Equatable {
    enum Key: Equatable {
        /// No window, or one that is not a stream window: the Deck, Settings, a
        /// sheet, the panel. The stream-only items are off and disabled.
        case noStream
        /// A stream window is key, with the values its items show.
        case stream(StreamMenuValues)
    }

    enum Event: Equatable {
        case streamBecameKey(StreamMenuValues)
        /// The key window's own values moved (style, Live Text, a phone report,
        /// an override). Ignored unless the event names the key stream window.
        case streamValuesChanged(StreamMenuValues)
        case streamResigned(stream: UInt32)
        case otherWindowBecameKey
        case appDeactivated
        case reset
    }

    enum Action: Equatable {
        /// Write the key window's values onto the menu's existing items.
        case correctMenu
    }

    private(set) var key: Key = .noStream

    var values: StreamMenuValues? {
        if case .stream(let values) = key { return values }
        return nil
    }

    var hasStream: Bool { values != nil }

    /// The state's name for the transition log: a closed set, never a value.
    var name: String {
        switch key {
        case .noStream: "no stream"
        case .stream: "stream key"
        }
    }

    /// The event's name for the transition log.
    static func name(of event: Event) -> String {
        switch event {
        case .streamBecameKey: "streamBecameKey"
        case .streamValuesChanged: "streamValuesChanged"
        case .streamResigned: "streamResigned"
        case .otherWindowBecameKey: "otherWindowBecameKey"
        case .appDeactivated: "appDeactivated"
        case .reset: "reset"
        }
    }

    mutating func handle(_ event: Event) -> [Action] {
        switch (key, event) {
        case (.noStream, .streamBecameKey(let values)):
            key = .stream(values)
        case (.stream(let current), .streamBecameKey(let values)):
            // The key moved between stream windows (or came back to this one):
            // the new window's values replace the old set whole.
            guard values != current else { return [] }
            key = .stream(values)
        case (.stream(let current), .streamValuesChanged(let values)):
            // Another window's values never reach the key window's items.
            guard values.stream == current.stream, values != current else { return [] }
            key = .stream(values)
        case (.stream(let current), .streamResigned(let stream)):
            guard stream == current.stream else { return [] }
            key = .noStream
        case (.noStream, .streamValuesChanged),
             (.noStream, .streamResigned),
             (_, .otherWindowBecameKey),
             (_, .appDeactivated),
             (_, .reset):
            // A window that is not a stream window took the key (or there is
            // none): every per-window value leaves with the window.
            guard hasStream else { return [] }
            key = .noStream
        }
        return [.correctMenu]
    }
}

// MARK: - What the app publishes

@Observable
final class StreamMenuState {
    static let shared = StreamMenuState()

    /// The key-window machine (MENU-4, MENU-6, MENU-9). Its values exist only
    /// while a stream window is key, so no read can see the last window's.
    private(set) var machine = StreamMenuKeyMachine()

    /// The settings every key window shares: Show Touches is one choice for
    /// every stream window, the reveal delay one for the menu, and the Deck's
    /// icon size is stored (DECK-6). They stay whether a stream window is key;
    /// the stream-only items still read them only with a key stream window.
    var showTouches = false
    /// Settings → General "Reveal controls after", for the Immersive submenu's
    /// checkmark (one value for every window).
    var revealDelay: RevealDelay = .short
    /// Settings → General "Default window density", for the Default item's
    /// label and for deciding what "Default" restores.
    var settingsDensity = 1.0
    /// The Deck's stored icon size (DECK-6), for View ▸ Icon Size's checkmark.
    /// Read from the profile when a menu opens, so the mark follows ⌘+ at once.
    var deckZoom: CGFloat = DeckZoom.defaultValue

    /// The app uses `shared`; a test builds its own to drive the menu rules.
    init() {}

    // MARK: Reading the key window

    var hasStream: Bool { machine.hasStream }
    /// The key stream window's style; the Deck's own default with none, so a
    /// "Framed" check can never come from a window that is no longer key.
    var style: WindowStyle { machine.values?.style ?? .standard }
    var liveText: Bool { machine.values?.liveText ?? false }
    var frozen: Bool { machine.values?.frozen ?? false }
    var phoneOffline: Bool { machine.values?.phoneOffline ?? false }
    var phoneWindow: Bool { machine.values?.phoneWindow ?? false }
    var panelOff: Bool { machine.values?.panelOff ?? false }
    var densityPackage: String? { machine.values?.densityPackage }
    var densityOverride: Double? { machine.values?.densityOverride }

    // MARK: Driving the machine

    /// One transition, logged as `menu key: <from> --<event>--> <to>`. The
    /// caller runs the returned actions; `.correctMenu` is `MenuMarks.apply`.
    @discardableResult
    func handle(_ event: StreamMenuKeyMachine.Event) -> [StreamMenuKeyMachine.Action] {
        let before = machine.name
        var next = machine
        let actions = next.handle(event)
        guard next != machine else { return [] }
        machine = next
        Log.app.notice("menu key: \(before, privacy: .public) --\(StreamMenuKeyMachine.name(of: event), privacy: .public)--> \(self.machine.name, privacy: .public)") // log-ok: closed machine state and event names, never a value
        return actions
    }
}
