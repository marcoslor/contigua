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
    private var window: NSWindow?
    private var hosting: NSHostingView<PhonePanelView>?

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
        window?.orderOut(nil)
        window = nil
        hosting = nil
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
    /// menu-style extra turns a Slider into a stepper submenu and its hover
    /// flickers), with the volume slider inline and no track row — and since
    /// 2026-10-22 an AppKit status item and panel, so the icon toggles.
    func testTheMenuBarIsAWindowPanelWithAnInlineVolumeSlider() throws {
        let app = try source("App.swift")
        XCTAssertFalse(app.contains(".menuBarExtraStyle(.menu)"),
                       "a menu-style extra turns the volume slider into a stepper submenu")
        XCTAssertFalse(app.contains("MenuBarExtra("),
                       "the status item is AppKit's: SwiftUI's window extra closed on mouse-down and reopened on mouse-up")
        XCTAssertTrue(app.contains("MenuBarController("),
                      "the app starts the menu bar item's AppKit controller")

        let panel = try source("MenuBarPanel.swift")
        XCTAssertTrue(panel.contains("NSStatusItem"),
                      "the menu bar item is an NSStatusItem")
        XCTAssertTrue(panel.contains("MenuBarContent("),
                      "the panel hosts the shared phone controls")
        XCTAssertTrue(panel.contains("MenuBarPanelMachine"),
                      "the panel's modes are one state machine")

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
                       dnd: PhoneDndMode? = .off, volume: Int? = 8,
                       ringer: PhoneRingerMode? = .normal,
                       phoneWindow: Bool = true) -> PhoneControlsState {
        var state = PhoneControlsState()
        state.phoneName = "Pixel 9"
        state.connection = online ? .online : .offline
        state.volume = volume
        state.volumeMax = 15
        state.media = MediaState()
        state.sessions = sessions
        state.dnd = dnd
        state.ringer = ringer
        state.phoneWindow = phoneWindow
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
                       [.dnd, .ringer, .ring, .screen, .volume, .sessions, .live,
                        .phoneScreen, .findApps, .continueOnMac, .installApk, .settings, .quit])

        // The agent row's Disconnect button is the first focusable control.
        state.agentCount = 1
        XCTAssertEqual(PhonePanelItem.focusOrder(for: state).first, .disconnectAgent)

        // Without live rows and with one session the picker is not there.
        state = panelState(sessions: [row("a", "Spotify")])
        XCTAssertEqual(PhonePanelItem.focusOrder(for: state),
                       [.dnd, .ringer, .ring, .screen, .volume,
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

    /// Every control names its own missing capability; P3 does not fold them
    /// into one line any more. The volume still has the line next to its slider.
    func testTheReasonNamesTheMissingPhoneCapability() {
        XCTAssertEqual(PhonePanelItem.volume.reason(in: panelState(volume: nil)),
                       "Your phone hasn't sent a volume.")
        XCTAssertEqual(PhonePanelItem.dnd.reason(in: panelState(dnd: nil)),
                       "This phone doesn't report Do Not Disturb.")
        XCTAssertNil(PhonePanelItem.volume.reason(in: panelState()))
        XCTAssertNil(PhonePanelItem.dnd.reason(in: panelState()))
        XCTAssertEqual(PhonePanelItem.ringer.reason(in: panelState(ringer: nil)),
                       "This phone doesn't report a ringer.")
        XCTAssertEqual(PhonePanelItem.screen.reason(in: panelState(phoneWindow: false)),
                       "Open Phone Mirror first.")
        // A volume without a maximum is not a fraction.
        var noMax = panelState()
        noMax.volumeMax = nil
        XCTAssertNil(noMax.volumeFraction)
        XCTAssertEqual(PhonePanelItem.volume.reason(in: noMax),
                       "Your phone hasn't sent a volume.")
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

    // MARK: - The panel's geometry (the review's shots, 2026-10-21)

    /// The panel in a real window at its intended width, laid out: the same
    /// hosting the app does, so the controls' frames are the ones a pointer
    /// hits.
    @discardableResult
    private func host(_ state: PhoneControlsState) -> NSHostingView<PhonePanelView> {
        window?.orderOut(nil)
        let view = NSHostingView(rootView: PhonePanelView(state: state, actions: PhoneControlsActions()))
        view.frame = NSRect(x: 0, y: 0, width: PhonePanelView.width, height: 640)
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
        self.window = window
        hosting = view
        return view
    }

    private func frame(_ control: NSView, in view: NSView) -> CGRect {
        control.convert(control.bounds, to: view)
    }

    /// Every focusable control SwiftUI laid out, top to bottom: its key-view
    /// proxies, the DND switch and the Now Playing popup.
    private func laidOut(in view: NSView) -> [NSView] {
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        return descendants(view)
            .filter {
                let name = String(describing: type(of: $0))
                return name.contains("KeyViewProxy") || $0 is NSSwitch || name.contains("PopupButton")
            }
            .sorted { a, b in
                let fa = frame(a, in: view), fb = frame(b, in: view)
                return fa.minY == fb.minY ? fa.minX < fb.minX : fa.minY < fb.minY
            }
    }

    /// The panel offscreen, at its own width, one point per pixel.
    private func render(_ state: PhoneControlsState) -> CGImage? {
        let renderer = ImageRenderer(content: PhonePanelView(state: state, actions: PhoneControlsActions()))
        renderer.proposedSize = ProposedViewSize(width: PhonePanelView.width, height: nil)
        renderer.scale = 1
        return renderer.cgImage
    }

    /// The pixels the panel drew: rows top-down as the renderer emits them.
    private struct Pixels {
        let width: Int
        let height: Int
        private let data: [UInt8]

        init?(_ image: CGImage) {
            let width = image.width, height = image.height
            var data = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(data: &data, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            self.width = width
            self.height = height
            self.data = data
        }

        /// The image rows covering `center ± half`. The hosting view is flipped
        /// (y grows down from the top), which is also how the renderer's rows
        /// are ordered.
        func rows(center: CGFloat, half: CGFloat) -> Range<Int> {
            let top = Int((center - half).rounded())
            let bottom = Int((center + half).rounded())
            return max(0, top)..<max(0, min(height, bottom))
        }

        func alpha(_ x: Int, _ y: Int) -> Int { Int(data[(y * width + x) * 4 + 3]) }

        /// What was drawn in a band, in the image's own columns: the first and
        /// last column with ink, or nil for a blank band.
        func ink(columns: Range<Int>, rows: Range<Int>) -> (minX: Int, maxX: Int)? {
            var minX: Int?, maxX: Int?
            for y in rows {
                for x in columns where alpha(x, y) > 8 {
                    minX = min(minX ?? x, x)
                    maxX = max(maxX ?? x, x)
                }
            }
            guard let minX, let maxX else { return nil }
            return (minX, maxX)
        }

        func hasInk(columns: Range<Int>, rows: Range<Int>) -> Bool {
            ink(columns: columns, rows: rows) != nil
        }

        /// The band's mean ink. The panel's own background is transparent, so
        /// dimming a row scales its pixels' alpha; the mean is steady where a
        /// peak depends on which control happens to be opaque.
        func meanAlpha(columns: Range<Int>, rows: Range<Int>) -> Double {
            var total = 0, count = 0
            for y in rows {
                for x in columns { total += alpha(x, y); count += 1 }
            }
            return count == 0 ? 0 : Double(total) / Double(count)
        }
    }

    /// The picker and the volume keep the shared text column: the volume is a
    /// 14 pt slider between two speakers, the picker a full-width menu row.
    func testThePickerAndTheVolumeKeepTheirColumns() throws {
        var state = panelState(sessions: [row("a", "Spotify"), row("b", "Music", playing: true)])
        state.battery = 87
        let view = host(state)
        let items = PhonePanelItem.focusOrder(for: state)
        let controls = laidOut(in: view)
        XCTAssertEqual(controls.count, items.count, "one laid-out control per enabled item")

        let slider = try XCTUnwrap(controls.first { control in
            let rect = frame(control, in: view)
            return rect.height < 20 && rect.width > 150
        })
        let sliderRect = frame(slider, in: view)
        XCTAssertEqual(sliderRect.height, 14, accuracy: 0.5)
        XCTAssertGreaterThan(sliderRect.width, 150)

        let picker = controls[items.firstIndex(of: .sessions)!]
        let pickerRect = frame(picker, in: view)
        XCTAssertGreaterThan(pickerRect.width, 200, "the picker spans the row")
        XCTAssertEqual(pickerRect.height, PhonePanelMetrics.rowHeight, accuracy: 1)
    }

    /// P3's rhythm: two tile rows at the review's 134 pt size, the volume, then
    /// one WINDOWS row, then the menu bar panel's footer.
    func testThePanelIsP3sTileGridThenVolumeThenOneWindowsRow() throws {
        let state = panelState()
        let view = host(state)
        let items = PhonePanelItem.focusOrder(for: state)
        let controls = laidOut(in: view)
        XCTAssertEqual(controls.count, items.count)

        let dnd = frame(controls[items.firstIndex(of: .dnd)!], in: view)
        let ringer = frame(controls[items.firstIndex(of: .ringer)!], in: view)
        let ring = frame(controls[items.firstIndex(of: .ring)!], in: view)
        let screen = frame(controls[items.firstIndex(of: .screen)!], in: view)
        XCTAssertEqual(dnd.width, PhonePanelMetrics.tileWidth, accuracy: 1)
        XCTAssertEqual(ringer.minX - dnd.maxX, PhonePanelMetrics.tileGap, accuracy: 1)
        XCTAssertEqual(dnd.minY, ringer.minY, accuracy: 1)
        XCTAssertEqual(ring.minY, screen.minY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(dnd.height, PhonePanelMetrics.tileMinHeight - 1)
        XCTAssertEqual(ring.minY - dnd.minY, dnd.height + PhonePanelMetrics.tileGap, accuracy: 1.5)

        let volume = frame(controls[items.firstIndex(of: .volume)!], in: view)
        XCTAssertGreaterThan(volume.minY, screen.minY)
        let phone = frame(controls[items.firstIndex(of: .phoneScreen)!], in: view)
        let find = frame(controls[items.firstIndex(of: .findApps)!], in: view)
        let cont = frame(controls[items.firstIndex(of: .continueOnMac)!], in: view)
        let install = frame(controls[items.firstIndex(of: .installApk)!], in: view)
        for rect in [phone, find, cont, install] {
            XCTAssertEqual(rect.minY, phone.minY, accuracy: 1, "WINDOWS is one row")
            XCTAssertGreaterThan(rect.width, 50)
        }
        XCTAssertGreaterThan(phone.minY, volume.minY)

        let settings = frame(controls[items.firstIndex(of: .settings)!], in: view)
        XCTAssertGreaterThan(settings.minY, phone.minY)
        XCTAssertTrue(items.contains(.quit))
    }

    /// Away: every phone control is off and the panel says why; the header
    /// drops its stale battery. Only the controls that need no phone stay on.
    func testOfflineDimsThePhoneControlsAndHidesTheBattery() throws {
        var state = panelState(online: false, phoneWindow: false)
        state.battery = 87
        let view = host(state)
        let items = PhonePanelItem.focusOrder(for: state)
        let enabled = items.filter { $0.isEnabled(in: state) }
        XCTAssertEqual(laidOut(in: view).count, enabled.count,
                       "the key loop holds exactly the enabled controls")
        XCTAssertEqual(enabled, [.findApps, .settings, .quit])
        XCTAssertNil(state.shownBattery, "offline the header does not draw a stale battery")

        // The reasons sit on the controls they disable (a tile's subtitle, the
        // volume row), so the offline panel is the online panel's height.
        let away = try XCTUnwrap(render(state).flatMap(Pixels.init))
        let now = try XCTUnwrap(render(panelState()).flatMap(Pixels.init))
        XCTAssertEqual(away.height, now.height)
    }
}
