// The mirror's bar from the keyboard (MIRROR-13, CONV-MAC-03): Tab and the
// phone's keys belong to the phone, so the bar gets one Mac-owned key — ⌃Tab —
// and then moves between its buttons on its own. The focus is one explicit
// machine (picture ↔ bar(index)) so the keys can never be half the bar's:
//
//   picture --⌃Tab--> bar(first) --→/Tab--> bar(next) --Esc/⌃Tab--> picture
//   bar(i) --Return/Space--> runs button i, stays on the bar
//
// Every event the state does not accept is ignored and its key falls through to
// the phone as it did before. Pure, so the tests pin each edge, including the
// keys that must not move the focus.

import AppKit

struct BarFocus: Equatable {
    enum State: Equatable {
        /// The picture has the keyboard: keys and Tab go to the phone.
        case picture
        /// The button at this index draws the focus ring; the bar's keys are
        /// consumed and never reach the phone.
        case bar(Int)
    }

    enum Event: Equatable {
        case controlTab
        case tab
        case shiftTab
        case left
        case right
        case activate
        case space
        case escape
    }

    enum Action: Equatable {
        /// The bar button at this index takes the focus ring.
        case focus(Int)
        /// The picture has the keyboard again: its keys reach the phone.
        case picture
        /// Run this bar button.
        case press(Int)
    }

    private(set) var state: State = .picture

    var index: Int? {
        if case .bar(let index) = state { return index }
        return nil
    }

    var isOnBar: Bool { index != nil }

    /// The bar's key for an event, or nil when the key is the phone's. A bare
    /// key with no modifier is not a shortcut (docs/UX.md): only ⌃Tab enters
    /// the bar, and its own keys act once it has the focus.
    static func event(keyCode: UInt16, control: Bool, shift: Bool) -> Event? {
        switch keyCode {
        case keyCodeTab: return control ? .controlTab : (shift ? .shiftTab : .tab)
        case keyCodeLeft: return .left
        case keyCodeRight: return .right
        case keyCodeReturn, keyCodeKeypadEnter: return .activate
        case keyCodeSpace: return .space
        case keyCodeEscape: return .escape
        default: return nil
        }
    }

    static let keyCodeTab: UInt16 = 48
    static let keyCodeLeft: UInt16 = 123
    static let keyCodeRight: UInt16 = 124
    static let keyCodeReturn: UInt16 = 36
    static let keyCodeKeypadEnter: UInt16 = 76
    static let keyCodeSpace: UInt16 = 49
    static let keyCodeEscape: UInt16 = 53

    /// One transition. `focusable` is the bar's enabled buttons in reading
    /// order: a disabled button is never focused (a frozen bar has none).
    mutating func handle(_ event: Event, focusable: [Int]) -> Action? {
        switch (state, event) {        case (.picture, .controlTab):
            guard let first = focusable.first else { return nil }
            state = .bar(first)
            return .focus(first)
        // The picture's own keys are the phone's: Tab still types on Android,
        // and Return, Esc and the arrows keep their phone meanings.
        case (.picture, .tab), (.picture, .shiftTab), (.picture, .left),
             (.picture, .right), (.picture, .activate), (.picture, .space),
             (.picture, .escape):
            return nil
        // ⌃Tab is the way in and the way out; Esc is the way out.
        case (.bar, .controlTab), (.bar, .escape):
            state = .picture
            return .picture
        case (.bar(let index), .tab), (.bar(let index), .right):
            guard let next = Self.step(from: index, focusable: focusable, forward: true) else {
                return nil
            }
            state = .bar(next)
            return .focus(next)
        case (.bar(let index), .shiftTab), (.bar(let index), .left):
            guard let next = Self.step(from: index, focusable: focusable, forward: false) else {
                return nil
            }
            state = .bar(next)
            return .focus(next)
        case (.bar(let index), .activate), (.bar(let index), .space):
            return .press(index)
        }
    }

    /// What one key does to the window: the action to apply, and whether the
    /// bar took the key (so it must not reach the phone). A key is the bar's
    /// when the bar had the focus or this very key gave it the focus.
    struct Routing: Equatable {
        var action: Action?
        var consumed: Bool
    }

    mutating func route(_ event: Event, focusable: [Int]) -> Routing {
        let hadFocus = isOnBar
        let action = handle(event, focusable: focusable)
        return Routing(action: action, consumed: hadFocus || isOnBar)
    }

    /// The next focusable button, wrapping at both ends: a bar of four buttons
    /// is a ring, and ← from Back reaches Turn Off Phone Screen.
    static func step(from index: Int, focusable: [Int], forward: Bool) -> Int? {
        guard !focusable.isEmpty else { return nil }
        switch (forward, focusable.firstIndex(of: index)) {
        case (true, let position?):
            return focusable[(position + 1) % focusable.count]
        case (false, let position?):
            return focusable[(position - 1 + focusable.count) % focusable.count]
        case (_, nil):
            // The button vanished (the bar was rebuilt): start at that end.
            return forward ? focusable.first : focusable.last
        }
    }
}
