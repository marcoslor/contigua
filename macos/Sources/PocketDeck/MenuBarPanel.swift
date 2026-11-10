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

enum MenuBarPanelEvent: Equatable {
    /// The status item's own click (mouse-up).
    case iconClick
    /// A right-click or Control-click on the status item: the icon's menu.
    case iconSecondaryClick
    /// The card's gear: the same request as the secondary click, anchored to
    /// the gear's screen rect (a pull-down, not the item's menu).
    case gear(NSRect)
    /// A click anywhere that is not the panel or the status item.
    case clickOutside
    case escape
    /// A panel row that opens a window (the Deck, a phone mirror, Settings…).
    case openWindow
    /// The hide animation ended: the panel is off screen.
    case hideFinished

    /// The field log's code for the event (a closed set, never a payload).
    var eventCode: String {
        switch self {
        case .iconClick: "iconClick"
        case .iconSecondaryClick: "iconSecondaryClick"
        case .gear: "gear"
        case .clickOutside: "clickOutside"
        case .escape: "escape"
        case .openWindow: "openWindow"
        case .hideFinished: "hideFinished"
        }
    }
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
    /// Pop the status item's own menu up: under the item for its own click, or
    /// under the gear's rect (nil = the item) for the card's gear.
    case showMenu(anchor: NSRect?)
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
            return [.showMenu(anchor: nil)]
        case (.closed, .gear(let anchor)):
            // The gear with no panel: the menu still opens under the gear.
            return [.showMenu(anchor: anchor)]
        case (.open, .iconSecondaryClick):
            // A panel covers the menu's anchor, so it goes first — at once:
            // the menu's tracking loop would stall a fade's completion. The
            // menu is still what the person asked for.
            state = .closed
            return [.hideImmediately, .showMenu(anchor: nil)]
        case (.open, .gear(let anchor)):
            // The same request from the card's gear: the card hides at once
            // and the menu opens under the gear, where the person clicked.
            state = .closed
            return [.hideImmediately, .showMenu(anchor: anchor)]
        case (.closing, .iconSecondaryClick), (.closing, .gear):
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

/// Where the icon's menu opens. A status item's own menu is AppKit's to place
/// under the item; the card's gear asks for the same menu as a pull-down, so it
/// opens under the gear's button (ISS-75) instead of under the item.
enum MenuBarMenuAnchor {
    /// The menu's top-left corner for a pull-down from `button`: under the
    /// button's leading edge, moved left when the menu would leave `visible`,
    /// and never past the screen's margin. The menu's top touches the button's
    /// bottom, as a pop-up button's menu does.
    static func pullDownPoint(under button: NSRect, menuWidth: CGFloat,
                              in visible: NSRect) -> NSPoint {
        let margin: CGFloat = 8
        let x = min(button.minX, visible.maxX - max(menuWidth, 0) - margin)
        return NSPoint(x: max(x, visible.minX + margin), y: button.minY)
    }

    /// The gear's frame on screen. `host` is the card's hosting view inside the
    /// panel's content view (SwiftUI's top-left origin) and `panel` the panel's
    /// screen frame; the gear sits `gearTop` below the card's top edge, on its
    /// trailing inset (PhonePanelMetrics). One value, so the controller and the
    /// view cannot drift.
    static func gearRect(host: NSRect, panel: NSRect) -> NSRect {
        let size = PhonePanelMetrics.gearSize
        let x = host.minX + host.width - PhonePanelMetrics.inset - size
        let y = host.minY + host.height - PhonePanelMetrics.gearTop - size
        return NSRect(x: panel.minX + x, y: panel.minY + y, width: size, height: size)
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
    /// panel steps past it — and past any row between it and the opening focus
    /// (the agent row's Disconnect) — the number `openingFocusSteps` names.
    func focusFirstPhoneControl(steps: Int = 1) {
        for _ in 0..<max(steps, 1) {
            selectNextKeyView(nil)
        }
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
    private var pulse = MenuBarPulseMachine()
    private var pulseTimer: Timer?
    private var launchTask: Task<Void, Never>?
    private var panel: MenuBarPanel?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var defaultsObserver: NSObjectProtocol?

    init(controller: ConnectionController, defaults: UserDefaults) {
        self.controller = controller
        self.defaults = defaults
        // AppKit sizes the item around the button's own image. A fixed width
        // was the person's padding and pushed the glyph off-centre (2026-10-30).
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        Self.current = self
        installButton()
        installMonitors()
        applyVisibility()
        observeIcon()
        openDeckAtLaunch()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyVisibility() }
        }
    }

    deinit {
        pulseTimer?.invalidate()
        launchTask?.cancel()
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
        // The glyph is the button's own template image: AppKit centres it and
        // the menu bar dims it on an inactive display. Nothing is layered over
        // the button; the states it had (the reconnecting pulse, the agent dot)
        // are frames of that image.
        button.image = MenuBarGlyph.image(link: controller.link,
                                          dot: controller.mcp.clientCount > 0)
    }

    /// The image follows the link and the agent count through Observation, the
    /// same two reads the SwiftUI label made, re-armed after every change.
    private func observeIcon() {
        withObservationTracking {
            updateIcon(link: controller.link, dot: controller.mcp.clientCount > 0)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeIcon() }
        }
    }

    /// One link change: the pulse machine takes it (logging its transition),
    /// then the image is drawn in the frame the machine chose.
    private func updateIcon(link: Link, dot: Bool) {
        runPulse(pulse.handle(.pulses(Self.pulses(link))), event: .pulses, before: pulse.state)
        renderIcon(link: link, dot: dot)
    }

    @objc private func pulseTicked() {
        runPulse(pulse.handle(.tick), event: .tick, before: pulse.state)
    }

    /// Which event a field log line names (a closed set; the state's names are
    /// the log's values).
    private enum PulseLogEvent {
        case pulses
        case tick
    }

    private func runPulse(_ actions: [MenuBarPulseAction], event: PulseLogEvent,
                          before: MenuBarPulseState) {
        let after = pulse.state
        if after != before {
            switch event {
            case .pulses:
                Log.app.notice("menu bar icon: \(before.rawValue, privacy: .public) --pulses--> \(after.rawValue, privacy: .public)")
            case .tick:
                // Twice a second while reconnecting: debug only, so the
                // pulse does not fill the unified log.
                Log.app.debug("menu bar icon: \(before.rawValue, privacy: .public) --tick--> \(after.rawValue, privacy: .public)")
            }
        }
        for action in actions {
            switch action {
            case .show:
                renderIcon(link: controller.link, dot: controller.mcp.clientCount > 0)
            case .startTimer:
                pulseTimer = pulseTimer ?? Timer.scheduledTimer(
                    timeInterval: Self.pulseInterval, target: self,
                    selector: #selector(pulseTicked), userInfo: nil, repeats: true)
            case .stopTimer:
                pulseTimer?.invalidate()
                pulseTimer = nil
            }
        }
    }

    private func renderIcon(link: Link, dot: Bool) {
        let button = statusItem.button
        button?.image = MenuBarGlyph.image(link: link, dot: dot, dimmed: pulse.isDim)
        // The dot's meaning is part of the drawing now, so the item's label
        // carries it, as the dot view's own label did before.
        button?.setAccessibilityLabel(dot ? "PocketDeck, an AI agent is connected" : "PocketDeck")
    }

    private static let pulseInterval: TimeInterval = 0.55

    private static func pulses(_ link: Link) -> Bool {
        if case .reconnecting = link { return true }
        return false
    }

    /// The Deck's launch open, moved here from `MenuBarIcon`'s `.task` when the
    /// view went away: the item exists from launch, and started from a shell
    /// (the test harness) SwiftUI sometimes does not present the Deck by itself.
    private func openDeckAtLaunch() {
        launchTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            guard self != nil else { return }
            DeckWindow.open()
        }
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
        let size: String
        if let drawn = statusItem.button?.image {
            image = drawn.isTemplate ? "template" : "plain"
            size = "\(Int(drawn.size.width.rounded()))x\(Int(drawn.size.height.rounded()))"
        } else {
            image = "none"
            size = "0x0"
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
            + " state=\(state) dot=\(controller.mcp.clientCount > 0 ? 1 : 0) size=\(size)"
    }

    // MARK: Events

    private func handle(_ event: MenuBarPanelEvent) {
        let before = machine.state
        let actions = machine.handle(event)
        let next = machine.state
        if next != before {
            Log.app.notice("menu bar panel: \(before.rawValue, privacy: .public) --\(event.eventCode, privacy: .public)--> \(next.rawValue, privacy: .public)")
        }
        for action in actions {
            switch action {
            case .show: showPanel()
            case .hide: hidePanel()
            case .hideImmediately: hidePanelNow()
            case .showMenu(let anchor): openSecondaryMenu(anchor: anchor)
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

    /// Pop the icon's menu up. `anchor` is the control that asked, in screen
    /// points: the card's gear passes its own frame, so the menu opens under
    /// the gear like a pull-down. Nil is the status item's own click, which
    /// AppKit anchors under the item. The item's `menu` is set only for that
    /// pop-up, so the button's action stays the panel's toggle the rest of the
    /// time.
    func openSecondaryMenu(anchor: NSRect? = nil) {
        let menu = secondaryMenu()
        if let anchor {
            let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? .zero
            holdGearMenuIfAsked(menu)
            menu.popUp(positioning: nil,
                       at: MenuBarMenuAnchor.pullDownPoint(under: anchor,
                                                          menuWidth: menu.size.width,
                                                          in: visible),
                       in: nil)
            return
        }
        guard let button = statusItem.button else { return }
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    /// How long the gear's menu stays open in a quiet e2e run (`gearhold`): the
    /// run cannot press Escape, so the menu closes itself. 0 in a person's run.
    private var gearMenuHold: TimeInterval = 0

    func holdGearMenu(seconds: TimeInterval) {
        gearMenuHold = seconds
    }

    private func holdGearMenuIfAsked(_ menu: NSMenu) {
        let seconds = gearMenuHold
        gearMenuHold = 0
        guard seconds > 0 else { return }
        // The menu's tracking loop runs in .eventTracking; a timer in that mode
        // (and the common modes) fires inside it and ends the loop.
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            menu.cancelTracking()
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The gear's frame on screen: the card's hosting view inside the panel's
    /// content view, at the panel's own frame. Nil while the card is not up.
    private func gearScreenRect() -> NSRect? {
        guard let panel, let host = panel.contentView?.subviews.first else { return nil }
        return MenuBarMenuAnchor.gearRect(host: host.frame, panel: panel.frame)
    }

    /// The gear asks for the icon's menu the way the right-click does, but the
    /// menu anchors at the gear (PANEL-3).
    private func gearClicked() {
        if let rect = gearScreenRect() {
            handle(.gear(rect))
        } else {
            handle(.iconSecondaryClick)
        }
    }

    /// `gearanchor` (e2e): the frame the card's gear anchors its menu to, as
    /// the controller pops it. Without a card the item's own menu still opens
    /// under the item.
    func menuAnchorDescription() -> String {
        if let rect = gearScreenRect() {
            return "gear \(Int(rect.minX)) \(Int(rect.minY)) \(Int(rect.width)) \(Int(rect.height))"
        }
        guard let button = statusItem.button else { return "none" }
        let frame = buttonFrame(button)
        return "statusitem \(Int(frame.minX)) \(Int(frame.minY)) \(Int(frame.width)) \(Int(frame.height))"
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
            // The gear is the same request as the right-click, anchored to the
            // gear's own button (PANEL-3).
            self?.gearClicked()
        }, onSizeChange: { [weak self] height in
            // A foreground row or a live row arrived/left: keep the card's top
            // under the item and follow the new height (PANEL-4).
            self?.panelContentHeightChanged(height)
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
        controller.beginPanelFrontWatch()
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.focusFirstPhoneControl(steps: PhonePanelItem.openingFocusSteps(
            for: PhoneControlsState(controller: controller)))
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
                self.controller.endPanelFrontWatch()
                self.handle(.hideFinished)
            }
        })
    }

    /// The secondary click's close: no fade, so the panel is off screen before
    /// the menu takes the run loop (a fade's completion would wait for it).
    private func hidePanelNow() {
        panel?.orderOut(nil)
        panel?.alphaValue = 1
        controller.endPanelFrontWatch()
    }

    /// PANEL-4: the card grew or shrank while open. Keep its top edge under
    /// the status item at the new height, at once (PANEL-29), clamped to the visible
    /// frame's bottom edge.
    private func panelContentHeightChanged(_ height: CGFloat) {
        guard let panel, panel.isVisible else { return }
        let size = NSSize(width: panel.frame.width, height: height + 20)
        guard abs(size.height - panel.frame.height) > 0.5 else { return }
        var frame = panel.frame
        let top = frame.maxY
        frame.size = size
        frame.origin.y = top - size.height
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: frame.midX, y: top)) })
            ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.origin.x, visible.minX + 8),
                                 visible.maxX - size.width - 8)
            // The card is short enough for any screen; the clamp only keeps a
            // future taller one from crossing the Dock.
            frame.origin.y = max(frame.origin.y, visible.minY + 8)
        }
        // PANEL-29: at once, with the content (no 0.12 s slide of the rows
        // under a row that came or went).
        panel.setFrame(frame, display: true)
    }
}
