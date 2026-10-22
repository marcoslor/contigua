// Panel P3 (docs/design/mac-redesign.md §3.8, the 2026-10-22 deck-panel
// review): a 2×2 tile grid, a menu on the Ringer tile, the volume slider with
// its value, one compact WINDOWS row, and a footer only in the menu bar
// panel. The pure model is what the e2e's paneldump reads and what the view
// draws; the hosted view checks pin the frames a pointer hits.

import AppKit
import SwiftUI
import XCTest
@testable import PocketDeck

@MainActor
final class PhonePanelP3Tests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
    }

    private func state(online: Bool = true, dnd: PhoneDndMode? = .off,
                       ringer: PhoneRingerMode? = .normal, volume: Int? = 8,
                       sessions: [MediaSessionRow] = [], phoneWindow: Bool = true) -> PhoneControlsState {
        var state = PhoneControlsState()
        state.phoneName = "Pixel 9"
        state.connection = online ? .online : .offline
        state.dnd = dnd
        state.ringer = ringer
        state.volume = volume
        state.volumeMax = 15
        state.sessions = sessions
        state.phoneWindow = phoneWindow
        return state
    }

    // MARK: - The model

    /// P3's order: the four tiles, the volume, the picker when there is one,
    /// the window buttons, then the menu bar panel's footer. The Deck popover
    /// asks for no footer, so its focus order ends at Install APK.
    func testTheFocusOrderIsP3AndTheFooterIsOptional() {
        let plain = state()
        XCTAssertEqual(PhonePanelItem.focusOrder(for: plain),
                       [.dnd, .ringer, .ring, .screen, .volume,
                        .phoneScreen, .findApps, .continueOnMac, .installApk,
                        .settings, .quit])
        XCTAssertEqual(PhonePanelItem.focusOrder(for: plain, showsFooter: false),
                       [.dnd, .ringer, .ring, .screen, .volume,
                        .phoneScreen, .findApps, .continueOnMac, .installApk])

        let two = state(sessions: [MediaSessionRow(key: "a", pkg: "p.a", app: "Spotify", playing: false),
                                   MediaSessionRow(key: "b", pkg: "p.b", app: "Music", playing: true)])
        XCTAssertEqual(PhonePanelItem.focusOrder(for: two, showsFooter: false),
                       [.dnd, .ringer, .ring, .screen, .volume, .sessions,
                        .phoneScreen, .findApps, .continueOnMac, .installApk])
    }

    /// The Ringer tile: the subtitle names the phone's mode, the menu lists
    /// exactly Ring/Vibrate/Silent with the current one checked, and the tile
    /// is disabled with a reason on an old phone or while DND is on.
    func testTheRingerTileNamesItsModeAndExplainsWhyItIsOff() {
        let ring = state(ringer: .normal)
        XCTAssertTrue(PhonePanelItem.ringer.isEnabled(in: ring))
        XCTAssertEqual(ring.ringerTitle, "Ring")
        XCTAssertEqual(ring.ringerMenu.map(\.name), ["Ring", "Vibrate", "Silent"])
        XCTAssertEqual(ring.ringerMenu.filter(\.checked).map(\.mode), [.normal])

        let vibrate = state(ringer: .vibrate)
        XCTAssertEqual(vibrate.ringerTitle, "Vibrate")
        XCTAssertEqual(vibrate.ringerMenu.filter(\.checked).map(\.mode), [.vibrate])

        let old = state(ringer: nil)
        XCTAssertFalse(PhonePanelItem.ringer.isEnabled(in: old))
        XCTAssertEqual(PhonePanelItem.ringer.reason(in: old),
                       "This phone doesn't report a ringer.")

        let dnd = state(dnd: .priority)
        XCTAssertFalse(PhonePanelItem.ringer.isEnabled(in: dnd))
        XCTAssertEqual(PhonePanelItem.ringer.reason(in: dnd),
                       "Turn off Do Not Disturb to change the ringer.")

        let away = state(online: false)
        XCTAssertFalse(PhonePanelItem.ringer.isEnabled(in: away))
        XCTAssertEqual(PhonePanelItem.ringer.reason(in: away),
                       "Connect your phone to use these.")
    }

    /// A disabled tile is never drawn as on. With DND on the Ringer reads
    /// Vibrate, which used to tint its disabled tile accent-blue, so it looked
    /// like a control that was on (CONV-MAC-25).
    func testADisabledTileIsNeverOn() {
        let dndOn = state(dnd: .priority, ringer: .vibrate)
        XCTAssertFalse(PhonePanelItem.ringer.isEnabled(in: dndOn))
        XCTAssertFalse(PhonePanelItem.ringer.isOn(in: dndOn))
        XCTAssertTrue(PhonePanelItem.dnd.isOn(in: dndOn))

        let vibrate = state(ringer: .vibrate)
        XCTAssertTrue(PhonePanelItem.ringer.isEnabled(in: vibrate))
        XCTAssertTrue(PhonePanelItem.ringer.isOn(in: vibrate))

        let away = state(online: false, dnd: .priority, ringer: .vibrate)
        XCTAssertFalse(PhonePanelItem.dnd.isEnabled(in: away))
        XCTAssertFalse(PhonePanelItem.dnd.isOn(in: away))
    }

    /// Turn Off Screen follows the phone window's held panel: "Screen off"
    /// when the phone holds it off, "Screen on" otherwise, and no phone window
    /// means the tile is disabled with the reason instead of hidden.
    func testTheScreenTileFollowsThePanelAndNeedsItsWindow() {
        let closed = state(phoneWindow: false)
        XCTAssertFalse(PhonePanelItem.screen.isEnabled(in: closed))
        XCTAssertEqual(PhonePanelItem.screen.reason(in: closed), "Open Phone Mirror first.")

        var on = state()
        on.phoneWindow = true
        on.panelOff = false
        XCTAssertTrue(PhonePanelItem.screen.isEnabled(in: on))
        XCTAssertEqual(on.screenTitle, "Screen on")

        var off = state()
        off.phoneWindow = true
        off.panelOff = true
        XCTAssertTrue(PhonePanelItem.screen.isEnabled(in: off))
        XCTAssertEqual(off.screenTitle, "Screen off")
    }

    /// The window button is the Phone Mirror, and the tile that opens it says
    /// so; the compact WINDOWS row may draw "Mirror" but VoiceOver reads this.
    func testTheWindowButtonIsNamedPhoneMirror() {
        XCTAssertEqual(PhonePanelItem.phoneScreen.label, "Phone Mirror")
    }

    /// Every other tile says its own reason: DND support, the link, the
    /// volume's fields. A control that cannot work is off, never hidden.
    func testEveryTileAndRowCarriesItsOwnReason() {
        let noDnd = state(dnd: nil)
        XCTAssertFalse(PhonePanelItem.dnd.isEnabled(in: noDnd))
        XCTAssertEqual(PhonePanelItem.dnd.reason(in: noDnd),
                       "This phone doesn't report Do Not Disturb.")

        let noVolume = state(volume: nil)
        XCTAssertFalse(PhonePanelItem.volume.isEnabled(in: noVolume))
        XCTAssertEqual(PhonePanelItem.volume.reason(in: noVolume),
                       "Your phone hasn't sent a volume.")

        let away = state(online: false)
        for item in [PhonePanelItem.dnd, .ringer, .ring, .volume, .phoneScreen, .continueOnMac] {
            XCTAssertFalse(item.isEnabled(in: away), "\(item) must be off offline")
            XCTAssertNotNil(item.reason(in: away), "\(item) must say why")
        }
        XCTAssertEqual(PhonePanelItem.findApps.reason(in: away), nil,
                       "Find Apps opens the Deck's search; it needs no phone")
    }

    // MARK: - The hosted view

    private func host(_ state: PhoneControlsState,
                      showsFooter: Bool = true) -> NSHostingView<PhonePanelView> {
        window?.orderOut(nil)
        let view = NSHostingView(rootView: PhonePanelView(state: state, actions: PhoneControlsActions(),
                                                          showsFooter: showsFooter))
        view.frame = NSRect(x: 0, y: 0, width: PhonePanelView.width, height: 720)
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
        self.window = window
        return view
    }

    private func controls(in view: NSView) -> [NSView] {
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        return descendants(view)
            .filter {
                let name = String(describing: type(of: $0))
                return name.contains("KeyViewProxy") || $0 is NSSwitch || name.contains("PopupButton")
            }
            .sorted { a, b in
                let fa = a.convert(a.bounds, to: view), fb = b.convert(b.bounds, to: view)
                return fa.minY == fb.minY ? fa.minX < fb.minX : fa.minY < fb.minY
            }
    }

    private func frame(_ control: NSView, in view: NSView) -> CGRect {
        control.convert(control.bounds, to: view)
    }

    /// The four tiles are two rows of two: 134 pt wide, 8 pt apart, at least
    /// 62 pt tall, and they come before the volume in the focus order.
    func testTheTilesAreTwoRowsOfTwoAtTheirReviewSize() throws {
        let state = state()
        let view = host(state, showsFooter: false)
        let items = PhonePanelItem.focusOrder(for: state, showsFooter: false)
        let laidOut = controls(in: view)
        XCTAssertEqual(laidOut.count, items.count, "one laid-out control per item")
        guard let dndIndex = items.firstIndex(of: .dnd) else { return XCTFail("no DND tile") }
        let dnd = frame(laidOut[dndIndex], in: view)
        let ringer = frame(laidOut[dndIndex + 1], in: view)
        let ring = frame(laidOut[dndIndex + 2], in: view)
        let screen = frame(laidOut[dndIndex + 3], in: view)

        XCTAssertEqual(dnd.width, PhonePanelMetrics.tileWidth, accuracy: 1)
        XCTAssertEqual(ringer.width, PhonePanelMetrics.tileWidth, accuracy: 1)
        XCTAssertEqual(ringer.minX - dnd.maxX, PhonePanelMetrics.tileGap, accuracy: 1)
        XCTAssertEqual(dnd.minY, ringer.minY, accuracy: 1, "DND and Ringer share the top row")
        XCTAssertEqual(ring.minY, screen.minY, accuracy: 1, "Ring and Screen share the bottom row")
        XCTAssertGreaterThanOrEqual(dnd.height, PhonePanelMetrics.tileMinHeight - 1)
        XCTAssertGreaterThanOrEqual(ring.height, PhonePanelMetrics.tileMinHeight - 1)
        XCTAssertEqual(ring.minY - dnd.minY, dnd.height + PhonePanelMetrics.tileGap, accuracy: 1.5)
        XCTAssertEqual(ring.minX, dnd.minX, accuracy: 1)
    }

    /// The volume is still the inline slider with its percentage; the WINDOWS
    /// row is one row of four buttons, and the footer appears only when asked.
    func testTheVolumeRowAndWindowsRowAndFooter() {
        let state = state()
        let withFooter = host(state, showsFooter: true)
        let footerItems = PhonePanelItem.focusOrder(for: state, showsFooter: true)
        let footerControls = controls(in: withFooter)
        XCTAssertEqual(footerControls.count, footerItems.count)
        let volume = footerControls[footerItems.firstIndex(of: .volume)!]
        let volumeRect = frame(volume, in: withFooter)
        XCTAssertEqual(volumeRect.height, 14, accuracy: 0.5)
        XCTAssertGreaterThan(volumeRect.width, 150)

        let phone = frame(footerControls[footerItems.firstIndex(of: .phoneScreen)!], in: withFooter)
        let find = frame(footerControls[footerItems.firstIndex(of: .findApps)!], in: withFooter)
        let cont = frame(footerControls[footerItems.firstIndex(of: .continueOnMac)!], in: withFooter)
        let install = frame(footerControls[footerItems.firstIndex(of: .installApk)!], in: withFooter)
        for rect in [phone, find, cont, install] {
            XCTAssertEqual(rect.minY, phone.minY, accuracy: 1, "WINDOWS is one row")
            XCTAssertGreaterThan(rect.width, 50)
        }
        XCTAssertLessThan(phone.maxX, find.minX)
        XCTAssertLessThan(cont.maxX, install.minX)

        let without = host(state, showsFooter: false)
        let bare = PhonePanelItem.focusOrder(for: state, showsFooter: false)
        XCTAssertEqual(controls(in: without).count, bare.count)
        XCTAssertFalse(bare.contains(.settings))
        XCTAssertFalse(bare.contains(.quit))
    }

    /// The two hosts: the menu bar asks for the footer, the Deck popover for
    /// none. One view, one body.
    func testTheDeckPopoverDropsTheFooter() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PocketDeck", isDirectory: true)
        let deck = try String(contentsOf: sources.appendingPathComponent("DeckViews.swift"), encoding: .utf8)
        let menu = try String(contentsOf: sources.appendingPathComponent("MenuBar.swift"), encoding: .utf8)
        XCTAssertTrue(deck.contains("showsFooter: false"), "the Deck popover has no Settings/Quit footer")
        XCTAssertTrue(menu.contains("showsFooter: true"), "the menu bar panel keeps its footer")
    }
}
