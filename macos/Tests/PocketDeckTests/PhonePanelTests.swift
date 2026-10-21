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
}
