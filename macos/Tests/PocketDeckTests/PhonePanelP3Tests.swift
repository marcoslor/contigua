// Panel P3 (docs/design/mac-redesign.md §3.8, the 2026-10-22 deck-panel
// review): a 2×2 tile grid, a menu on the Ringer tile, the volume slider with
// its value, one compact WINDOWS row, and the menu bar panel's gear last in
// Tab order. The pure model is what the e2e's paneldump reads and what the view
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
                       sessions: [MediaSessionRow] = [], phoneWindow: Bool = true,
                       agentCount: Int = 0) -> PhoneControlsState {
        var state = PhoneControlsState()
        state.phoneName = "Pixel 9"
        state.connection = online ? .online : .offline
        state.dnd = dnd
        state.ringer = ringer
        state.volume = volume
        state.volumeMax = 15
        state.sessions = sessions
        state.phoneWindow = phoneWindow
        state.agentCount = agentCount
        return state
    }

    // MARK: - The model

    /// P3's order: the menu bar panel's gear first (the header's control), then
    /// the four tiles, the volume, the picker when there is one and the window
    /// buttons. The Deck popover has no gear, so its order starts at DND.
    /// Settings… and Quit are the icon's menu, never rows.
    func testTheFocusOrderIsP3WithTheGearFirst() {
        let plain = state()
        let tiles = [PhonePanelItem.dnd, .ringer, .ring, .screen, .volume,
                     .phoneScreen, .findApps, .continueOnMac, .installApk]
        XCTAssertEqual(PhonePanelItem.focusOrder(for: plain), tiles)
        XCTAssertEqual(PhonePanelItem.focusOrder(for: plain, showsGear: true), [.gear] + tiles)

        let two = state(sessions: [MediaSessionRow(key: "a", pkg: "p.a", app: "Spotify", playing: false),
                                   MediaSessionRow(key: "b", pkg: "p.b", app: "Music", playing: true)])
        XCTAssertEqual(PhonePanelItem.focusOrder(for: two, showsGear: true),
                       [.gear, .dnd, .ringer, .ring, .screen, .volume, .sessions,
                        .phoneScreen, .findApps, .continueOnMac, .installApk])

        XCTAssertFalse(PhonePanelItem.allCases.contains { $0.rawValue == "settings" || $0.rawValue == "quit" },
                       "the footer rows are gone from the item model")
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

    /// The handoff button says what it does (CONV-PD-09): the short label and
    /// the full sentence a person hears or reads in its help tag.
    func testTheHandoffButtonNamesWhatItDoes() {
        XCTAssertEqual(PhonePanelItem.continueOnMac.label, "Move to Mac")
        XCTAssertEqual(PhonePanelView.moveToMacHelp,
                       "Moves the app on your phone's screen into its own Mac window, where you left off (⇧⌘C)")
    }

    /// A disabled tile says why on its own second line, in a few words; the
    /// full sentence stays the reason. An enabled tile shows its state instead.
    func testADisabledTileSaysWhyOnItsSubtitle() {
        let away = state(online: false)
        XCTAssertEqual(PhonePanelItem.dnd.shortReason(in: away), "Connect phone first")
        XCTAssertEqual(PhonePanelItem.ring.shortReason(in: away), "Connect phone first")

        let closed = state(phoneWindow: false)
        XCTAssertEqual(PhonePanelItem.screen.shortReason(in: closed), "Open Mirror first")

        let dndOn = state(dnd: .priority, ringer: .vibrate)
        XCTAssertEqual(PhonePanelItem.ringer.shortReason(in: dndOn), "Off while DND is on")

        let noDnd = state(dnd: nil)
        XCTAssertEqual(PhonePanelItem.dnd.shortReason(in: noDnd), "Not on this phone")

        XCTAssertNil(PhonePanelItem.dnd.shortReason(in: state()))
        XCTAssertNil(PhonePanelItem.screen.shortReason(in: state()))
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

    /// PANEL-12/19: with a mirror open but the link down, the tile cannot work:
    /// a click would send `phone.panel` into a dead session. The offline reason
    /// comes first, so the tile says why it is off instead of opening a request
    /// the phone will never answer (CONV-PD-02/CONV-PD-03, misses.md M3).
    func testTheScreenTileIsOffWhileTheLinkIsDown() {
        let offline = state(online: false, phoneWindow: true)
        XCTAssertFalse(PhonePanelItem.screen.isEnabled(in: offline),
                       "Turn Off Screen was enabled with no link, even with a mirror open")
        XCTAssertEqual(PhonePanelItem.screen.reason(in: offline), "Connect your phone to use these.")
        XCTAssertEqual(PhonePanelItem.screen.shortReason(in: offline), "Connect phone first")
    }

    /// PATH-17 + PANEL-12: a live session with no usable path is not
    /// Connected. The panel says Reconnecting at once and Offline after the
    /// windows' 15 s, so a path outage cannot leave its controls enabled
    /// while every request would queue into the grace's dead session.
    func testAPathOutageTakesThePanelOffline() {
        let phone = PhoneRef(id: "aaa", name: "Pixel 9", model: "")
        XCTAssertEqual(PhoneControlsState.Connection.resolve(
            link: .online(phone), pathsDown: false, pathsOffline: false), .online)
        XCTAssertEqual(PhoneControlsState.Connection.resolve(
            link: .online(phone), pathsDown: true, pathsOffline: false), .reconnecting)
        XCTAssertEqual(PhoneControlsState.Connection.resolve(
            link: .online(phone), pathsDown: true, pathsOffline: true), .offline)
        // The controller's own `link` already reports the outage as Reconnecting.
        XCTAssertEqual(PhoneControlsState.Connection.resolve(
            link: .reconnecting(phone), pathsDown: true, pathsOffline: false), .reconnecting)
        XCTAssertEqual(PhoneControlsState.Connection.resolve(
            link: .reconnecting(phone), pathsDown: true, pathsOffline: true), .offline)
        var state = state(online: true, phoneWindow: true)
        state.connection = .resolve(link: .reconnecting(phone), pathsDown: true, pathsOffline: true)
        XCTAssertFalse(PhonePanelItem.screen.isEnabled(in: state),
                       "Turn Off Screen was enabled with no usable path")
        XCTAssertEqual(PhonePanelItem.screen.reason(in: state), "Connect your phone to use these.")
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

    private func host(_ state: PhoneControlsState, showsGear: Bool = false) -> NSHostingView<PhonePanelView> {
        window?.orderOut(nil)
        let gear: (() -> Void)? = showsGear ? {} : nil
        let view = NSHostingView(rootView: PhonePanelView(state: state, actions: PhoneControlsActions(),
                                                          onGear: gear))
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

    /// The card in a real menu-bar panel, key and laid out the way the status
    /// item's panel is when it opens — without the focus step, which the test
    /// runs itself.
    private func panelHost(_ state: PhoneControlsState) -> (MenuBarPanel, NSHostingView<PhonePanelView>) {
        window?.orderOut(nil)
        let view = NSHostingView(rootView: PhonePanelView(state: state,
                                                          actions: PhoneControlsActions(),
                                                          onGear: {}))
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let panel = MenuBarPanel(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        view.frame = NSRect(origin: .zero, size: size)
        panel.contentView = view
        panel.orderFrontRegardless()
        panel.makeKey()
        view.layoutSubtreeIfNeeded()
        window = panel
        return (panel, view)
    }

    private func isControl(_ view: NSView) -> Bool {
        let name = String(describing: type(of: view))
        return name.contains("KeyViewProxy") || view is NSSwitch || name.contains("PopupButton")
    }

    /// The controls in the order SwiftUI laid them out — the key-view order the
    /// debug probe maps `PhonePanelItem.focusOrder` to.
    private func hierarchyControls(in view: NSView) -> [NSView] {
        func walk(_ view: NSView) -> [NSView] {
            let own: [NSView] = isControl(view) ? [view] : []
            return own + view.subviews.flatMap(walk)
        }
        return walk(view)
    }

    private func controls(in view: NSView) -> [NSView] {
        hierarchyControls(in: view).sorted { a, b in
            let fa = a.convert(a.bounds, to: view), fb = b.convert(b.bounds, to: view)
            return fa.minY == fb.minY ? fa.minX < fb.minX : fa.minY < fb.minY
        }
    }

    /// The help tag and accessibility names a control's subtree carries.
    private func helpAndLabel(of view: NSView) -> String {
        var found: [String] = []
        func walk(_ view: NSView) {
            if let tip = view.toolTip, !tip.isEmpty { found.append(tip) }
            if let label = view.accessibilityLabel(), !label.isEmpty { found.append(label) }
            if let help = view.accessibilityHelp(), !help.isEmpty { found.append(help) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found.joined(separator: " | ")
    }

    private func frame(_ control: NSView, in view: NSView) -> CGRect {
        control.convert(control.bounds, to: view)
    }

    /// The four tiles are two rows of two: 134 pt wide, 8 pt apart, at least
    /// 62 pt tall, and they come before the volume in the focus order.
    func testTheTilesAreTwoRowsOfTwoAtTheirReviewSize() throws {
        let state = state()
        let view = host(state)
        let items = PhonePanelItem.focusOrder(for: state)
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

    /// The volume is still the inline slider with its percentage, and the
    /// WINDOWS row is one row of four buttons.
    func testTheVolumeRowAndWindowsRow() {
        let state = state()
        let view = host(state)
        let items = PhonePanelItem.focusOrder(for: state)
        let laidOut = controls(in: view)
        XCTAssertEqual(laidOut.count, items.count)
        let volume = frame(laidOut[items.firstIndex(of: .volume)!], in: view)
        XCTAssertEqual(volume.height, 14, accuracy: 0.5)
        XCTAssertGreaterThan(volume.width, 150)

        let phone = frame(laidOut[items.firstIndex(of: .phoneScreen)!], in: view)
        let find = frame(laidOut[items.firstIndex(of: .findApps)!], in: view)
        let cont = frame(laidOut[items.firstIndex(of: .continueOnMac)!], in: view)
        let install = frame(laidOut[items.firstIndex(of: .installApk)!], in: view)
        for rect in [phone, find, cont, install] {
            XCTAssertEqual(rect.minY, phone.minY, accuracy: 1, "WINDOWS is one row")
            XCTAssertGreaterThan(rect.width, 50)
        }
        XCTAssertLessThan(phone.maxX, find.minX)
        XCTAssertLessThan(cont.maxX, install.minX)
    }

    /// The gear sits on the header's right edge and is the card's first control
    /// in key order; the panel steps past it when it opens (next test).
    func testTheGearIsOnTheHeaderAndHeadsTheKeyOrder() {
        let state = state()
        let items = PhonePanelItem.focusOrder(for: state, showsGear: true)
        XCTAssertEqual(items.first, .gear)
        XCTAssertEqual(PhonePanelItem.focusOrder(for: state).first, .dnd,
                       "the Deck popover has no gear")

        let view = host(state, showsGear: true)
        let laidOut = hierarchyControls(in: view)
        XCTAssertEqual(laidOut.count, items.count, "one laid-out control per item")
        let gear = frame(laidOut[0], in: view)
        XCTAssertEqual(gear.width, 22, accuracy: 1)
        XCTAssertEqual(gear.height, 22, accuracy: 1)
        XCTAssertEqual(gear.maxX, PhonePanelView.width - PhonePanelMetrics.inset, accuracy: 1,
                       "the gear sits on the panel's right inset")
        let dnd = frame(laidOut[items.firstIndex(of: .dnd)!], in: view)
        XCTAssertLessThan(gear.maxY, dnd.minY, "the gear is in the header, above the tiles")
    }

    /// The panel opens on its first phone control, not on the gear and never on
    /// a destructive action: the ring lands on DND with or without an agent,
    /// and the panel steps past the agent row's Disconnect to get there
    /// (PANEL-7, ISS-75). The panel steps past its first key view for this, and
    /// `openingFocusSteps` names how far.
    func testThePanelOpensOnTheFirstTileNotTheGear() {
        let plain = state()
        let items = PhonePanelItem.focusOrder(for: plain, showsGear: true)
        XCTAssertEqual(items.first, .gear, "the gear heads the card")
        XCTAssertEqual(PhonePanelItem.openingFocus(for: plain), .dnd)
        XCTAssertEqual(PhonePanelItem.openingFocusSteps(for: plain), 1)

        let agent = state(agentCount: 1)
        XCTAssertEqual(PhonePanelItem.openingFocus(for: agent), .dnd,
                       "the opening focus never lands on Disconnect")
        XCTAssertEqual(PhonePanelItem.openingFocusSteps(for: agent), 2,
                       "the agent row adds one key view between the gear and DND")

        let (panel, view) = panelHost(plain)
        let laidOut = hierarchyControls(in: view)
        XCTAssertEqual(laidOut.count, items.count, "one laid-out control per item")
        XCTAssertTrue(panel.firstResponder === laidOut[items.firstIndex(of: .gear)!],
                      "the key order starts on the gear")
        panel.focusFirstPhoneControl(steps: PhonePanelItem.openingFocusSteps(for: plain))
        XCTAssertTrue(panel.firstResponder === laidOut[items.firstIndex(of: .dnd)!],
                      "the opening focus is the DND tile")

        let agentItems = PhonePanelItem.focusOrder(for: agent, showsGear: true)
        let (agentPanel, agentView) = panelHost(agent)
        let agentControls = hierarchyControls(in: agentView)
        XCTAssertEqual(agentControls.count, agentItems.count)
        agentPanel.focusFirstPhoneControl(steps: PhonePanelItem.openingFocusSteps(for: agent))
        XCTAssertTrue(agentPanel.firstResponder
                      === agentControls[agentItems.firstIndex(of: .dnd)!],
                      "the ring lands on DND, not on Disconnect")
    }

    /// The gear's menu anchors at the gear's own button: the pure rect the
    /// controller pops at is the frame SwiftUI laid the gear out in (PANEL-3).
    func testTheGearAnchorIsTheGearButtonsOwnFrame() {
        let state = state()
        let (panel, view) = panelHost(state)
        let items = PhonePanelItem.focusOrder(for: state, showsGear: true)
        let laidOut = hierarchyControls(in: view)
        guard let gearIndex = items.firstIndex(of: .gear), gearIndex < laidOut.count else {
            return XCTFail("no gear control")
        }
        let gear = laidOut[gearIndex]
        let inWindow = gear.convert(gear.bounds, to: nil)
        let onScreen = NSRect(origin: panel.convertPoint(toScreen: inWindow.origin),
                              size: inWindow.size)
        let anchor = MenuBarMenuAnchor.gearRect(host: view.frame, panel: panel.frame)
        XCTAssertEqual(anchor.origin.x, onScreen.origin.x, accuracy: 0.5)
        XCTAssertEqual(anchor.origin.y, onScreen.origin.y, accuracy: 0.5)
        XCTAssertEqual(anchor.size, onScreen.size)
        XCTAssertEqual(anchor.width, PhonePanelMetrics.gearSize)
    }

    /// One view, one body, two hosts: the menu bar panel passes the gear's
    /// action, the Deck popover passes none, and no host has a footer row.
    func testOnlyTheMenuBarPanelHasTheGear() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PocketDeck", isDirectory: true)
        let deck = try String(contentsOf: sources.appendingPathComponent("DeckViews.swift"), encoding: .utf8)
        let menu = try String(contentsOf: sources.appendingPathComponent("MenuBar.swift"), encoding: .utf8)
        XCTAssertFalse(deck.contains("onGear:"), "the Deck popover has no gear")
        XCTAssertTrue(menu.contains("onGear: onSecondaryMenu"), "the menu bar panel has the gear")
        XCTAssertFalse(menu.contains("showsFooter"), "the panel has no footer rows")
    }
}
