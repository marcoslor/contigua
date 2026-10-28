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
// the run (the quiet rule in .agent/_common.md). Nothing moves the pointer.

import AppKit

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
    private static var timers: [Timer] = []
    private static var observers: [NSObjectProtocol] = []

    /// Starts one tracked session. Returns why it could not start, else nil.
    static func start(path resultPath: String, itemPath: String, seconds wait: TimeInterval) -> String? {
        guard !running else { return "a menu track is already running" }
        guard wait > 0, wait <= 30 else { return "menutrack needs 0 < SECONDS <= 30" }
        let item = resolve(itemPath: itemPath)
        guard let item else { return "menutrack: no menu item at \(itemPath)" }
        guard let submenu = item.submenu else { return "menutrack: \(itemPath) has no submenu" }
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }),
              let view = window.contentView else { return "menutrack: no window to show a menu over" }

        running = true
        path = resultPath
        MenuTrack.itemPath = itemPath
        seconds = wait
        buildsBefore = Menus.builds
        itemsBefore = identities(in: NSApp.mainMenu)
        submenuBefore = item.submenu.map(ObjectIdentifier.init)
        opened = false
        openedSubmenu = false
        stateChanges = 0
        trackingPaths = []
        observe()

        // The menu must be opened from the run loop, not from this command: the
        // command's own reply has to reach the check before the main thread
        // enters the tracking loop.
        schedule(after: 0.4) {
            opened = true
            submenu.popUp(positioning: nil,
                          at: NSPoint(x: 40, y: max(40, (view.bounds.height) - 40)),
                          in: view)
        }
        schedule(after: 0.4 + wait) {
            openedSubmenu = trackingPaths.contains(itemPath)
            write()
        }
        schedule(after: 0.4 + wait) {
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
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        Log.app.info("menutrack: opened=\(opened, privacy: .public) builds=\(Menus.builds - buildsBefore, privacy: .public) tracking=\(trackingPaths.count, privacy: .public)")
        running = false
        for timer in timers { timer.invalidate() }
        timers = []
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }
}
