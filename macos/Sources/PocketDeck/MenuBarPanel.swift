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
// Settings… and Quit live in the icon's own secondary-click menu (the person
// picked this on 2026-10-27): a right-click or Control-click opens it, and so
// does the panel's gear. The panel's footer rows are gone, so the card is the
// phone's controls only.

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
    /// A right-click or Control-click on the status item: the icon's menu.
    case iconSecondaryClick
    /// A click anywhere that is not the panel or the status item.
    case clickOutside
    case escape
    /// A panel row that opens a window (the Deck, a phone mirror, Settings…).
    case openWindow
    /// The hide animation ended: the panel is off screen.
    case hideFinished
}

/// Which click the status item received. Control-click arrives as a left click
/// carrying ⌃, so it is the same request as a right-click; a plain left click
/// is the panel's toggle.
enum MenuBarPanelClick: Equatable {
    case primary
    case secondary

    static func of(type: NSEvent.EventType?, modifiers: NSEvent.ModifierFlags) -> MenuBarPanelClick {
        type == .rightMouseUp || modifiers.contains(.control) ? .secondary : .primary
    }
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

/// The icon's own menu (CONV-MAC-10): the commands the panel's footer used to
/// carry. Settings… ⌘, and Quit PocketDeck ⌘Q are the app menu's keys too, so
/// they are recognisable here; About sits between them, as Apple's extras do.
enum MenuBarMenu {
    static let settingsTitle = "Settings…"
    static let aboutTitle = "About PocketDeck"
    static let quitTitle = "Quit PocketDeck"

    static func make(target: AnyObject) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item(settingsTitle, action: #selector(MenuBarController.openSettingsFromMenu(_:)),
                          key: ",", target: target))
        menu.addItem(item(aboutTitle, action: #selector(MenuBarController.showAboutFromMenu(_:)),
                          key: "", target: target))
        menu.addItem(.separator())
        menu.addItem(item(quitTitle, action: #selector(MenuBarController.quitFromMenu(_:)),
                          key: "q", target: target))
        return menu
    }

    private static func item(_ title: String, action: Selector, key: String,
                             target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }
}

// MARK: - The panel

/// The panel window: a borderless, non-activating card that still takes the
/// keyboard (so Esc and the panel's own controls work without activating the
/// app — the person is usually in another app when they use it).
final class MenuBarPanel: NSPanel {
    var onEscape: (() -> Void)?

    /// The card opens with its ring on the first phone control. The gear heads
    /// the card's key order (it is the header's top-right control), so the
    /// panel steps past it once: DND, or the agent row's Disconnect.
    func focusFirstPhoneControl() {
        selectNextKeyView(nil)
    }

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
        Self.current = self
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
        let event = NSApp.currentEvent
        let click = MenuBarPanelClick.of(type: event?.type,
                                         modifiers: event?.modifierFlags ?? [])
        handle(click == .secondary ? .iconSecondaryClick : .iconClick)
    }

    /// `menubaricon` (e2e `menubar-shots`, PANEL-25): the item as AppKit has
    /// it — the length, whether the drawing is the button's own template image,
    /// and foreign views over the button.
    func iconDescription() -> String {
        let length = statusItem.length == NSStatusItem.variableLength
            ? "variable" : "\(Int(statusItem.length))"
        let image: String
        if let drawn = statusItem.button?.image {
            image = drawn.isTemplate ? "template" : "plain"
        } else {
            image = "none"
        }
        let state: String
        switch controller.link {
        case .idle: state = "idle"
        case .connecting: state = "connecting"
        case .online: state = "online"
        case .reconnecting: state = "reconnecting"
        case .offline: state = "offline"
        case .needsPairing: state = "needsPairing"
        case .pairing: state = "pairing"
        }
        return "length=\(length) image=\(image) subviews=\(statusItem.button?.subviews.count ?? 0)"
            + " state=\(state) dot=\(controller.mcp.clientCount > 0 ? 1 : 0)"
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
            case .showMenu: openSecondaryMenu()
            }
        }
    }

    // MARK: The secondary-click menu

    /// The app's one status item: the probe's hosted panel opens the same menu
    /// through it (one item per thing, CONV-MAC-11).
    static weak var current: MenuBarController?

    /// The icon's menu: the three app commands the panel's footer used to
    /// carry. One builder serves the pop-up and the e2e's dump, so the menu a
    /// check reads is the menu a person gets.
    func secondaryMenu() -> NSMenu { MenuBarMenu.make(target: self) }

    /// Pop the icon's menu up under the status item. The item's `menu` is set
    /// only for the pop-up, so the button's action stays the panel's toggle the
    /// rest of the time. The icon's secondary click and the panel's gear both
    /// come through the machine's `.showMenu` action and land here.
    func openSecondaryMenu() {
        guard let button = statusItem.button else { return }
        statusItem.menu = secondaryMenu()
        button.performClick(nil)
        statusItem.menu = nil
    }

    /// `iconmenu PATH` (e2e `menus`): what the builder would pop, as JSON,
    /// without showing it — a quiet run has no screen to pop it on.
    func dumpSecondaryMenu(to path: String) -> Bool {
        let rows: [[String: Any]] = secondaryMenu().items.map { item in
            [
                "title": item.isSeparatorItem ? "-" : item.title,
                "key": item.keyEquivalent,
                "command": item.keyEquivalentModifierMask.contains(.command),
                "separator": item.isSeparatorItem,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]) else {
            return false
        }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    @objc fileprivate func openSettingsFromMenu(_ sender: Any?) {
        // The panel closes as it does after a footer row: the window is what
        // the person asked for, and a panel left behind it would be stale.
        handle(.openWindow)
        controller.openSettingsWindow()
    }

    @objc fileprivate func showAboutFromMenu(_ sender: Any?) {
        handle(.openWindow)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc fileprivate func quitFromMenu(_ sender: Any?) {
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
            // closes the panel first, then the menu opens under the icon.
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
        panel.focusFirstPhoneControl()
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
