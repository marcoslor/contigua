// The panel's debug host and control driver for the host e2e. A quiet run
// cannot open a MenuBarExtra's status item (that is the window server's), so
// `panelopen` shows the menu bar's exact content in a plain window; the Deck
// popover opens through its own state (`deckpanel`). Both then drive the real
// SwiftUI controls: a click or drag goes through NSApplication's event queue,
// the path a person's pointer takes, and the phone counts the effect.
//
// SwiftUI keeps its controls inside one hosting view, so the controls are
// found in the view tree: one KeyViewProxy per focusable row, the DND switch
// and the Now Playing popup as real AppKit views. They follow the panel's own
// layout order (PhonePanelItem.focusOrder); a control is only mapped while
// every item has one. A check that a click landed is the phone receiving
// `phone.dnd` / `media.command`, not the action being called.

import AppKit
import SwiftUI

@MainActor
enum PanelProbe {
    enum Host: String {
        case panel
        case deck
        /// The real status item's panel window (what a person sees). It is not
        /// reachable in a quiet host run (no click on the status item), only in
        /// the VM's visible run.
        case real
    }

    private static var hostWindow: NSWindow?
    private static weak var controller: ConnectionController?

    /// `panelopen`: the menu bar's content in a window of its own.
    static func open(controller: ConnectionController) {
        self.controller = controller
        if let hostWindow {
            hostWindow.makeKeyAndOrderFront(nil)
            return
        }
        let view = NSHostingView(rootView: AnyView(MenuBarContent().environment(controller)))
        view.frame = NSRect(x: 0, y: 0, width: PhonePanelView.width, height: 640)
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "PocketDeck Panel"
        window.identifier = NSUserInterfaceItemIdentifier("pocketdeck-panel")
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        if let screen = NSScreen.main {
            window.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.minX + 60,
                                                y: screen.visibleFrame.maxY - 40))
        }
        window.makeKeyAndOrderFront(nil)
        hostWindow = window
    }

    /// `panelclose`.
    static func close() {
        hostWindow?.orderOut(nil)
    }

    /// `deckpanel`: the status pill's popover (the pill itself is a toolbar
    /// item, not reachable without the real pointer in a quiet run; opening it
    /// is setup, the switch inside is the control under test).
    static func openDeckPopover(controller: ConnectionController) {
        self.controller = controller
        controller.openDeckPanel()
    }

    /// `paneldump HOST PATH`: the panel's model rows and the real controls the
    /// hosting view laid out, as JSON.
    static func dump(host: String, to path: String) -> Bool {
        guard let host = Host(rawValue: host) else { return false }
        guard let state = currentState() else { return false }
        guard let window = window(for: host) else { return false }
        let items = PhonePanelItem.focusOrder(for: state, showsFooter: showsFooter(host))
        let focusable = items.filter { $0.isEnabled(in: state) }
        settle(window, items: focusable)
        let controls = controlFrames(in: window)
        let rows: [[String: Any]] = items.enumerated().map { index, item in
            [
                "id": item.id,
                "kind": item.rawValue,
                "label": label(item, state: state),
                "enabled": enabled(item, state: state),
                "index": index,
            ]
        }
        let frames: [[String: Any]] = controls.enumerated().map { index, frame in
            ["index": index, "x": frame.minX, "y": frame.minY,
             "width": frame.width, "height": frame.height]
        }
        let root: [String: Any] = [
            "width": PhonePanelView.width,
            "phone": state.phoneName,
            "status": state.connection.text,
            "battery": state.shownBattery ?? -1,
            "reason": state.reason ?? "",
            "mapped": focusable.count == controls.count,
            "items": rows,
            "controls": frames,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else {
            return false
        }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// `panelclick HOST ID`: a click at the control's own frame, through the
    /// app's event queue.
    static func click(host: String, id: String) -> Bool {
        guard let host = Host(rawValue: host), let state = currentState(),
              let window = window(for: host) else { return false }
        settle(window, items: focusableItems(state, host: host))
        guard let target = control(for: id, state: state, host: host, in: window) else { return false }
        let point = CGPoint(x: target.frame.midX, y: target.frame.midY)
        switch target.kind {
        case .switch:
            // The switch's own click: an NSSwitch's mouseDown runs a tracking
            // loop that would wait for the queue in a quiet run.
            (switchView(in: window) as? NSSwitch)?.performClick(nil)
            pump(0.3)
        case .slider:
            send(.leftMouseDown, at: point, in: window)
            send(.leftMouseUp, at: point, in: window)
            pump(0.3)
        case .button, .popup:
            send(.leftMouseDown, at: point, in: window)
            send(.leftMouseUp, at: point, in: window)
            pump(0.2)
        }
        return true
    }

    /// `paneldrag HOST ID FRACTION`: the volume slider, from its current knob
    /// to the fraction of the track.
    static func drag(host: String, id: String, fraction: Double) -> Bool {
        guard let host = Host(rawValue: host), let state = currentState(),
              let window = window(for: host) else { return false }
        settle(window, items: focusableItems(state, host: host))
        guard let target = control(for: id, state: state, host: host, in: window) else { return false }
        let clamped = min(max(fraction, 0), 1)
        let startFraction = min(max(state.volumeFraction ?? 0.2, 0), 1)
        // The track's interactive span, inset by the knob's radius.
        let inset: CGFloat = 8
        let startX = target.frame.minX + inset
            + (target.frame.width - inset * 2) * startFraction
        let endX = target.frame.minX + inset
            + (target.frame.width - inset * 2) * clamped
        let y = target.frame.midY
        send(.leftMouseDown, at: CGPoint(x: startX, y: y), in: window)
        for step in 1...10 {
            let t = Double(step) / 10
            send(.leftMouseDragged, at: CGPoint(x: startX + (endX - startX) * t, y: y), in: window)
            pump(0.02)
        }
        send(.leftMouseUp, at: CGPoint(x: endX, y: y), in: window)
        pump(0.4)
        return true
    }

    /// `panelvolumedrag HOST FRACTION PATH`: a several-step drag that records
    /// what the slider showed after each step, before any phone echo can be
    /// mistaken for the pointer. The trace is the display the person sees, not
    /// the phone's last report.
    static func volumeDrag(host: String, fraction: Double, to path: String) -> Bool {
        guard let host = Host(rawValue: host), let state = currentState(),
              let window = window(for: host) else { return false }
        settle(window, items: focusableItems(state, host: host))
        guard let target = control(for: PhonePanelItem.volume.id, state: state, host: host,
                                   in: window) else { return false }
        let clamped = min(max(fraction, 0), 1)
        let startFraction = min(max(PhoneVolumeDebug.display, 0), 1)
        let inset: CGFloat = 8
        let startX = target.frame.minX + inset
            + (target.frame.width - inset * 2) * startFraction
        let endX = target.frame.minX + inset
            + (target.frame.width - inset * 2) * clamped
        let y = target.frame.midY
        var steps: [[String: Any]] = [["step": 0, "target": startFraction,
                                      "display": PhoneVolumeDebug.display,
                                      "phone": state.volumeFraction ?? -1,
                                      "phase": PhoneVolumeDebug.phase]]
        send(.leftMouseDown, at: CGPoint(x: startX, y: y), in: window)
        for step in 1...10 {
            let t = Double(step) / 10
            send(.leftMouseDragged, at: CGPoint(x: startX + (endX - startX) * t, y: y),
                 in: window)
            pump(0.02)
            let current = currentState()
            steps.append(["step": step,
                          "target": startFraction + (clamped - startFraction) * t,
                          "display": PhoneVolumeDebug.display,
                          "phone": current?.volumeFraction ?? -1,
                          "phase": PhoneVolumeDebug.phase])
        }
        send(.leftMouseUp, at: CGPoint(x: endX, y: y), in: window)
        pump(0.4)
        steps.append(["step": 11, "target": clamped,
                      "display": PhoneVolumeDebug.display,
                      "phone": currentState()?.volumeFraction ?? -1,
                      "phase": PhoneVolumeDebug.phase])
        let data = try? JSONSerialization.data(withJSONObject: steps, options: [.prettyPrinted])
        guard let data else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// `panelringer HOST MODE`: choose one of the Ringer tile's menu rows. The
    /// tile must be laid out and enabled; the action is the menu item's own
    /// (the same closure the label's Menu builds), and the phone's next `state`
    /// moves the checkmark, never an optimistic local guess.
    static func ringer(host: String, mode: PhoneRingerMode) -> Bool {
        guard let host = Host(rawValue: host), let state = currentState(),
              let window = window(for: host), let controller else { return false }
        settle(window, items: focusableItems(state, host: host))
        guard PhonePanelItem.ringer.isEnabled(in: state),
              state.ringerMenu.contains(where: { $0.mode == mode }),
              control(for: PhonePanelItem.ringer.id, state: state, host: host, in: window) != nil else {
            return false
        }
        PhoneControlsActions(controller: controller, openDeck: {}).setRinger(mode)
        return true
    }

    /// `panelwindows PATH`: what the app's windows are, for a failed lookup
    /// (the popover is its own window and may not be there yet).
    static func windowsReport(to path: String) -> Bool {
        let lines = NSApp.windows.map { window in
            "\(type(of: window)) title=\(window.title) id=\(window.identifier?.rawValue ?? "-")"
                + " visible=\(window.isVisible) frame=\(Int(window.frame.width))x\(Int(window.frame.height))"
                + " controls=\(controlViews(in: window).count)"
        }
        return (try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }

    // MARK: - Lookup

    /// What a laid-out control is, by the view SwiftUI put there.
    private enum Kind {
        case slider, button, popup, `switch`
    }

    private struct Control {
        let frame: CGRect
        let kind: Kind
    }

    /// Resize a host window the panel's own content height: the panel gains
    /// and loses the one reason line and the agent row, and the window is made
    /// once, so it would otherwise keep the height of an earlier state.
    private static func fit(_ window: NSWindow) {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let size = CGSize(width: PhonePanelView.width, height: view.fittingSize.height)
        guard size.height > 0, abs(view.frame.height - size.height) > 0.5 else { return }
        window.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
    }

    /// The panel's view tree follows the controller's state: a row that was
    /// disabled when the window opened has no key-view proxy until the next
    /// render, and the panel's height follows the reason line. A dump or a click
    /// that reads the tree in the same turn the state changed would see the old
    /// one (fewer controls than rows, or rows in another order). Give SwiftUI
    /// its turns first — the same ones a person's pointer sees.
    private static func settle(_ window: NSWindow, items: [PhonePanelItem]) {
        for _ in 0..<20 {
            fit(window)
            if controlViews(in: window).count == items.count { return }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    private static func currentState() -> PhoneControlsState? {
        guard let controller else { return nil }
        return PhoneControlsState(controller: controller)
    }

    /// The Deck's popover has no Settings/Quit footer; the menu bar panel does.
    private static func showsFooter(_ host: Host) -> Bool { host != .deck }

    /// The controls SwiftUI actually lays out and focuses: a disabled control
    /// has no key-view proxy, so the focusable order leaves it out. Dumps still
    /// report every item with its reason; mapping counts only enabled ones.
    private static func focusableItems(_ state: PhoneControlsState, host: Host) -> [PhonePanelItem] {
        PhonePanelItem.focusOrder(for: state, showsFooter: showsFooter(host))
            .filter { $0.isEnabled(in: state) }
    }

    private static func window(for host: Host) -> NSWindow? {
        switch host {
        case .panel:
            return hostWindow?.isVisible == true ? hostWindow : nil
        case .deck:
            // The popover is its own window above the Deck; take the visible
            // one that carries the panel's controls.
            let candidates = NSApp.windows.filter { $0.isVisible && $0 !== DeckWindow.window }
            return candidates.first { !controlViews(in: $0).isEmpty }
        case .real:
            // The status item's window: panel-sized, not our host, not the
            // Deck. (With the Deck popover also open, the frontmost wins.)
            return NSApp.windows.first {
                $0.isVisible && $0 !== hostWindow && $0 !== DeckWindow.window
                    && (280...400).contains($0.frame.width) && $0.frame.height >= 250
            }
        }
    }

    private static func control(for id: String, state: PhoneControlsState, host: Host,
                                in window: NSWindow) -> Control? {
        let controls = laidOut(in: window)
        // The volume's track is the only track-height control, so it is found
        // by shape even when a disabled row has no proxy.
        if id == PhonePanelItem.volume.id {
            return controls.first { $0.kind == .slider }
        }
        // The index mapping is only valid while every enabled item has a
        // control: a disabled control has no key-view proxy and is not there
        // to click anyway.
        let items = focusableItems(state, host: host)
        guard items.count == controls.count,
              let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return controls[index]
    }

    private static func label(_ item: PhonePanelItem, state: PhoneControlsState) -> String {
        switch item {
        case .ring: return state.ringTitle
        case .ringer: return state.ringerTitle
        case .screen: return state.screenTitle
        case .sessions: return state.pickerTitle
        case .installApk: return state.installTitle
        default: return item.label
        }
    }

    private static func enabled(_ item: PhonePanelItem, state: PhoneControlsState) -> Bool {
        item.isEnabled(in: state)
    }

    /// The window's laid-out controls, top to bottom: SwiftUI's key-view
    /// proxies plus the real AppKit controls it hosts (the DND switch, the Now
    /// Playing popup).
    private static func laidOut(in window: NSWindow) -> [Control] {
        controlViews(in: window)
            .map { view in
                // Window coordinates: the same space an NSEvent's location is
                // in, and the same one a top-down sort needs.
                let frame = view.convert(view.bounds, to: nil)
                let name = String(describing: type(of: view))
                let kind: Kind
                if view is NSSwitch {
                    kind = .switch
                } else if name.contains("PopupButton") {
                    kind = .popup
                } else if frame.height < 20 && frame.width > 150 {
                    kind = .slider
                } else {
                    kind = .button
                }
                return Control(frame: frame, kind: kind)
            }
            .sorted { $0.frame.maxY > $1.frame.maxY }
    }

    private static func controlFrames(in window: NSWindow) -> [CGRect] {
        laidOut(in: window).map(\.frame)
    }

    private static func controlViews(in window: NSWindow) -> [NSView] {
        guard let content = window.contentView else { return [] }
        var views: [NSView] = []
        collectControls(content, into: &views)
        return views
    }

    private static func switchView(in window: NSWindow) -> NSView? {
        controlViews(in: window).first { $0 is NSSwitch }
    }

    private static func collectControls(_ view: NSView, into views: inout [NSView]) {
        let name = String(describing: type(of: view))
        if name.contains("KeyViewProxy") || view is NSSwitch || name.contains("PopupButton") {
            views.append(view)
            // A popup's own subviews are not controls of their own.
            return
        }
        for child in view.subviews { collectControls(child, into: &views) }
    }

    // MARK: - Events

    private static func event(_ type: NSEvent.EventType, at point: CGPoint,
                              in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)
    }

    private static func send(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) {
        guard let event = event(type, at: point, in: window) else { return }
        window.sendEvent(event)
    }

    /// Hand the run loop back so the app dispatches what was posted and the
    /// phone's reply can land.
    private static func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }
}
