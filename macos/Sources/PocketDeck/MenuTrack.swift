// `menutrack PATH MENU SECONDS` (e2e `menus`): holds one of the app's real
// menus open and reports what happened while it was up.
//
// The person's 10-27 report — a submenu that kept appearing and disappearing
// while they hovered it — happens when SwiftUI rebuilds the commands' NSMenu
// items underneath an open menu. The measurement here is what a rebuild looks
// like: how many times the commands body was evaluated while a menu tracked,
// and whether the menu's own item and submenu objects are still the ones the
// bar held when it opened.
//
// The menu is opened with `NSMenu.popUp`, which is the same tracking loop a
// click runs; it is not AX's `AXPress` on the menu bar item because that
// activates a background app and takes the person's keyboard for the length of
// the run (the quiet rule in .agent/_common.md). Nothing moves the pointer
// unless the caller names an item to hover (WIN-27's shots): then the menu is
// positioned so that item's corner is known, the check puts the real pointer
// there, and the report says which item the tracking loop highlighted.

import AppKit
import ApplicationServices

@MainActor
enum MenuTrack {
    private static var running = false
    private static var path = ""
    private static var itemPath = ""
    private static var seconds: TimeInterval = 0
    private static var buildsBefore = 0
    private static var itemsBefore: [ObjectIdentifier] = []
    private static var submenuBefore: ObjectIdentifier?
    private static var opened = false
    private static var openedSubmenu = false
    private static var stateChanges = 0
    private static var trackingPaths: Set<String> = []
    private static var hoverTitle = ""
    private static var hoverPointSource = ""
    private static var hoverPointText = ""
    private static var timers: [Timer] = []
    private static var observers: [NSObjectProtocol] = []

    /// Starts one tracked session. Returns why it could not start, else nil.
    /// `hover` names an item of `itemPath`'s menu whose help tag the caller
    /// wants on screen: the menu is positioned so that item's own corner sits
    /// at a known point, and `hoverPath` receives that point in Quartz
    /// coordinates for the caller's real pointer move.
    static func start(path resultPath: String, itemPath: String, seconds wait: TimeInterval,
                      hover: String? = nil, hoverPath: String? = nil) -> String? {
        guard !running else { return "a menu track is already running" }
        guard wait > 0, wait <= 10 else { return "menutrack needs 0 < SECONDS <= 10" }
        let item = resolve(itemPath: itemPath)
        guard let item else { return "menutrack: no menu item at \(itemPath)" }
        guard let submenu = item.submenu else { return "menutrack: \(itemPath) has no submenu" }
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }),
              let view = window.contentView else { return "menutrack: no window to show a menu over" }
        let hoverItem: NSMenuItem?
        if let hover {
            guard let found = submenu.items.first(where: { !$0.isSeparatorItem && $0.title == hover }) else {
                return "menutrack: no item '\(hover)' in \(itemPath)"
            }
            hoverItem = found
        } else {
            hoverItem = nil
        }

        running = true
        path = resultPath
        MenuTrack.itemPath = itemPath
        MenuTrack.hoverTitle = hoverItem?.title ?? ""
        hoverPointSource = ""
        hoverPointText = ""
        seconds = wait
        buildsBefore = Menus.builds
        itemsBefore = identities(in: NSApp.mainMenu)
        submenuBefore = item.submenu.map(ObjectIdentifier.init)
        opened = false
        openedSubmenu = false
        stateChanges = 0
        trackingPaths = []
        // The item's own top-left corner lands at this point (popUp's
        // positioning-item rule), so the caller can put the pointer inside the
        // item without guessing a menu's layout.
        let anchor = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        observe()

        // The menu must be opened from the run loop, not from this command: the
        // command's own reply has to reach the check before the main thread
        // enters the tracking loop.
        schedule(after: 0.4) {
            opened = true
            if let hoverItem {
                submenu.popUp(positioning: hoverItem, at: anchor, in: view)
            } else {
                submenu.popUp(positioning: nil,
                              at: NSPoint(x: 40, y: max(40, (view.bounds.height) - 40)),
                              in: view)
            }
            // The tracking loop ended (a click, Escape or the close timer).
            // Write now if the report timer never ran: the next step must never
            // be refused as "a menu track is already running" (the VM's sleep
            // wedge, round 3).
            if running { write() }
        }
        if hoverItem != nil, let hoverPath {
            schedule(after: 1.0) {
                let point = pointerPoint(window: window, view: view, anchor: anchor,
                                         menu: itemPath, item: hoverTitle)
                let line = "\(point.x) \(point.y)\n"
                try? line.write(toFile: hoverPath, atomically: true, encoding: .utf8)
            }
        }
        schedule(after: 0.4 + wait) {
            openedSubmenu = trackingPaths.contains(itemPath)
            // write() invalidates every scheduled timer, so the close must run
            // in this same closure: the round-3 split pair had the write timer
            // invalidate the cancel timer before it fired, and the menu stayed
            // tracking into the next step.
            write()
            submenu.cancelTracking()
            NSApp.mainMenu?.cancelTracking()
        }
        return nil
    }

    /// The check's state changes while the menu is up (`menu-burst`): the report
    /// says how many it really made, so a run where nothing changed cannot pass
    /// by having nothing to rebuild.
    static func noteStateChange() {
        guard running else { return }
        stateChanges += 1
    }

    private static func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { work() }
        }
        RunLoop.main.add(timer, forMode: .common)
        // A menu's own tracking loop runs in the event-tracking mode; a mode
        // that forgot to inherit common modes would never fire the close and
        // would leave the app's main thread inside NSMenu (round 3's wedge).
        RunLoop.main.add(timer, forMode: .eventTracking)
        timers.append(timer)
    }

    // MARK: - Tracking notifications

    private static func observe() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                            object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard running, let menu = note.object as? NSMenu else { return }
                trackingPaths.insert(path(of: menu) ?? menu.title)
            }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification,
                                            object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard running, let menu = note.object as? NSMenu else { return }
                trackingPaths.remove(path(of: menu) ?? menu.title)
            }
        })
    }

    // MARK: - Reading the bar

    /// The point the check moves the real pointer to: the hovered item's own
    /// centre from the open menu's Accessibility frame. AppKit may move a menu
    /// that would not fit at the requested anchor, so the anchor (the item's
    /// corner plus a little in and down) is only the fallback.
    private static func pointerPoint(window: NSWindow, view: NSView, anchor: NSPoint,
                                     menu itemPath: String, item: String) -> NSPoint {
        if let frame = axItemFrame(menu: itemPath, item: item) {
            hoverPointSource = "ax"
            hoverPointText = "\(frame.midX) \(frame.midY)"
            return NSPoint(x: frame.midX, y: frame.midY)
        }
        let inWindow = view.convert(anchor, to: nil)
        let screen = window.convertPoint(toScreen: inWindow)
        let top = window.screen?.frame.maxY ?? NSScreen.screens.first?.frame.maxY ?? 0
        let point = NSPoint(x: screen.x + 40, y: top - (screen.y - 11))
        hoverPointSource = "anchor"
        hoverPointText = "\(point.x) \(point.y)"
        return point
    }

    /// The menu item's frame while the menu is open. The bar's Accessibility
    /// tree is the one MenuDump already reads; a menu item carries its screen
    /// frame only while it is displayed.
    private static func axItemFrame(menu itemPath: String, item: String) -> NSRect? {
        let menuTitle = itemPath.split(separator: "/").first.map(String.init) ?? itemPath
        let app = AXUIElementCreateApplication(getpid())
        guard let bar = axElement(app, kAXMenuBarAttribute as String) else { return nil }
        for barItem in axChildren(bar) where axString(barItem, kAXTitleAttribute as String) == menuTitle {
            guard let menu = axChildren(barItem).first else { continue }
            for element in axChildren(menu) where axString(element, kAXTitleAttribute as String) == item {
                guard let frame = axFrame(element) else { continue }
                return frame
            }
        }
        return nil
    }

    private static func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    private static func axFrame(_ element: AXUIElement) -> NSRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &origin) else { return nil }
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 1, size.height > 1 else { return nil }
        return NSRect(origin: origin, size: size)
    }

    private static func resolve(itemPath: String) -> NSMenuItem? {
        var items = NSApp.mainMenu?.items ?? []
        var found: NSMenuItem?
        for title in itemPath.split(separator: "/").map(String.init) {
            guard let item = items.first(where: { $0.title == title }) else { return nil }
            found = item
            items = item.submenu?.items ?? []
        }
        return found
    }

    /// "View/Density": where the menu hangs in the bar, for the report.
    private static func path(of menu: NSMenu) -> String? {
        var stack: [(String, NSMenu)] = []
        guard let root = NSApp.mainMenu else { return nil }
        for item in root.items {
            if let submenu = item.submenu { stack.append((item.title, submenu)) }
        }
        while let (name, candidate) = stack.popLast() {
            if candidate === menu { return name }
            for item in candidate.items {
                if let submenu = item.submenu { stack.append((name + "/" + item.title, submenu)) }
            }
        }
        return nil
    }

    /// Every item in the bar, by object identity: a rebuild replaces these.
    private static func identities(in menu: NSMenu?) -> [ObjectIdentifier] {
        guard let menu else { return [] }
        var result: [ObjectIdentifier] = []
        for item in menu.items {
            result.append(ObjectIdentifier(item))
            if let submenu = item.submenu { result += identities(in: submenu) }
        }
        return result
    }

    // MARK: - The report

    private static func write() {
        let item = resolve(itemPath: MenuTrack.itemPath)
        let hover = hoverTitle.isEmpty ? nil
            : item?.submenu?.items.first(where: { $0.title == hoverTitle })
        let now = identities(in: NSApp.mainMenu)
        let report: [String: Any] = [
            "opened": opened,
            "seconds": seconds,
            "state_changes": stateChanges,
            "builds_during": Menus.builds - buildsBefore,
            "items_changed": now != itemsBefore,
            "item_count_before": itemsBefore.count,
            "item_count_after": now.count,
            "submenu_same_object": item?.submenu.map(ObjectIdentifier.init) == submenuBefore,
            "submenu_opened": openedSubmenu || trackingPaths.contains(MenuTrack.itemPath),
            "tracking_at_end": trackingPaths.sorted(),
            // The item the open menu had under the pointer when the report was
            // written: the caller's pointer move landed on the hovered item.
            "highlighted_item": item?.submenu?.highlightedItem?.title ?? "",
            // The sentence the hovered item carries as its help tag (WIN-27),
            // for the shot's sidecar report: the screenshot shows the tag, this
            // is its text even when a capture misses it.
            "hover_item": hoverTitle,
            "help_tag": hover?.toolTip ?? "",
            // Where the pointer move was aimed (Quartz) and how it was read:
            // "ax" is the open item's own frame, "anchor" the popUp fallback.
            "hover_point": hoverPointText,
            "hover_point_source": hoverPointSource,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        running = false
        for timer in timers { timer.invalidate() }
        timers = []
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }
}
