// The rules behind the app's menus (docs/design/mac-redesign.md §3.8). Pure, so
// the checks, the enablement and the titles are unit tested here; the SwiftUI
// commands (MenuBar.swift) build every item and read these decisions. Nothing
// in the app inserts an AppKit item into a SwiftUI menu: SwiftUI rebuilds those
// menus, and an inserted item is dropped when it does.

import Foundation

enum MenuModel {
    /// View ▸ the style pair, top to bottom.
    static let styles: [WindowStyle] = [.framed, .immersive]

    /// Exactly one of the pair is checked: the key stream window's style.
    static func styleChecked(_ item: WindowStyle, key: WindowStyle) -> Bool { item == key }

    /// Hide Controls is the reveal choice for an immersive window only, so a
    /// choice is never also a submenu's parent.
    static func hideControlsEnabled(style: WindowStyle) -> Bool { style == .immersive }

    /// Hide Controls' items, top to bottom (the three delays, a separator,
    /// Always Visible).
    static let hideControls: [ImmersiveMenuItem] = ImmersiveMenuModel.items

    /// The Density item that clears the app's override. It names the Settings
    /// default, so the person knows what "Default" restores.
    static func densityDefaultTitle(settings: Double) -> String {
        "Default (\(DensityRules.percentLabel(settings)))"
    }

    /// The percentage items: every option except the one the Default item
    /// already names, so the same value never appears twice.
    static func densityOptions(settings: Double) -> [(label: String, value: Double)] {
        WindowDensity.options.filter { abs($0.value - settings) > 0.0005 }
    }

    /// View ▸ Icon Size's items: the Deck's four icon-size steps (DECK-6). The
    /// space before the sign keeps them distinct from Density's app percentages
    /// in the same menu, which name a different setting.
    static func iconSizeTitle(_ value: CGFloat) -> String {
        "\(Int((Double(value) * 100).rounded())) %"
    }
}
