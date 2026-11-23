// The panel as a person sees it: PhonePanelView hosted for real, with the
// controls SwiftUI laid out inside it and the pixels it draws
// (docs/design/mac-redesign.md §3.8). The two v104 bugs live here: a Slider in
// a menu-style MenuBarExtra became a "Phone volume" stepper submenu, and the
// flat list carried the track row and a second volume.
//
// Why the view tree and not the accessibility tree: a test process is not a
// foreground app (NSApp never activates, so no window becomes key), and
// SwiftUI builds its AX elements only for an AX client: the hosting view's
// `accessibilityChildren()` is empty here. The hosting view's own subviews are
// the laid-out hierarchy, and the e2e drives these same controls in the
// running app through the window's event dispatch, where fakephone counts the
// `dnd` and `media.command` they send.

import AppKit
import SwiftUI
import XCTest
@testable import Contigua

@MainActor
final class PhonePanelViewTests: XCTestCase {
    private var window: NSWindow?
    private var hosting: NSHostingView<PhonePanelView>?

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        hosting = nil
    }

    // MARK: - State

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

    private func live(_ id: String) -> NotifyLiveItem {
        NotifyLiveItem(id: id, pkg: "com.example.clock", label: "Timer", chip: nil,
                       progress: nil, chrono: nil, countDown: false, updated: Date())
    }

    // MARK: - Hosting

    /// The panel in a real window at its intended width, laid out.
    @discardableResult
    private func host(_ state: PhoneControlsState,
                      _ actions: PhoneControlsActions = PhoneControlsActions(),
                      gear: Bool = false) -> NSHostingView<PhonePanelView> {
        // One host at a time: the previous window goes away before the next.
        window?.orderOut(nil)
        let view = NSHostingView(rootView: PhonePanelView(state: state, actions: actions,
                                                          onGear: gear ? {} : nil))
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

    /// Every focusable control SwiftUI laid out, top to bottom: its key-view
    /// proxies (Buttons, the Slider), the real AppKit controls inside platform
    /// view hosts (the DND switch, the Now Playing popup).
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

    /// A click at the control's own frame through the window's event dispatch:
    /// the path a person's pointer takes. An NSEvent's location is in window
    /// coordinates, which is what `convert(_:to: nil)` gives.
    private func click(_ item: PhonePanelItem, state: PhoneControlsState,
                       in view: NSHostingView<PhonePanelView>) {
        guard let index = PhonePanelItem.focusOrder(for: state).firstIndex(of: item),
              index < controls(in: view).count else { return XCTFail("no \(item) control") }
        let control = controls(in: view)[index]
        let rect = control.convert(control.bounds, to: nil)
        click(at: CGPoint(x: rect.midX, y: rect.midY))
    }

    private func click(at point: CGPoint) {
        guard let window else { return XCTFail("no window") }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            window.sendEvent(event)
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    // MARK: - Rendering

    /// The panel offscreen, at its own width, one point per pixel.
    private func render(_ state: PhoneControlsState) -> CGImage? {
        let renderer = ImageRenderer(content: PhonePanelView(state: state, actions: PhoneControlsActions()))
        renderer.proposedSize = ProposedViewSize(width: PhonePanelView.width, height: nil)
        renderer.scale = 1
        return renderer.cgImage
    }

    private func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Whether anything was drawn in a band of the image (the panel's own
    /// background is transparent; text and controls are not).
    private func drawn(_ image: CGImage, in band: CGRect) -> Bool {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &data, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // CGContext's origin is bottom-left; the band is in the panel's
        // top-down layout, and an ImageRenderer image is top-down per row.
        let rows = Int(band.minY)..<min(Int(band.maxY), height)
        let columns = Int(band.minX)..<min(Int(band.maxX), width)
        for row in rows {
            for column in columns where data[(row * width + column) * 4 + 3] > 8 { return true }
        }
        return false
    }

    // MARK: - What the panel is

    /// The e2e reads the slider's local display through the probe mirror after
    /// each drag step. The host seeds it from the phone on the first render.
    func testTheVolumeMirrorStartsAtThePhonesValue() {
        PhoneVolumeDebug.reset()
        _ = host(panelState(volume: 8))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(PhoneVolumeDebug.display, 8.0 / 15.0, accuracy: 0.001)
        XCTAssertEqual(PhoneVolumeDebug.phase, "idle")
    }

    /// The v104 repro: the volume is still an inline 14 pt slider in its own
    /// row, not a "Phone volume" stepper submenu. The Ringer and picker are
    /// menus, but the volume itself is never a popup.
    func testTheVolumeIsAnInlineSliderNotASubmenu() {
        let state = panelState(sessions: [MediaSessionRow(key: "a", pkg: "p.a", app: "Spotify", playing: false),
                                          MediaSessionRow(key: "b", pkg: "p.b", app: "Music", playing: true)])
        let view = host(state)
        XCTAssertEqual(view.bounds.width, PhonePanelView.width)

        let laidOut = controls(in: view)
        XCTAssertEqual(laidOut.count, PhonePanelItem.focusOrder(for: state).count,
                       "one laid-out control per panel item")
        guard let volume = laidOut.first(where: { control in
            let rect = frame(control, in: view)
            return rect.height < 20 && rect.width > 150
        }) else { return XCTFail("no volume slider") }
        let rect = frame(volume, in: view)
        XCTAssertEqual(rect.height, 14, accuracy: 0.5, "the volume is a slider track, not a 28 pt row")
        XCTAssertGreaterThan(rect.width, 150, "the slider spans the row between its two speaker symbols")
        XCTAssertFalse(volume is NSPopUpButton, "the volume must not be a popup (the submenu shape)")

        // With nothing to pick the picker row is gone too, but the tiles still
        // are: the panel keeps one control per item.
        let plain = panelState()
        let plainView = host(plain)
        XCTAssertEqual(controls(in: plainView).count,
                       PhonePanelItem.focusOrder(for: plain).count)
    }

    /// The rows in the order the view lays them out: the full-width Sound
    /// module, the 2×2 modules, the picker, the live rows with their Dismiss
    /// buttons and the two window buttons (PANEL-13/PANEL-20). This is the
    /// order the e2e's panelclick/paneldrag map indices to.
    func testTheControlsAreLaidOutInThePanelOrder() {
        var state = panelState(sessions: [MediaSessionRow(key: "a", pkg: "p.a", app: "Spotify", playing: false),
                                          MediaSessionRow(key: "b", pkg: "p.b", app: "Music", playing: true)])
        state.live = [live("n1")]
        let view = host(state)
        let items = PhonePanelItem.focusOrder(for: state)
        let laidOut = controls(in: view)
        XCTAssertEqual(laidOut.count, items.count)
        // A short list fails above; indexing it would crash the whole test process.
        guard laidOut.count == items.count else { return }
        let ys = laidOut.map { frame($0, in: view).minY }
        XCTAssertEqual(ys, ys.sorted(), "the controls are top to bottom in the model's order")
        XCTAssertEqual(Array(items.prefix(5)), [.volume, .dnd, .ringer, .ring, .screen])
        XCTAssertLessThan(ys[items.firstIndex(of: .volume)!], ys[items.firstIndex(of: .dnd)!])
        XCTAssertLessThan(ys[items.firstIndex(of: .screen)!], ys[items.firstIndex(of: .sessions)!])
        XCTAssertLessThan(ys[items.firstIndex(of: .sessions)!], ys[items.firstIndex(of: .live)!])
        XCTAssertLessThan(ys[items.firstIndex(of: .live)!], ys[items.firstIndex(of: .phoneScreen)!])
        XCTAssertEqual(items.last, .findApps, "no footer, no Install APK and no gear in the Deck's copy")

        // The menu bar panel heads its order with the gear, in the header.
        let menu = host(state, gear: true)
        let menuItems = PhonePanelItem.focusOrder(for: state, showsGear: true)
        XCTAssertEqual(controls(in: menu).count, menuItems.count)
        XCTAssertEqual(menuItems.first, .gear)
    }

    /// Ring becomes Stop Ringing while the phone rings: the row's own click
    /// runs the other action, so a person never sees a stale label.
    func testTheRingRowFlipsToStopWhileThePhoneRings() {
        var calls: [String] = []
        var actions = PhoneControlsActions()
        actions.ring = { calls.append("ring") }
        actions.stopRing = { calls.append("stopRing") }

        var state = panelState()
        let idle = host(state, actions)
        XCTAssertEqual(state.ringTitle, "Ring Phone")
        click(.ring, state: state, in: idle)
        XCTAssertEqual(calls, ["ring"])

        state.ringing = true
        let ringing = host(state, actions)
        XCTAssertEqual(state.ringTitle, "Stop Ringing")
        click(.ring, state: state, in: ringing)
        XCTAssertEqual(calls, ["ring", "stopRing"])
    }

    /// Away: the phone controls are off and nothing fires. P3 keeps every
    /// control laid out with its reason on the control itself (a tile's
    /// subtitle, the volume row); the panel keeps its online height.
    func testOfflineDimsThePhoneControlsAndSaysWhy() throws {
        var calls: [String] = []
        var actions = PhoneControlsActions()
        actions.ring = { calls.append("ring") }
        actions.stopRing = { calls.append("stopRing") }
        actions.setVolume = { calls.append("volume \($0)") }
        actions.setDnd = { calls.append("dnd \($0)") }

        let state = panelState(online: false)
        let view = host(state, actions)
        for item in [PhonePanelItem.dnd, .ringer, .ring, .volume,
                     .phoneScreen, .continueOnMac, .installApk] {
            XCTAssertFalse(item.isEnabled(in: state), "\(item) must be off offline")
            XCTAssertNotNil(item.reason(in: state), "\(item) must say why")
        }
        XCTAssertEqual(state.reason, "Connect your phone to use these.")
        XCTAssertEqual(PhonePanelItem.ringer.reason(in: state), "Connect your phone to use these.")

        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        XCTAssertFalse(descendants(view).contains { $0 is NSSwitch },
                       "P3's DND control is a tile button, not an AppKit switch")
        let rect = view.bounds
        click(at: CGPoint(x: rect.midX, y: rect.midY))
        XCTAssertTrue(calls.isEmpty, "no disabled control runs anything")

        // No floating reason line: offline the panel is the online panel's height.
        let away = try XCTUnwrap(render(state))
        let now = try XCTUnwrap(render(panelState()))
        XCTAssertEqual(away.height, now.height,
                       "the reasons sit on their controls, not in a line under the grid")
    }

    /// No track text or artwork: two states that differ only in the media's
    /// title, performer and album draw the same pixels.
    func testThePanelDrawsNothingFromTheTrack() throws {
        var withTrack = panelState()
        withTrack.media?.title = "Secret Song"
        withTrack.media?.artist = "Secret Artist"
        withTrack.media?.album = "Secret Album"
        let without = panelState()

        let a = try XCTUnwrap(render(withTrack))
        let b = try XCTUnwrap(render(without))
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.height, b.height)
        XCTAssertNotNil(png(a))
        // The renderer's anti-aliasing can differ by a pixel or two between
        // two runs; track text would cover a band of the card. The panel reads
        // no media title, performer or album (PANEL-15).
        let diff = pixelDifference(a, b)
        XCTAssertLessThanOrEqual(diff.count, 4,
                                 "the track's text must not be drawn anywhere in the panel: \(diff.count) pixels differ at \(diff.box)")
    }

    /// PANEL-28: the handoff row is drawn only while the phone is online and
    /// the front machine knows a package; it sits after the Live rows and
    /// before WINDOWS, and its arrival moves no row above it.
    func testTheHandoffRowAppearsOnlyForAFreshFrontApp() {
        var known = panelState()
        known.handoff = FrontAppRow(pkg: "p.maps", label: "Maps", icon: nil)
        let with = host(known)
        let withItems = PhonePanelItem.focusOrder(for: known)
        XCTAssertTrue(withItems.contains(.continueOnMac), "no handoff row for a known app")
        XCTAssertEqual(withItems.firstIndex(of: .continueOnMac),
                       withItems.firstIndex(of: .phoneScreen)! - 1,
                       "the handoff row sits just above WINDOWS")
        XCTAssertEqual(controls(in: with).count, withItems.count,
                       "one laid-out control per item, the handoff row included")
        let withHeight = with.fittingSize.height
        let volumeY = frame(controls(in: with)[withItems.firstIndex(of: .volume)!], in: with).minY
        let dndY = frame(controls(in: with)[withItems.firstIndex(of: .dnd)!], in: with).minY

        let plain = panelState()
        let without = host(plain)
        let withoutItems = PhonePanelItem.focusOrder(for: plain)
        XCTAssertFalse(withoutItems.contains(.continueOnMac), "no row without a known app")
        XCTAssertEqual(controls(in: without).count, withoutItems.count)
        XCTAssertLessThan(without.fittingSize.height, withHeight, "the row adds its height")
        XCTAssertEqual(frame(controls(in: without)[withoutItems.firstIndex(of: .volume)!],
                             in: without).minY, volumeY, accuracy: 1,
                       "the Sound module stays where it was")
        XCTAssertEqual(frame(controls(in: without)[withoutItems.firstIndex(of: .dnd)!],
                             in: without).minY, dndY, accuracy: 1,
                       "the modules stay where they were")

        var away = known
        away.connection = .offline
        XCTAssertFalse(away.showsHandoff, "offline hides the row")
        XCTAssertFalse(PhonePanelItem.focusOrder(for: away).contains(.continueOnMac))
    }

    /// The one shared component: the Deck's popover and the menu bar panel
    /// build this same view, so the same controls and the same item ids are in
    /// both (the hosts only differ in what "open the Deck" means).
    func testTheDeckPopoverHostsTheSamePanel() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Contigua", isDirectory: true)
        for name in ["MenuBar.swift", "DeckViews.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(text.contains("PhonePanelView("), "\(name) hosts the shared panel")
            XCTAssertTrue(text.contains("PhoneControlsActions(controller: controller)"),
                          "\(name) uses the controller's own actions")
        }
        let panel = try String(contentsOf: sources.appendingPathComponent("PhonePanel.swift"), encoding: .utf8)
        XCTAssertTrue(panel.contains("accessibilityIdentifier(PhonePanelItem."),
                      "the rows carry the panel item ids both hosts inherit")
    }

    /// The pixels two renders differ in, and where.
    private func pixelDifference(_ a: CGImage, _ b: CGImage) -> (count: Int, box: CGRect) {
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = CGContext(data: &data, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return data
        }
        let pa = pixels(a), pb = pixels(b)
        var count = 0
        var box = CGRect.null
        for y in 0..<min(a.height, b.height) {
            for x in 0..<min(a.width, b.width) {
                let i = (y * a.width + x) * 4
                if pa[i..<i + 4] != pb[i..<i + 4] {
                    count += 1
                    box = box.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        return (count, box)
    }
}
