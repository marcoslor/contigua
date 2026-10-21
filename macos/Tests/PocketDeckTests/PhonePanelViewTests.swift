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
@testable import PocketDeck

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

    private func live(_ id: String) -> NotifyLiveItem {
        NotifyLiveItem(id: id, pkg: "com.example.clock", label: "Timer", chip: nil,
                       progress: nil, chrono: nil, countDown: false, updated: Date())
    }

    // MARK: - Hosting

    /// The panel in a real window at its intended width, laid out.
    @discardableResult
    private func host(_ state: PhoneControlsState,
                      _ actions: PhoneControlsActions = PhoneControlsActions()) -> NSHostingView<PhonePanelView> {
        // One host at a time: the previous window goes away before the next.
        window?.orderOut(nil)
        let view = NSHostingView(rootView: PhonePanelView(state: state, actions: actions))
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

    /// The v104 repro: the volume is an inline slider in its own row, not a
    /// "Phone volume" stepper submenu. Nothing in the panel is a popup control
    /// (the picker is an ordinary row with a menu), and the volume is a 14 pt
    /// track in its row.
    func testTheVolumeIsAnInlineSliderNotASubmenu() {
        let state = panelState(sessions: [MediaSessionRow(key: "a", pkg: "p.a", app: "Spotify", playing: false),
                                          MediaSessionRow(key: "b", pkg: "p.b", app: "Music", playing: true)])
        let view = host(state)
        XCTAssertEqual(view.bounds.width, PhonePanelView.width)

        let laidOut = controls(in: view)
        XCTAssertEqual(laidOut.count, PhonePanelItem.focusOrder(for: state).count,
                       "one laid-out control per panel item")
        guard let volume = laidOut.first else { return XCTFail("no volume control") }
        let rect = frame(volume, in: view)
        XCTAssertEqual(rect.height, 14, accuracy: 0.5, "the volume is a slider track, not a 28 pt row")
        XCTAssertGreaterThan(rect.width, 150, "the slider spans the row between its two speaker symbols")
        XCTAssertFalse(volume is NSPopUpButton, "the volume must not be a popup (the submenu shape)")

        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let popups = descendants(view).filter { String(describing: type(of: $0)).contains("PopupButton") }
        XCTAssertTrue(popups.isEmpty, "no control in the panel is a popup (the volume is not a submenu)")
        // With nothing to pick the picker row is gone too.
        let plain = host(panelState())
        let rows = controls(in: plain).count
        XCTAssertEqual(rows, PhonePanelItem.focusOrder(for: panelState()).count)
    }

    /// The rows in the order the view lays them out: the phone controls, the
    /// live notifications, the window actions, then Settings/Quit. This is the
    /// order the e2e's panelclick/paneldrag map indices to.
    func testTheControlsAreLaidOutInThePanelOrder() {
        var state = panelState(sessions: [MediaSessionRow(key: "a", pkg: "p.a", app: "Spotify", playing: false),
                                          MediaSessionRow(key: "b", pkg: "p.b", app: "Music", playing: true)])
        state.live = [live("n1")]
        let view = host(state)
        let items = PhonePanelItem.focusOrder(for: state)
        let laidOut = controls(in: view)
        XCTAssertEqual(laidOut.count, items.count)
        let ys = laidOut.map { frame($0, in: view).minY }
        XCTAssertEqual(ys, ys.sorted(), "the controls are top to bottom in the model's order")
        // PHONE is above LIVE, and both are above WINDOWS' rows.
        XCTAssertLessThan(ys[items.firstIndex(of: .ring)!], ys[items.firstIndex(of: .live)!])
        XCTAssertLessThan(ys[items.firstIndex(of: .live)!], ys[items.firstIndex(of: .phoneScreen)!])
        XCTAssertEqual(Array(items.suffix(2)), [.settings, .quit])
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

    /// Away: the phone controls are off and nothing fires, because the panel
    /// says why in one line instead of hiding them.
    func testOfflineDimsThePhoneControlsAndSaysWhy() throws {
        var calls: [String] = []
        var actions = PhoneControlsActions()
        actions.ring = { calls.append("ring") }
        actions.stopRing = { calls.append("stopRing") }
        actions.setVolume = { calls.append("volume \($0)") }
        actions.setDnd = { calls.append("dnd \($0)") }

        let state = panelState(online: false)
        let view = host(state, actions)
        let laidOut = controls(in: view)
        // The switch is still drawn, and it is off; a click on it runs nothing.
        guard let dnd = laidOut.compactMap({ $0 as? NSSwitch }).first else {
            return XCTFail("the DND control is the AppKit switch")
        }
        XCTAssertFalse(dnd.isEnabled, "the DND switch is off while the phone is away")
        let rect = frame(dnd, in: view)
        click(at: CGPoint(x: rect.midX, y: rect.midY))
        XCTAssertTrue(calls.isEmpty, "a disabled control runs nothing")

        // The reason line is drawn in the one row band it takes below the
        // slider; online there is no line and no gap, so the DND row follows
        // the volume row directly.
        let away = try XCTUnwrap(render(state))
        let dndTop = rect.minY - 14
        let band = CGRect(x: 12, y: dndTop - 14, width: 276, height: 12)
        XCTAssertTrue(drawn(away, in: band), "the panel draws the reason line while offline")
        let onlineView = host(panelState())
        let onlineSlider = try XCTUnwrap(controls(in: onlineView).first { c in
            let f = frame(c, in: onlineView)
            return f.height < 20 && f.width > 150
        })
        let onlineDnd = try XCTUnwrap(controls(in: onlineView).compactMap { $0 as? NSSwitch }.first)
        XCTAssertEqual(frame(onlineDnd, in: onlineView).midY - frame(onlineSlider, in: onlineView).midY,
                       28, accuracy: 0.5, "online there is no reason line and no gap under the slider")
        XCTAssertEqual(state.reason, "Connect your phone to use these.")
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
        XCTAssertEqual(png(a), png(b), "the track's text must not be drawn anywhere in the panel")
    }

    /// The one shared component: the Deck's popover and the menu bar panel
    /// build this same view, so the same controls and the same item ids are in
    /// both (the hosts only differ in what "open the Deck" means).
    func testTheDeckPopoverHostsTheSamePanel() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PocketDeck", isDirectory: true)
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
}
