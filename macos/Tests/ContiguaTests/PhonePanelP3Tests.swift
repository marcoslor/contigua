// Panel P3 (docs/design/mac-redesign.md §3.8, the 2026-10-22 deck-panel
// review): a 2×2 tile grid, a menu on the Ringer tile, the volume slider with
// its value, one compact WINDOWS row, and the menu bar panel's gear last in
// Tab order. The pure model is what the e2e's paneldump reads and what the view
// draws; the hosted view checks pin the frames a pointer hits.

import AppKit
import SwiftUI
import XCTest
@testable import Contigua

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

    /// The P2 reading order: the menu bar panel's gear first (the header's
    /// control), then the four modules' one Sound slider, the modules, the
    /// picker when there is one, the live rows and their Dismiss buttons, the
    /// handoff row when the phone reports an app in front, and the two window
    /// buttons. Install APK… is the Phone menu's, never a card row.
    func testTheFocusOrderIsTheReadingOrderWithTheGearFirst() {
        let plain = state()
        let reading = [PhonePanelItem.volume, .dnd, .ringer, .ring, .screen,
                       .phoneScreen, .findApps]
        XCTAssertEqual(PhonePanelItem.focusOrder(for: plain), reading)
        XCTAssertEqual(PhonePanelItem.focusOrder(for: plain, showsGear: true), [.gear] + reading)

        let two = state(sessions: [MediaSessionRow(key: "a", pkg: "p.a", app: "Spotify", playing: false),
                                   MediaSessionRow(key: "b", pkg: "p.b", app: "Music", playing: true)])
        XCTAssertEqual(PhonePanelItem.focusOrder(for: two, showsGear: true),
                       [.gear, .volume, .dnd, .ringer, .ring, .screen, .sessions,
                        .phoneScreen, .findApps])

        var front = state()
        front.handoff = FrontAppRow(pkg: "p.maps", label: "Maps", icon: nil)
        XCTAssertEqual(PhonePanelItem.focusOrder(for: front),
                       [.volume, .dnd, .ringer, .ring, .screen, .continueOnMac,
                        .phoneScreen, .findApps])

        var live = state()
        live.live = [NotifyLiveItem(id: "n1", pkg: "com.example.clock", label: "Timer",
                                    chip: nil, progress: nil, chrono: nil, countDown: false,
                                    updated: Date())]
        XCTAssertEqual(PhonePanelItem.focusOrder(for: live),
                       [.volume, .dnd, .ringer, .ring, .screen, .live, .liveDismiss,
                        .phoneScreen, .findApps])

        var phones = state()
        phones.phones = [PhoneControlsState.PanelPhone(id: "a", name: "Pixel 9", active: true),
                         PhoneControlsState.PanelPhone(id: "b", name: "Galaxy S25+", active: false)]
        phones.agentCount = 1
        XCTAssertEqual(PhonePanelItem.focusOrder(for: phones, showsGear: true).prefix(4),
                       [.gear, .phonePicker, .disconnectAgent, .volume])

        XCTAssertFalse(PhonePanelItem.allCases.contains { $0.rawValue == "settings" || $0.rawValue == "quit" },
                       "the footer rows are gone from the item model")
        XCTAssertFalse(PhonePanelItem.focusOrder(for: plain).contains(.installApk),
                       "Install APK… left the card")
    }

    /// The Ringer tile: the subtitle names the phone's mode, the menu lists
    /// exactly Ring/Vibrate/Silent with the current one checked, and the tile
    /// is disabled with a reason on an old phone or while DND is on.
    func testTheRingerModuleNamesItsModeAndExplainsWhyItIsOff() {
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

    /// The handoff module says what it does (CONV-PD-09): the app's name when
    /// the phone reports one, the fallback the menu must always have, and the
    /// full sentence in its help tag and VoiceOver hint.
    func testTheHandoffButtonNamesWhatItDoes() {
        XCTAssertEqual(PhonePanelItem.continueOnMac.label, "Open Current App on Mac")
        XCTAssertEqual(PhonePanelView.handoffHelp,
                       "Moves the app on your phone's screen into its own Mac window, where you left off (⇧⌘C)")
        let maps = FrontAppRow(pkg: "p.maps", label: "Maps", icon: nil)
        XCTAssertEqual(maps.title, "Open Maps on Mac")
        XCTAssertEqual(maps.help,
                       "Moves Maps from your phone's screen into its own Mac window, where you left off (⇧⌘C)")
        XCTAssertEqual(FrontAppRow(pkg: "p.unknown", label: nil, icon: nil).title,
                       "Open Current App on Mac")
    }

    /// A disabled module says why on its own second line, in a few words; the
    /// full sentence stays the reason. While the link is down the four modules
    /// show no per-module line: the Sound module carries the group's reason.
    func testADisabledModuleSaysWhyOnItsSecondLine() {
        let away = state(online: false)
        XCTAssertNil(PhonePanelItem.dnd.shortReason(in: away))
        XCTAssertNil(PhonePanelItem.ring.shortReason(in: away))
        XCTAssertEqual(PhonePanelItem.screen.shortReason(in: away), nil)

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
    func testADisabledModuleIsNeverOn() {
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
    /// means the module is disabled with the reason instead of hidden.
    func testTheScreenModuleFollowsThePanelAndNeedsItsWindow() {
        let closed = state(phoneWindow: false)
        XCTAssertFalse(PhonePanelItem.screen.isEnabled(in: closed))
        XCTAssertEqual(PhonePanelItem.screen.reason(in: closed), "Open Phone Mirror first.")
        XCTAssertEqual(PhonePanelItem.screen.shortReason(in: closed), "Open Mirror first")

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

    /// PANEL-12/19: with a mirror open but the link down, the module cannot
    /// work: a click would send `phone.panel` into a dead session. The offline
    /// group reason comes first, so the module says nothing of its own and the
    /// Sound module carries the one sentence (CONV-PD-02/CONV-PD-03, misses.md M3).
    func testTheScreenModuleIsOffWhileTheLinkIsDown() {
        let offline = state(online: false, phoneWindow: true)
        XCTAssertFalse(PhonePanelItem.screen.isEnabled(in: offline),
                       "Turn Off Screen was enabled with no link, even with a mirror open")
        XCTAssertEqual(PhonePanelItem.screen.reason(in: offline), "Connect your phone to use these.")
        XCTAssertNil(PhonePanelItem.screen.shortReason(in: offline))
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

    /// The WINDOWS row is two normal-text buttons: Phone Mirror and Apps,
    /// with Apps reading "Find Apps" to VoiceOver (PANEL-16).
    func testTheWindowRowIsPhoneMirrorAndAppsAtNormalTextSize() {
        XCTAssertEqual(PhonePanelItem.phoneScreen.label, "Phone Mirror")
        XCTAssertEqual(PhonePanelItem.findApps.label, "Find Apps")
        XCTAssertGreaterThanOrEqual(PhonePanelMetrics.windowMinHeight, 30,
                                    "normal text needs the 32 pt button")
    }

    /// Every other tile says its own reason: DND support, the link, the
    /// volume's fields. A control that cannot work is off, never hidden.
    func testEveryModuleAndRowCarriesItsOwnReason() {
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

    /// The four modules are two rows of two: 134 pt wide, 8 pt apart, at least
    /// 62 pt tall; their titles and state lines are the design's (PANEL-8).
    func testTheModulesAreTwoRowsOfTwoWithTheirTitlesAndStates() throws {
        let state = state()
        XCTAssertEqual(PhonePanelItem.dnd.label, "Focus")
        XCTAssertEqual(PhonePanelItem.ringer.label, "Ringer")
        XCTAssertEqual(PhonePanelItem.ring.label, "Ring Phone")
        XCTAssertEqual(PhonePanelItem.screen.label, "Turn Off Screen")
        XCTAssertEqual(state.ringSubtitle, "Plays a sound")
        XCTAssertEqual(state.screenTitle, "Screen on")

        let view = host(state)
        let items = PhonePanelItem.focusOrder(for: state)
        let laidOut = controls(in: view)
        XCTAssertEqual(laidOut.count, items.count, "one laid-out control per item")
        // A short list fails above; indexing it would crash the whole test process.
        guard laidOut.count == items.count else { return }
        guard let dndIndex = items.firstIndex(of: .dnd) else { return XCTFail("no Focus module") }
        let dnd = frame(laidOut[dndIndex], in: view)
        let ringer = frame(laidOut[dndIndex + 1], in: view)
        let ring = frame(laidOut[dndIndex + 2], in: view)
        let screen = frame(laidOut[dndIndex + 3], in: view)

        XCTAssertEqual(dnd.width, PhonePanelMetrics.tileWidth, accuracy: 1)
        XCTAssertEqual(ringer.width, PhonePanelMetrics.tileWidth, accuracy: 1)
        XCTAssertEqual(ringer.minX - dnd.maxX, PhonePanelMetrics.tileGap, accuracy: 1)
        XCTAssertEqual(dnd.minY, ringer.minY, accuracy: 1, "Focus and Ringer share the top row")
        XCTAssertEqual(ring.minY, screen.minY, accuracy: 1, "Ring and Screen share the bottom row")
        XCTAssertGreaterThanOrEqual(dnd.height, PhonePanelMetrics.tileMinHeight - 1)
        XCTAssertGreaterThanOrEqual(ring.height, PhonePanelMetrics.tileMinHeight - 1)
        XCTAssertEqual(ring.minY - dnd.minY, dnd.height + PhonePanelMetrics.tileGap, accuracy: 1.5)
        XCTAssertEqual(ring.minX, dnd.minX, accuracy: 1)
    }

    /// The Sound module is the card's first control: the slider above the
    /// modules, full width, with its percentage (PANEL-13).
    func testTheSoundModuleComesFirstAndHoldsTheSlider() {
        let state = state()
        let view = host(state)
        let items = PhonePanelItem.focusOrder(for: state)
        let laidOut = controls(in: view)
        XCTAssertEqual(laidOut.count, items.count)
        // A short list fails above; indexing it would crash the whole test process.
        guard laidOut.count == items.count else { return }
        let volume = frame(laidOut[items.firstIndex(of: .volume)!], in: view)
        let dnd = frame(laidOut[items.firstIndex(of: .dnd)!], in: view)
        XCTAssertEqual(volume.height, 14, accuracy: 0.5)
        XCTAssertGreaterThan(volume.width, 150)
        XCTAssertLessThan(volume.maxY, dnd.minY, "the Sound module is above the 2×2 modules")
    }

    /// Each module is a real button that reads its title and its state: the
    /// one help string carries both, and the view applies a VoiceOver value to
    /// the four modules (PANEL-8/PANEL-21).
    func testTheModulesReadTheirTitleAndValue() throws {
        let state = state()
        let focus = PhonePanelItem.dnd.help(in: state)
        XCTAssertTrue(focus.contains("Focus"), "the module's help tag lacks its title: \(focus)")
        XCTAssertTrue(focus.contains("Off"), "the module's help tag lacks its state: \(focus)")
        let ring = PhonePanelItem.ring.help(in: state)
        XCTAssertTrue(ring.contains("Plays a sound"), "the ring module lacks its state: \(ring)")

        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Contigua/PhonePanel.swift"), encoding: .utf8)
        let values = source.components(separatedBy: ".accessibilityValue(").count - 1
        XCTAssertGreaterThanOrEqual(values, 4, "the four modules and the Sound slider carry their value")
    }

    /// The screen module's short reason is also its help tag (PANEL-12).
    func testTheScreenModulesHelpTagIsItsReason() {
        let closed = state(phoneWindow: false)
        XCTAssertEqual(PhonePanelItem.screen.help(in: closed), "Open Mirror first",
                       "the screen module's help tag is its short reason")
    }

    /// With two phones the name is a pop-up in the header and the card keeps
    /// its 300 pt width, even for a long name (PANEL-6/PANEL-27).
    func testThePhonePopUpFitsTheCardsWidth() throws {
        var state = state()
        state.phoneName = "Galaxy S25+ Ultra"
        state.phones = [
            PhoneControlsState.PanelPhone(id: "a", name: "Pixel 9", active: false),
            PhoneControlsState.PanelPhone(id: "b", name: "Galaxy S25+ Ultra", active: true),
        ]
        let view = host(state, showsGear: true)
        let laidOut = hierarchyControls(in: view)
        XCTAssertEqual(laidOut.count,
                       PhonePanelItem.focusOrder(for: state, showsGear: true).count)
        let rects = laidOut.map { frame($0, in: view) }
        let gear = try XCTUnwrap(rects.first {
            $0.width <= PhonePanelMetrics.gearSize + 1 && $0.maxY < PhonePanelMetrics.headerHeight + 20
        }, "no gear in the header")
        let picker = try XCTUnwrap(rects.first {
            $0.minY < PhonePanelMetrics.headerHeight && $0 != gear
        }, "no phone pop-up in the header")
        XCTAssertGreaterThan(picker.width, 40, "the name keeps its pop-up")
        XCTAssertLessThan(picker.maxX, gear.minX,
                          "the phone pop-up runs under the gear: \(picker) gear \(gear)")
        XCTAssertEqual(view.fittingSize.width, PhonePanelView.width, accuracy: 1,
                       "the card keeps its width with a long phone name")
    }

    /// The WINDOWS row is one row of two normal-text buttons (PANEL-16): the
    /// card has no Install APK… and no handoff row unless the phone reports a
    /// foreground app (PANEL-28).
    func testTheWindowsRowIsTwoButtons() {
        let state = state()
        let view = host(state)
        let items = PhonePanelItem.focusOrder(for: state)
        let laidOut = controls(in: view)
        XCTAssertEqual(laidOut.count, items.count)
        // A short list fails above; indexing it would crash the whole test process.
        guard laidOut.count == items.count else { return }
        let phone = frame(laidOut[items.firstIndex(of: .phoneScreen)!], in: view)
        let apps = frame(laidOut[items.firstIndex(of: .findApps)!], in: view)
        XCTAssertEqual(phone.minY, apps.minY, accuracy: 1, "WINDOWS is one row")
        XCTAssertGreaterThan(phone.width, 100)
        XCTAssertGreaterThan(apps.width, 100)
        XCTAssertGreaterThanOrEqual(phone.height, PhonePanelMetrics.windowMinHeight - 1)
        XCTAssertLessThan(phone.maxX, apps.minX)
        XCTAssertEqual(PhonePanelItem.phoneScreen.label, "Phone Mirror")
        XCTAssertEqual(PhonePanelItem.findApps.label, "Find Apps")
        XCTAssertFalse(items.contains(.installApk))
        XCTAssertFalse(items.contains(.continueOnMac))
    }

    /// The gear sits on the header's right edge and is the card's first control
    /// in key order; the panel steps past it when it opens (next test).
    func testTheGearIsOnTheHeaderAndHeadsTheKeyOrder() {
        let state = state()
        let items = PhonePanelItem.focusOrder(for: state, showsGear: true)
        XCTAssertEqual(items.first, .gear)
        XCTAssertEqual(PhonePanelItem.focusOrder(for: state).first, .volume,
                       "the Deck popover has no gear; Sound is its first control")

        let view = host(state, showsGear: true)
        let laidOut = hierarchyControls(in: view)
        XCTAssertEqual(laidOut.count, items.count, "one laid-out control per item")
        // A short list fails above; indexing it would crash the whole test process.
        guard laidOut.count == items.count else { return }
        let gear = frame(laidOut[0], in: view)
        XCTAssertEqual(gear.width, 22, accuracy: 1)
        XCTAssertEqual(gear.height, 22, accuracy: 1)
        XCTAssertEqual(gear.maxX, PhonePanelView.width - PhonePanelMetrics.inset, accuracy: 1,
                       "the gear sits on the panel's right inset")
        let dnd = frame(laidOut[items.firstIndex(of: .dnd)!], in: view)
        XCTAssertLessThan(gear.maxY, dnd.minY, "the gear is in the header, above the tiles")
    }

    /// The panel opens on its first phone module, not on the gear, the phone
    /// pop-up or a destructive action: the ring lands on Focus with or without
    /// an agent, and the panel steps past the gear, the Sound slider (and the
    /// agent row's Disconnect) to get there (PANEL-7, ISS-75).
    func testThePanelOpensOnTheFirstModuleNotTheGear() {
        let plain = state()
        let items = PhonePanelItem.focusOrder(for: plain, showsGear: true)
        XCTAssertEqual(items.first, .gear, "the gear heads the card")
        XCTAssertEqual(PhonePanelItem.openingFocus(for: plain), .dnd)
        XCTAssertEqual(PhonePanelItem.openingFocusSteps(for: plain), 2,
                       "gear -> Sound slider -> Focus")

        let agent = state(agentCount: 1)
        XCTAssertEqual(PhonePanelItem.openingFocus(for: agent), .dnd,
                       "the opening focus never lands on Disconnect")
        XCTAssertEqual(PhonePanelItem.openingFocusSteps(for: agent), 3,
                       "the agent row adds one key view between the gear and the Sound slider")

        let (panel, view) = panelHost(plain)
        let laidOut = hierarchyControls(in: view)
        XCTAssertEqual(laidOut.count, items.count, "one laid-out control per item")
        // A short list fails above; indexing it would crash the whole test process.
        guard laidOut.count == items.count else { return }
        XCTAssertTrue(panel.firstResponder === laidOut[items.firstIndex(of: .gear)!],
                      "the key order starts on the gear")
        panel.focusFirstPhoneControl(steps: PhonePanelItem.openingFocusSteps(for: plain))
        XCTAssertTrue(panel.firstResponder === laidOut[items.firstIndex(of: .dnd)!],
                      "the opening focus is the Focus module")

        let agentItems = PhonePanelItem.focusOrder(for: agent, showsGear: true)
        let (agentPanel, agentView) = panelHost(agent)
        let agentControls = hierarchyControls(in: agentView)
        XCTAssertEqual(agentControls.count, agentItems.count)
        agentPanel.focusFirstPhoneControl(steps: PhonePanelItem.openingFocusSteps(for: agent))
        XCTAssertTrue(agentPanel.firstResponder
                      === agentControls[agentItems.firstIndex(of: .dnd)!],
                      "the ring lands on Focus, not on Disconnect")
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
            .appendingPathComponent("Sources/Contigua", isDirectory: true)
        let deck = try String(contentsOf: sources.appendingPathComponent("DeckViews.swift"), encoding: .utf8)
        let menu = try String(contentsOf: sources.appendingPathComponent("MenuBar.swift"), encoding: .utf8)
        XCTAssertFalse(deck.contains("onGear:"), "the Deck popover has no gear")
        XCTAssertTrue(menu.contains("onGear: onSecondaryMenu"), "the menu bar panel has the gear")
        XCTAssertFalse(menu.contains("showsFooter"), "the panel has no footer rows")
    }
}
