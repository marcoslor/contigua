// What the View menu shows about the key stream window. SwiftUI's menu
// commands cannot see AppKit windows, so the window controllers publish here.

import CoreGraphics
import Observation

@Observable
final class StreamMenuState {
    static let shared = StreamMenuState()

    /// A stream window is key: the per-window items are enabled.
    var hasStream = false
    /// The key stream window's style (the Window Style radio items follow it).
    var style: WindowStyle = .standard
    var showTouches = false
    /// The key stream window is in Live Text mode (the View menu's check).
    var liveText = false
    /// The key stream window's phone-side actions are frozen: Live Text or a
    /// cover over the mirror. One rule for the buttons, shortcuts and menu.
    var frozen = false
    /// The key window's link is down: the phone-side menu items are disabled
    /// with their reason (the same rule as the bar's controls).
    var phoneOffline = false
    /// The key window is the phone window (the whole Navigate menu acts on it).
    var phoneWindow = false
    /// The key phone window's mirrored panel is held off ("Turn Off Phone
    /// Screen"): the Navigate menu item's check follows the phone's report.
    var panelOff = false
    /// Settings → General "Reveal controls after", for the Immersive submenu's
    /// checkmark (one value for every window).
    var revealDelay: RevealDelay = .short

    /// The app the key stream window shows; nil for the phone window and for
    /// a link window before the phone names its package. Without one the
    /// Density submenu is disabled.
    var densityPackage: String?
    /// The key window's app override; nil means it follows the Settings
    /// default (the submenu checks "Default").
    var densityOverride: Double?
    /// Settings → General "Default window density", for the Default item's
    /// label and for deciding what "Default" restores.
    var settingsDensity = 1.0
    /// The Deck's stored icon size (DECK-6), for View ▸ Icon Size's checkmark.
    /// Read from the profile when a menu opens, so the mark follows ⌘+ at once.
    var deckZoom: CGFloat = 1

    /// The app uses `shared`; a test builds its own to drive the menu rules.
    init() {}
}
