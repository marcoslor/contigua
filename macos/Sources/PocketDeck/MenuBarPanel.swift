// The menu bar item and its panel, owned in AppKit.
//
// SwiftUI's `MenuBarExtra(.window)` closes its panel when the status item takes
// key on mouse-down and then opens it again on mouse-up, so a second click on
// the icon never closed the panel (the person's report, 2026-10-22). An
// `NSStatusItem` and an `NSPanel` give the click one owner: the icon's action
// toggles, and the panel is never closed by losing key.
//
// The panel's modes are one state machine (AGENTS "State machines"): Closed,
// Open and Closing, with the icon click, a click outside, Esc and an action
// that opens a window. Only the returned actions touch windows.
//
// The person's second ask (2026-10-27): Settings… and Quit move to a
// right-click menu on the icon. That is a prototype behind `--debug-proto
// panelmenu=M1|M2|M3` (PanelMenuPrototype.swift), and its own event,
// `iconSecondaryClick`; without the flag a right-click still toggles the panel.

import AppKit
import SwiftUI

// MARK: - The machine

enum MenuBarPanelState: String, Equatable {
    case closed
    case open
    case closing
}

enum MenuBarPanelEvent: String, Equatable {
    /// The status item's own click (mouse-up).
    case iconClick
    /// A right-click or Control-click on the status item: the prototype's
    /// menu under the icon (PanelMenuPrototype.swift).
    case iconSecondaryClick
    /// A click anywhere that is not the panel or the status item.
    case clickOutside
    case escape
    /// A panel row that opens a window (the Deck, a phone mirror, Settings…).
    case openWindow
    /// The hide animation ended: the panel is off screen.
    case hideFinished
}

enum MenuBarPanelAction: Equatable {
    case show
    case hide
    /// Take the panel off screen with no fade: the menu is about to track, and
    /// its loop would stall the animation's completion, leaving an invisible
    /// window on screen. A menu bar menu closes its panel at once anyway.
    case hideImmediately
    /// Pop the status item's own menu up under the icon.
    case showMenu
}

struct MenuBarPanelMachine {
    private(set) var state: MenuBarPanelState = .closed

    /// One pure transition: the new state and the actions to run.
    mutating func handle(_ event: MenuBarPanelEvent) -> [MenuBarPanelAction] {
        switch (state, event) {
        case (.closed, .iconClick):
            state = .open
            return [.show]
        case (.open, .iconClick):
            // The reported bug: the second click must close, not reopen.
            state = .closing
            return [.hide]
        case (.closing, .iconClick):
            // Already going away; a click must not bring it back (the same
            // click that closed it is still in flight on some systems).
            return []
        case (.closed, .iconSecondaryClick):
            // No panel to close: the menu opens on its own.
            return [.showMenu]
        case (.open, .iconSecondaryClick):
            // A panel covers the menu's anchor, so it goes first — at once:
            // the menu's tracking loop would stall a fade's completion. The
            // menu is still what the person asked for.
            state = .closed
            return [.hideImmediately, .showMenu]
        case (.closing, .iconSecondaryClick):
            // The panel is already leaving; a second menu must not stack.
            return []
        case (.open, .clickOutside), (.open, .escape), (.open, .openWindow):
            state = .closing
            return [.hide]
        case (.closing, .hideFinished):
            state = .closed
            return []
        case (.closed, .clickOutside), (.closed, .escape), (.closed, .openWindow),
             (.closed, .hideFinished),
             (.closing, .clickOutside), (.closing, .escape), (.closing, .openWindow),
             (.open, .hideFinished):
            return []
        }
    }
}

// MARK: - The panel

/// The panel window: a borderless, non-activating card that still takes the
/// keyboard (so Esc and the panel's own controls work without activating the
/// app — the person is usually in another app when they use it).
final class MenuBarPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - The controller

@MainActor
final class MenuBarController: NSObject {
    /// The Settings toggle this item follows; the same key the app's
    /// `@AppStorage("showMenuBar")` writes.
    static let showMenuBarKey = "showMenuBar"

    private let controller: ConnectionController
    private let defaults: UserDefaults
    private let statusItem: NSStatusItem
    private var machine = MenuBarPanelMachine()
    private var panel: MenuBarPanel?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var defaultsObserver: NSObjectProtocol?

    init(controller: ConnectionController, defaults: UserDefaults) {
        self.controller = controller
        self.defaults = defaults
        statusItem = NSStatusBar.system.statusItem(withLength: 30)
        super.init()
        installButton()
        installMonitors()
        applyVisibility()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyVisibility() }
        }
    }

    deinit {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    var isInserted: Bool { statusItem.isVisible }

    /// The visibility the person chose in Settings ▸ General.
    private func applyVisibility() {
        let wanted = defaults.object(forKey: Self.showMenuBarKey) as? Bool ?? true
        if statusItem.isVisible != wanted {
            statusItem.isVisible = wanted
            if !wanted { handle(.clickOutside) }
        }
    }

    private func installButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(iconClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "PocketDeck"
        // The icon keeps the states the SwiftUI label had, including the pulse
        // while reconnecting and the dot while an agent is connected.
        let host = NSHostingView(rootView: MenuBarIcon().environment(controller))
        host.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            host.topAnchor.constraint(equalTo: button.topAnchor),
            host.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
    }

    @objc private func iconClicked(_ sender: Any?) {
        // The prototype gives the secondary click its own event (a right-click,
        // or Control-click, which arrives as a left click carrying ⌃). Without
        // the flag both clicks stay the panel's toggle, as they are today.
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if secondary, PanelMenuPrototype.current != nil {
            handle(.iconSecondaryClick)
        } else {
            handle(.iconClick)
        }
    }

    // MARK: Events

    private func handle(_ event: MenuBarPanelEvent) {
        let before = machine.state
        let actions = machine.handle(event)
        let next = machine.state
        if next != before {
            Log.app.notice("menu bar panel: \(before.rawValue, privacy: .public) --\(event.rawValue, privacy: .public)--> \(next.rawValue, privacy: .public)")
        }
        for action in actions {
            switch action {
            case .show: showPanel()
            case .hide: hidePanel()
            case .hideImmediately: hidePanelNow()
            case .showMenu: showSecondaryMenu()
            }
        }
    }

    // MARK: The secondary-click menu

    /// The status item's own menu: Settings…, About, Quit. The item's `menu` is
    /// set only for the pop-up, so the button's action stays the panel's
    /// toggle the rest of the time. The icon's secondary click and the M2 gear
    /// both reach it through the machine's `.showMenu` action.
    private func showSecondaryMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item("Settings…", #selector(openSettingsFromMenu(_:)), key: ","))
        menu.addItem(item("About PocketDeck", #selector(showAboutFromMenu(_:)), key: ""))
        menu.addItem(.separator())
        menu.addItem(item("Quit PocketDeck", #selector(quitFromMenu(_:)), key: "q"))
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openSettingsFromMenu(_ sender: Any?) {
        // The panel closes as it does after a footer row: the window is what
        // the person asked for, and a panel left behind it would be stale.
        handle(.openWindow)
        controller.openSettingsWindow()
    }

    @objc private func showAboutFromMenu(_ sender: Any?) {
        handle(.openWindow)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quitFromMenu(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    /// A click in another app: close. Clicks in this app's own windows arrive
    /// in the local monitor instead.
    private func installMonitors() {
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            MainActor.assumeIsolated { self?.localMouseDown(event) }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The status item's window belongs to the menu bar, so its
                // click also reaches the global monitor: it is the icon's
                // toggle, not a click outside.
                if self.isStatusItemClick(NSEvent.mouseLocation) { return }
                self.handle(.clickOutside)
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if MainActor.assumeIsolated({ self.machine.state == .open && event.keyCode == 53 }) {
                MainActor.assumeIsolated { self.handle(.escape) }
                return nil
            }
            return event
        }
    }

    private func localMouseDown(_ event: NSEvent) {
        guard machine.state == .open else { return }
        if let panel, event.window === panel { return }
        // The status item's own click toggles: it is never "outside". Its
        // window number or its frame may be what the event carries.
        if let button = statusItem.button, let buttonWindow = button.window,
           event.windowNumber == buttonWindow.windowNumber {
            return
        }
        if isStatusItemClick(NSEvent.mouseLocation) { return }
        handle(.clickOutside)
    }

    /// A little slack around the item: the click's location is rounded to
    /// points and the icon is small.
    private func isStatusItemClick(_ point: NSPoint) -> Bool {
        guard let button = statusItem.button else { return false }
        let frame = buttonFrame(button)
        return !frame.isEmpty && frame.insetBy(dx: -6, dy: -6).contains(point)
    }

    private func buttonFrame(_ button: NSStatusBarButton) -> NSRect {
        guard let window = button.window else { return .zero }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    // MARK: The panel window

    private func makePanel() -> MenuBarPanel {
        if let panel { return panel }
        let panel = MenuBarPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // The controls' hover highlights follow the pointer over a non-activating panel.
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onEscape = { [weak self] in self?.handle(.escape) }
        self.panel = panel
        return panel
    }

    private func showPanel() {
        guard let button = statusItem.button, button.window != nil else {
            // The item is hidden (the Settings toggle went off in the same
            // turn): there is nothing to anchor the panel to.
            handle(.clickOutside)
            return
        }
        let panel = makePanel()
        let host = NSHostingView(rootView: MenuBarContent(onOpenWindow: { [weak self] in
            self?.handle(.openWindow)
        }, onSecondaryMenu: { [weak self] in
            // The gear is the same request as the right-click: the machine
            // closes the panel first, then the one menu opens under the icon.
            self?.handle(.iconSecondaryClick)
        }).environment(controller))
        host.layoutSubtreeIfNeeded()
        let content = host.fittingSize
        let inset: CGFloat = 10
        let size = NSSize(width: content.width + inset * 2, height: content.height + inset * 2)
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: inset),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -inset),
            host.topAnchor.constraint(equalTo: effect.topAnchor, constant: inset),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -inset),
        ])
        panel.contentView = effect
        panel.setContentSize(size)
        let anchor = buttonFrame(button)
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 6)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = max(origin.y, visible.minY + 8)
        }
        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func hidePanel() {
        guard let panel else {
            handle(.hideFinished)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panel?.orderOut(nil)
                self.panel?.alphaValue = 1
                self.handle(.hideFinished)
            }
        })
    }

    /// The secondary click's close: no fade, so the panel is off screen before
    /// the menu takes the run loop (a fade's completion would wait for it).
    private func hidePanelNow() {
        panel?.orderOut(nil)
        panel?.alphaValue = 1
    }
}
