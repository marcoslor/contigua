// The panel's debug host and control driver for the host e2e. A quiet run
// cannot open a MenuBarExtra's status item (that is the window server's), so
// `panelopen` shows the menu bar's exact content in a plain window; the Deck
// popover opens through its own state. Both then drive the real SwiftUI
// controls: a click or drag goes to the window's hit-tested view, the same
// path a person's pointer takes, and the phone counts the effect.
//
// SwiftUI keeps its controls inside one hosting view, so the controls are
// found by the hosting view's key-view proxies, which follow the panel's
// focus order (PhonePanelItem.focusOrder). A check that a click landed is the
// phone receiving `phone.dnd` / `media.command`, not the action being called.

import AppKit
import SwiftUI

@MainActor
enum PanelProbe {
    enum Host: String {
        case panel
        case deck
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
    static func openDeckPopover() {
        controller?.openDeckPanel()
    }

    /// `paneldump HOST PATH`: the panel's model rows and the real controls the
    /// hosting view laid out, as JSON.
    static func dump(host: String, to path: String) -> Bool {
        guard let host = Host(rawValue: host) else { return false }
        guard let state = currentState() else { return false }
        guard let window = window(for: host) else { return false }
        let proxies = proxyFrames(in: window)
        let rows: [[String: Any]] = PhonePanelItem.focusOrder(for: state).map { item in
            var row: [String: Any] = [
                "id": item.id,
                "kind": item.rawValue,
                "label": label(item, state: state),
                "enabled": enabled(item, state: state),
            ]
            if let index = PhonePanelItem.focusOrder(for: state).firstIndex(of: item) { row["index"] = index }
            return row
        }
        let frames: [[String: Any]] = proxies.enumerated().map { index, frame in
            ["index": index, "x": frame.minX, "y": frame.minY,
             "width": frame.width, "height": frame.height]
        }
        let root: [String: Any] = [
            "width": PhonePanelView.width,
            "phone": state.phoneName,
            "status": state.connection.text,
            "battery": state.battery ?? -1,
            "reason": state.reason ?? "",
            "items": rows,
            "controls": frames,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else {
            return false
        }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// `panelclick HOST ID`: a click at the control's own frame, through the
    /// window's event dispatch.
    static func click(host: String, id: String) -> Bool {
        guard let host = Host(rawValue: host), let state = currentState(),
              let window = window(for: host), let index = index(of: id, in: state) else { return false }
        guard let frame = proxyFrames(in: window).dropFirst(index).first else { return false }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        send(.leftMouseDown, at: point, in: window)
        send(.leftMouseUp, at: point, in: window)
        pump()
        return true
    }

    /// `paneldrag HOST ID FRACTION`: the volume slider, from its current knob
    /// to the fraction of the track.
    static func drag(host: String, id: String, fraction: Double) -> Bool {
        guard let host = Host(rawValue: host), let state = currentState(),
              let window = window(for: host), let index = index(of: id, in: state) else { return false }
        guard let frame = proxyFrames(in: window).dropFirst(index).first else { return false }
        let clamped = min(max(fraction, 0), 1)
        let startFraction = state.volumeFraction ?? 0.2
        let start = CGPoint(x: frame.minX + frame.width * startFraction, y: frame.midY)
        let end = CGPoint(x: frame.minX + frame.width * clamped, y: frame.midY)
        send(.leftMouseDown, at: start, in: window)
        for step in 1...10 {
            let t = Double(step) / 10
            send(.leftMouseDragged,
                 at: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y), in: window)
            pump()
        }
        send(.leftMouseUp, at: end, in: window)
        pump()
        return true
    }

    // MARK: - Lookup

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
            // one that carries the panel's key views.
            let candidates = NSApp.windows.filter { $0.isVisible && $0 !== DeckWindow.window }
            return candidates.first { !proxyFrames(in: $0).isEmpty }
        }
    }

    private static func index(of id: String, in state: PhoneControlsState) -> Int? {
        PhonePanelItem.focusOrder(for: state).firstIndex { $0.id == id }
    }

    private static func label(_ item: PhonePanelItem, state: PhoneControlsState) -> String {
        switch item {
        case .ring: return state.ringTitle
        case .sessions: return state.pickerTitle
        case .installApk: return state.installTitle
        case .live: return PhonePanelItem.live.label
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

    /// The hosting view's key-view proxies, top to bottom in the window: one
    /// per focusable control, in the panel's focus order.
    private static func proxyFrames(in window: NSWindow) -> [CGRect] {
        guard let content = window.contentView else { return [] }
        var proxies: [NSView] = []
        collectProxies(content, into: &proxies)
        return proxies
            .map { $0.convert($0.bounds, to: content) }
            .sorted { $0.maxY > $1.maxY }
    }

    private static func collectProxies(_ view: NSView, into proxies: inout [NSView]) {
        if String(describing: type(of: view)).contains("KeyViewProxy") { proxies.append(view) }
        for child in view.subviews { collectProxies(child, into: &proxies) }
    }

    // MARK: - Events

    private static func send(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) {
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1,
        ) else { return }
        window.sendEvent(event)
    }

    private static func pump() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}
