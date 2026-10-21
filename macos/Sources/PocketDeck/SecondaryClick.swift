// Settings ▸ Input "Secondary click (two-finger click)": what a right click
// (or a trackpad two-finger click) on the stream does. Long press is the
// default: the pointer goes down at the click, stays down for Android's
// long-press timeout, and comes up — the app's context menu opens, as a
// right-click does on the Mac. Back and Nothing are for people who use the
// gesture another way. Stored in the profile's defaults, read live.

import AppKit

enum SecondaryClick: String, CaseIterable, Identifiable {
    case longPress
    case back
    case nothing

    static let key = "input.secondaryClick"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .longPress: return "Long press"
        case .back: return "Back"
        case .nothing: return "Nothing"
        }
    }

    var explanation: String {
        switch self {
        case .longPress:
            return "A two-finger click presses and holds at the pointer, so the app's context menu opens as a right-click does. A drag while it is held moves the touch."
        case .back:
            return "A two-finger click goes Back, like the mouse's side Back button."
        case .nothing:
            return "A two-finger click does nothing. Clicks and scrolling are unaffected."
        }
    }

    /// Unset or unreadable values are the default, Long press.
    static func stored(in defaults: UserDefaults) -> SecondaryClick {
        guard let raw = defaults.string(forKey: key), let value = SecondaryClick(rawValue: raw) else {
            return .longPress
        }
        return value
    }
}
