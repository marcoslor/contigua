// View ▸ Immersive (docs/design/mac-redesign.md §3.8): the reveal-delay
// submenu and the "always visible" chrome rule. Pure, so the menu's items,
// its checks and what a pick does are unit tested; the controller and the
// chrome read the rule.
//
// The submenu is one setting for every window (RevealDelay, the same store
// Settings ▸ General writes) plus the style switch that "Immersive" always
// was: picking anything takes the focused window to immersive, and the choice
// applies to every open immersive window at once.

import Foundation

enum ImmersiveMenuItem: Hashable {
    case delay(RevealDelay)
    case separator
    case alwaysVisible

    var title: String {
        switch self {
        case .delay(let delay): return delay.label
        case .separator: return ""
        case .alwaysVisible: return RevealDelay.alwaysVisible.label
        }
    }
}

enum ImmersiveMenuModel {
    /// Top to bottom: the three reveal delays, a separator, Always Visible.
    static let items: [ImmersiveMenuItem] = [
        .delay(.instantly),
        .delay(.short),
        .delay(.long),
        .separator,
        .alwaysVisible,
    ]

    /// The checkmark: the current reveal choice, on the item that stores it.
    static func isChecked(_ item: ImmersiveMenuItem, reveal: RevealDelay) -> Bool {
        switch item {
        case .delay(let delay): return delay == reveal
        case .alwaysVisible: return reveal.keepsChromeVisible
        case .separator: return false
        }
    }

    /// What a pick does: store the choice globally and switch the focused
    /// window to immersive. A separator picks nothing.
    static func pick(_ item: ImmersiveMenuItem) -> (reveal: RevealDelay, style: WindowStyle)? {
        switch item {
        case .delay(let delay): return (delay, .immersive)
        case .alwaysVisible: return (.alwaysVisible, .immersive)
        case .separator: return nil
        }
    }

    /// The parent item is checked while the focused window is immersive.
    static func parentChecked(style: WindowStyle) -> Bool {
        style == .immersive
    }
}

/// The immersive chrome's rule. Normally the traffic lights and the bar's
/// capsules hide at rest and the dwell pill brings them in; with Always
/// Visible there is no hot zone and no hiding — they stay over the stream,
/// which still fills the window.
enum ImmersiveChrome {
    static func alwaysVisible(_ delay: RevealDelay) -> Bool {
        delay.keepsChromeVisible
    }

    /// The dwell's hot zone exists only while the chrome can hide.
    static func usesDwell(alwaysVisible: Bool) -> Bool { !alwaysVisible }

    /// The pill (the lights and the capsules) is up: always, or because the
    /// dwell brought it in.
    static func showsPill(alwaysVisible: Bool, dwellShown: Bool) -> Bool {
        alwaysVisible || dwellShown
    }
}
