// View ▸ Hide Controls (docs/design/mac-redesign.md §3.8): the full-screen
// bar's reveal choice. Pure, so the menu's items, its checks and what a pick
// does are unit tested; the controller and the chrome read the rule.
//
// The submenu is one setting for every window (RevealDelay, the same store
// Settings ▸ General writes). A pick stores the choice; it never changes a
// window's style.

import Foundation

enum FullScreenMenuItem: Hashable {
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

enum FullScreenMenuModel {
    /// Top to bottom: the three reveal delays, a separator, Always Visible.
    static let items: [FullScreenMenuItem] = [
        .delay(.instantly),
        .delay(.short),
        .delay(.long),
        .separator,
        .alwaysVisible,
    ]

    /// The checkmark: the current reveal choice, on the item that stores it.
    static func isChecked(_ item: FullScreenMenuItem, reveal: RevealDelay) -> Bool {
        switch item {
        case .delay(let delay): return delay == reveal
        case .alwaysVisible: return reveal.keepsChromeVisible
        case .separator: return false
        }
    }

    /// What a pick does: store the choice globally. A separator picks nothing.
    static func pick(_ item: FullScreenMenuItem) -> RevealDelay? {
        switch item {
        case .delay(let delay): return delay
        case .alwaysVisible: return .alwaysVisible
        case .separator: return nil
        }
    }
}
