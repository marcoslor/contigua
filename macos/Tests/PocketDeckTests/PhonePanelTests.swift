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

    /// The review's first panel shot: the Now Playing picker's icon sat left of
    /// the other rows' icon column and the row drew no indicator that it is a
    /// choice; the volume row's speaker was not in the column at all. Every
    /// row's symbol now sits in the one 18 pt column and the picker ends in a
    /// popup indicator at the row's trailing edge.
    func testEveryRowSharesTheOneIconColumn() throws {
        var state = panelState(sessions: [row("a", "Spotify"), row("b", "Music", playing: true)])
        state.battery = 87
        let view = host(state)
        let pixels = try XCTUnwrap(render(state).flatMap(Pixels.init))
        XCTAssertEqual(pixels.height, Int(view.fittingSize.height.rounded()),
                       "the render and the host lay out the same panel")
        let items = PhonePanelItem.focusOrder(for: state)
        let controls = laidOut(in: view)
        XCTAssertEqual(controls.count, items.count, "one laid-out control per panel item")

        let column = PhonePanelMetrics.inset + PhonePanelMetrics.rowInset
        // The rows with a leading icon; the footer's two shortcuts sit on the
        // text inset, not on the icon column.
        let iconRows: [PhonePanelItem] = [.volume, .dnd, .ring, .sessions,
                                          .phoneScreen, .findApps, .continueOnMac, .installApk]
        var centres: [(PhonePanelItem, CGFloat)] = []
        for item in iconRows {
            let control = controls[try XCTUnwrap(items.firstIndex(of: item))]
            let centre = frame(control, in: view).midY
            let icon = try XCTUnwrap(pixels.ink(columns: 8..<45, rows: pixels.rows(center: centre, half: 9)),
                                     "\(item.rawValue) draws no leading icon")
            XCTAssertGreaterThanOrEqual(icon.minX, Int(column) - 1,
                                        "\(item.rawValue)'s icon starts left of the icon column")
            XCTAssertLessThanOrEqual(icon.maxX, Int(column + PhonePanelMetrics.iconColumn) + 1,
                                     "\(item.rawValue)'s icon runs past the icon column")
            centres.append((item, CGFloat(icon.minX + icon.maxX) / 2))
        }
        let mean = centres.map(\.1).reduce(0, +) / CGFloat(centres.count)
        for (item, centre) in centres {
            XCTAssertEqual(centre, mean, accuracy: 1,
                           "\(item.rawValue)'s icon is off the column the others share")
        }

        // The picker row is the full row and ends in the popup indicator.
        let picker = try XCTUnwrap(items.firstIndex(of: .sessions))
        let row = frame(controls[picker], in: view)
        XCTAssertTrue(pixels.hasInk(columns: 240..<290, rows: pixels.rows(center: row.midY, half: 9)),
                      "the Now Playing row draws no trailing indicator")
        XCTAssertGreaterThan(row.width, 200, "the Now Playing row is only as wide as its text")
    }

    /// The review's rhythm complaints: an empty agent row stood between the
    /// header and PHONE, the reason line kept its height when there was nothing
    /// to explain (a gap under the slider) and the two section gaps differed.
    /// The panel is now one grid: 28 pt rows, a 10 pt gap on both sides of a
    /// 16 pt label, and only content that exists takes height.
    func testTheRowsAndSectionsShareOneVerticalGrid() throws {
        let state = panelState(sessions: [row("a", "Spotify"), row("b", "Music", playing: true)])
        let view = host(state)
        let items = PhonePanelItem.focusOrder(for: state)
        let controls = laidOut(in: view)
        let centres = Dictionary(uniqueKeysWithValues: zip(items, controls.map { frame($0, in: view).midY }))

        // One 28 pt row after another inside a section, whatever the row is
        // (slider, switch, button, popup).
        for (above, below) in [(PhonePanelItem.volume, PhonePanelItem.dnd),
                               (.dnd, .ring), (.ring, .sessions),
                               (.phoneScreen, .findApps), (.findApps, .continueOnMac),
                               (.continueOnMac, .installApk)] {
            XCTAssertEqual(abs(centres[above]! - centres[below]!), PhonePanelMetrics.rowHeight, accuracy: 0.5,
                           "\(above.rawValue) → \(below.rawValue) is not one row")
        }
        // One section gap (10) and one label (16) between PHONE's last row and
        // WINDOWS' first row: the same gap the header leaves above PHONE.
        XCTAssertEqual(abs(centres[.sessions]! - centres[.phoneScreen]!),
                       PhonePanelMetrics.rowHeight + PhonePanelMetrics.sectionHeight
                           + PhonePanelMetrics.sectionGap,
                       accuracy: 0.5,
                       "the WINDOWS section is spaced like the PHONE one")

        let expected = PhonePanelMetrics.inset * 2 + PhonePanelMetrics.headerHeight
            + (PhonePanelMetrics.sectionGap + PhonePanelMetrics.sectionHeight) * 2
            + PhonePanelMetrics.rowHeight * 8
            + PhonePanelMetrics.sectionGap + PhonePanelMetrics.rowHeight
        XCTAssertEqual(view.fittingSize.height, expected, accuracy: 0.5,
                       "online the panel is exactly its header, rows, labels and gaps")
        var away = state
        away.connection = .offline
        XCTAssertEqual(host(away).fittingSize.height, expected + PhonePanelMetrics.reasonHeight, accuracy: 0.5,
                       "offline the panel adds only the one reason line")
    }

    /// The review's offline shot: Ring Phone dimmed, but Do Not Disturb's label
    /// and the slider stayed bright, and the header kept the last battery level.
    /// Offline every phone row is off and drawn like Ring Phone, and the
    /// battery is gone rather than stale.
    func testOfflineDimsEveryPhoneRowAndHidesTheBattery() throws {
        var state = panelState(online: false, sessions: [row("a", "Spotify"), row("b", "Music")])
        state.battery = 87
        XCTAssertNil(state.shownBattery, "offline the header draws no battery")
        XCTAssertNil(state.volumeFraction)
        for item in [PhonePanelItem.volume, .dnd, .ring, .phoneScreen, .continueOnMac, .installApk] {
            XCTAssertFalse(item.isEnabled(in: state), "\(item.rawValue) must be off while the phone is away")
        }
        XCTAssertTrue(PhonePanelItem.findApps.isEnabled(in: state))

        let view = host(state)
        let pixels = try XCTUnwrap(render(state).flatMap(Pixels.init))
        // A disabled row leaves the key loop, so the offline controls are found
        // by their shapes (the switch) and the grid, not by index.
        let dnd = try XCTUnwrap(laidOut(in: view).first { $0 is NSSwitch }, "no DND switch")
        let dndCentre = frame(dnd, in: view).midY
        // The same panel online: each row's own ink, then and now, gives the
        // dimming factor without depending on the platform's control colours.
        let onlineState = panelState(sessions: [row("a", "Spotify"), row("b", "Music")])
        let onlineView = host(onlineState)
        let online = try XCTUnwrap(render(onlineState).flatMap(Pixels.init))
        let onlineDnd = try XCTUnwrap(laidOut(in: onlineView).first { $0 is NSSwitch }, "no online DND switch")
        let onlineCentre = frame(onlineDnd, in: onlineView).midY
        func dimRatio(_ columns: Range<Int>, offlineCentre: CGFloat, onlineCentre: CGFloat) -> Double {
            let away = pixels.meanAlpha(columns: columns, rows: pixels.rows(center: offlineCentre, half: 8))
            let now = online.meanAlpha(columns: columns, rows: online.rows(center: onlineCentre, half: 8))
            return now == 0 ? 0 : away / now
        }
        // Offline the volume row is above the one reason line, which is above
        // DND; online there is no line, so each row is one row higher.
        let volumeAway = dndCentre - PhonePanelMetrics.rowHeight - PhonePanelMetrics.reasonHeight
        let volumeNow = onlineCentre - PhonePanelMetrics.rowHeight
        let labels = 46..<150
        let icons = 20..<44
        let rows: [(String, Range<Int>, CGFloat, CGFloat)] = [
            ("Do Not Disturb", labels, dndCentre, onlineCentre),
            ("Ring Phone", labels, dndCentre + PhonePanelMetrics.rowHeight,
             onlineCentre + PhonePanelMetrics.rowHeight),
            ("volume icons", icons, volumeAway, volumeNow),
            ("slider", labels, volumeAway, volumeNow),
        ]
        for (name, columns, away, now) in rows {
            XCTAssertLessThanOrEqual(dimRatio(columns, offlineCentre: away, onlineCentre: now), 0.75,
                                     "the \(name) is not dimmed while the phone is away")
        }
        // A disabled row's label dims the way Ring Phone's does.
        XCTAssertEqual(dimRatio(labels, offlineCentre: dndCentre, onlineCentre: onlineCentre), 0.6,
                       accuracy: 0.15, "the DND label does not dim like the Ring Phone label")

        // Nothing stands in the header's battery corner.
        let header = PhonePanelMetrics.inset + PhonePanelMetrics.headerHeight / 2
        XCTAssertFalse(pixels.hasInk(columns: 240..<288, rows: pixels.rows(center: header, half: 20)),
                       "the offline header still draws a battery level")
    }
}
