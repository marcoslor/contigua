// The menu bar panel and the Deck popover (docs/design/mac-redesign.md §3.8,
// docs/DESIGN.md "Deck"): one shared phone-controls component, no volume
// submenu, no track row, no second forwarded-audio slider. The reported bugs
// (v104) were a Slider inside a menu-style MenuBarExtra, which AppKit turned
// into a "Phone volume" stepper submenu whose hover opened and closed, and a
// flat list with two volume controls. The view checks read the panel's own
// source and its pure item model; the panel is one fixed layout so the same
// frames drive the e2e's real clicks.

import AppKit
import SwiftUI
import XCTest
@testable import PocketDeck

@MainActor
final class PhonePanelTests: XCTestCase {
    private var profile: Profile!
    private var support: URL!
    private var controller: ConnectionController!

    override func setUp() async throws {
        let suffix = UUID().uuidString.lowercased().prefix(8)
        guard let profile = Profile(name: "panel-test-\(suffix)") else {
            XCTFail("bad test profile name")
            return
        }
        self.profile = profile
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        support = base.appendingPathComponent(profile.supportDirectoryName, isDirectory: true)
        controller = ConnectionController(options: LaunchOptions(), profile: profile)
    }

    override func tearDown() async throws {
        profile?.defaults.removePersistentDomain(forName: profile.defaultsSuiteName!)
        if let support { try? FileManager.default.removeItem(at: support) }
    }

    private var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PocketDeckTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // macos
            .appendingPathComponent("Sources/PocketDeck", isDirectory: true)
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
    }

    /// The repro of the v104 report: the menu bar must be a window panel (a
    /// menu-style MenuBarExtra turns a Slider into a stepper submenu and its
    /// hover flickers), with the volume slider inline and no track row.
    func testTheMenuBarIsAWindowPanelWithAnInlineVolumeSlider() throws {
        let app = try source("App.swift")
        XCTAssertTrue(app.contains(".menuBarExtraStyle(.window)"),
                      "the menu bar must be a window panel, not a menu")
        XCTAssertFalse(app.contains(".menuBarExtraStyle(.menu)"),
                       "a menu-style extra turns the volume slider into a stepper submenu")

        let menu = try source("MenuBar.swift")
        XCTAssertTrue(menu.contains("PhonePanelView("),
                      "the menu bar must host the shared phone controls")
        // The app's menu commands (AppCommands) legitimately build menus; only
        // the panel's own content must not.
        let panelContent = menu.components(separatedBy: "struct AppCommands").first ?? menu
        XCTAssertFalse(panelContent.contains("Menu {"),
                       "the panel must not build a submenu (the volume picker is a row, not a Menu)")
        XCTAssertFalse(menu.contains("MediaMenu.trackLine"),
                       "the track row is removed: the Mac's own Now Playing is enough")
        XCTAssertFalse(menu.contains("controller.mediaArt"),
                       "the artwork row is removed")
        XCTAssertFalse(menu.contains("Phone audio"),
                       "the forwarded-audio slider and Mute are removed")
        XCTAssertFalse(menu.contains("audioVolume"),
                       "there is one volume control in the panel: the phone's media volume")
    }

    /// The panel is shared: the Deck's status pill opens the same component in
    /// a popover and the toolbar keeps its Phone button.
    func testTheDeckStatusPillOpensTheSamePanel() throws {
        let deck = try source("DeckViews.swift")
        XCTAssertTrue(deck.contains("PhonePanelView("),
                      "the Deck popover must host the same phone controls")
        XCTAssertTrue(deck.contains(".popover("),
                      "the status pill opens the controls in a popover")
        XCTAssertTrue(deck.contains("Label(\"Phone\""),
                      "the toolbar keeps its Phone button")
    }

    /// No track text or artwork anywhere in the panel: the panel's source never
    /// reads the title, artist, album or the artwork.
    func testThePanelHasNoTrackText() throws {
        let panel = try source("PhonePanel.swift")
        for forbidden in ["trackLine", "mediaArt", "artist", "album", ".title"] {
            XCTAssertFalse(panel.contains(forbidden),
                           "the panel must not read the media \(forbidden)")
        }
    }

    // MARK: - The panel's model

    private func panelState(online: Bool = true, sessions: [MediaSessionRow] = [],
                       dnd: PhoneDndMode? = .off, volume: Int? = 8) -> PhoneControlsState {
        var state = PhoneControlsState()
        state.phoneName = "Pixel 9"
        state.connection = online ? .online : .offline
        var media = MediaState()
        media.volume = volume
        media.volumeMax = 15
        state.media = volume == nil ? nil : media
        state.sessions = sessions
        state.dnd = dnd
        return state
    }

    private func row(_ key: String, _ app: String, playing: Bool = false) -> MediaSessionRow {
        MediaSessionRow(key: key, pkg: "com.example.\(key)", app: app, playing: playing)
    }

    /// The rows in the order the view lays them out, because the e2e maps the
    /// hosting view's key views (top to bottom) to this list by index: the
    /// phone controls, the live notifications, then the window actions and the
    /// footer.
    func testTheRowsAreInTheOrderTheViewLaysThemOut() {
        var state = panelState(sessions: [row("a", "Spotify"), row("b", "Music")])
        state.live = [NotifyLiveItem(id: "n1", pkg: "com.example.clock", label: "Timer",
                                     chip: nil, progress: nil, chrono: nil, countDown: false,
                                     updated: Date())]
        XCTAssertEqual(PhonePanelItem.focusOrder(for: state),
                       [.volume, .dnd, .ring, .sessions, .live,
                        .phoneScreen, .findApps, .continueOnMac, .installApk, .settings, .quit])

        // The agent row's Disconnect button is the first focusable control.
        state.agentCount = 1
        XCTAssertEqual(PhonePanelItem.focusOrder(for: state).first, .disconnectAgent)

        // Without live rows and with one session the picker is not there.
        state = panelState(sessions: [row("a", "Spotify")])
        XCTAssertEqual(PhonePanelItem.focusOrder(for: state),
                       [.volume, .dnd, .ring,
                        .phoneScreen, .findApps, .continueOnMac, .installApk, .settings, .quit])
    }

    /// Ring becomes Stop Ringing while the phone rings, and back.
    func testRingFlipsToStopRinging() {
        var state = panelState()
        XCTAssertEqual(state.ringTitle, "Ring Phone")
        state.ringing = true
        XCTAssertEqual(state.ringTitle, "Stop Ringing")
        XCTAssertEqual(PhonePanelItem.ring.label, "Ring Phone")
    }

    /// Offline: one honest line, and the phone controls are off (no volume, no
    /// DND) even when the last state still had both.
    func testOfflineExplainsWhyTheControlsAreOff() {
        let state = panelState(online: false, sessions: [row("a", "Spotify")])
        XCTAssertEqual(state.reason, "Connect your phone to use these.")
        XCTAssertNil(state.volumeFraction)
        XCTAssertEqual(state.connection.text, "Offline")
    }

    /// Online but the phone sent no volume, or no DND: say which, in that order.
    func testTheReasonNamesTheMissingPhoneCapability() {
        XCTAssertEqual(panelState(volume: nil).reason, "Your phone hasn't sent a volume.")
        XCTAssertEqual(panelState(dnd: nil).reason, "This phone doesn't report Do Not Disturb.")
        XCTAssertNil(panelState().reason)
        // A volume without a maximum is not a fraction.
        var noMax = panelState()
        noMax.media?.volumeMax = nil
        XCTAssertNil(noMax.volumeFraction)
        XCTAssertEqual(noMax.reason, "Your phone hasn't sent a volume.")
    }

    /// The picker is a row only with two or more sessions, and its title names
    /// the app Now Playing follows.
    func testThePickerNeedsTwoSessionsAndNamesTheChosenApp() {
        XCTAssertFalse(panelState(sessions: [row("a", "Spotify")]).showsPicker)
        var state = panelState(sessions: [row("a", "Spotify"), row("b", "Music", playing: true)])
        XCTAssertTrue(state.showsPicker)
        XCTAssertEqual(state.pickerTitle, "Now Playing follows: Spotify")
        state.media?.key = "b"
        XCTAssertEqual(state.pickerTitle, "Now Playing follows: Music")
    }

    /// One item model for both hosts: the menu bar panel and the Deck popover
    /// build the same view from the same state, and every row has its own id.
    func testBothHostsBuildTheSameItems() throws {
        let ids = PhonePanelItem.allCases.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "row ids must be unique")
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("panel.") })
        for name in ["MenuBar.swift", "DeckViews.swift"] {
            let text = try source(name)
            XCTAssertTrue(text.contains("PhonePanelView("), "\(name) hosts the shared panel")
            XCTAssertTrue(text.contains("PhoneControlsState(controller: controller)"),
                          "\(name) builds the panel state the same way")
        }
    }
}
