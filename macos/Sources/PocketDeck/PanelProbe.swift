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
        let items = PhonePanelItem.focusOrder(for: state)
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
            "battery": state.battery ?? -1,
            "reason": state.reason ?? "",
            "mapped": items.count == controls.count,
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
              let window = window(for: host), let target = control(for: id, state: state, in: window)
        else { return false }
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
              let window = window(for: host), let target = control(for: id, state: state, in: window)
        else { return false }
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

    private static func currentState() -> PhoneControlsState? {
        guard let controller else { return nil }
        return PhoneControlsState(controller: controller)
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

    private static func control(for id: String, state: PhoneControlsState,
                                in window: NSWindow) -> Control? {
        let controls = laidOut(in: window)
        // The AppKit shapes are unique, so they are found even when a disabled
        // row has no proxy: the switch is the DND row, the popup is the Now
        // Playing picker, and the only track-height control is the volume.
        if let item = PhonePanelItem(rawValue: id.replacingOccurrences(of: "panel.", with: "")) {
            switch item {
            case .dnd: return controls.first { $0.kind == .switch }
            case .volume: return controls.first { $0.kind == .slider }
            case .sessions: return controls.first { $0.kind == .popup }
            default: break
            }
        }
        let items = PhonePanelItem.focusOrder(for: state)
        // The index mapping is only valid while every item has a control (an
        // offline panel drops the disabled rows from the key loop).
        guard items.count == controls.count,
              let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return controls[index]
    }

    private static func label(_ item: PhonePanelItem, state: PhoneControlsState) -> String {
        switch item {
        case .ring: return state.ringTitle
        case .sessions: return state.pickerTitle
        case .installApk: return state.installTitle
        default: return item.label
        }
    }

    private static func enabled(_ item: PhonePanelItem, state: PhoneControlsState) -> Bool {
        switch item {
        case .volume: return state.volumeFraction != nil
        case .dnd: return state.connection.isOnline && state.dnd != nil
        case .ring, .phoneScreen, .continueOnMac: return state.connection.isOnline
        case .installApk: return state.connection.isOnline && !state.installBusy
        case .sessions, .live, .findApps, .settings, .quit, .disconnectAgent: return true
        }
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
