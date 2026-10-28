// The bar's system leftovers, after SwiftUI and AppKit have built the menus.
//
// AppKit puts an item in Help that the app did not write: "Send <app> Feedback
// …" (the design keeps Help empty). SwiftUI puts a separator where it places
// one command group between two of its own: Window's Enter Full Screen group
// leaves two in a row before Bring All to Front, and neither framework offers
// a way to say "this group takes no separator".
//
// This pass only removes: the feedback item, every separator in Help (its only
// other content), and a separator that directly follows another. It never
// adds, moves or retitles an item, and it never touches a separator at the
// edge of a menu: SwiftUI builds its menus item by item, and removing what is
// only the trailing edge so far makes it stop filling the menu.
//
// It runs on the notifications AppKit and SwiftUI post when a menu changes (and
// when the app activates and a menu opens), so a rebuild cannot bring the
// leftovers back unnoticed. `removals` is the rule as a value over a menu
// snapshot, so K2 tests it without AppKit; `clean` is the only side effect.

import AppKit

enum MenuCleanup {
    /// A menu's items as far as the rules care: title, whether it is a
    /// separator, its key equivalent, and a submenu.
    struct Item: Equatable {
        var title: String
        var isSeparator: Bool
        var children: [Item] = []
        /// The item's own shortcut, empty for none: AppKit's duplicate
        /// full-screen item carries none, the app's carries ⌃⌘F (MENU-7).
        var keyEquivalent: String = ""

        init(title: String, isSeparator: Bool = false, children: [Item] = [],
             keyEquivalent: String = "") {
            self.title = title
            self.isSeparator = isSeparator
            self.children = children
            self.keyEquivalent = keyEquivalent
        }
    }

    /// A removal, by the item's indices from the menu's root (the last index
    /// is the item itself).
    struct Removal: Equatable, Hashable {
        var path: [Int]
    }

    /// The items to remove from `menu` and its submenus.
    static func removals(menu: String, items: [Item]) -> [Removal] {
        var out: [Removal] = []
        collect(menu: menu, items: items, path: [], into: &out)
        return out
    }

    private static func collect(menu: String, items: [Item], path: [Int], into out: inout [Removal]) {
        for (index, item) in items.enumerated() where !item.children.isEmpty {
            collect(menu: menu.isEmpty ? item.title : menu + "/" + item.title, items: item.children,
                    path: path + [index], into: &out)
        }
        var removed = Set<Int>()
        // AppKit adds its own Enter Full Screen to the Window menu; after a
        // SwiftUI rebuild the bar can show it beside the app's ⌃⌘F item, so the
        // person reads the command twice. The keyed item is the app's and stays;
        // the key-less one is a leftover (MENU-7, MENU-11).
        if menu == "Window" {
            let fullScreen = items.enumerated().filter {
                !$0.element.isSeparator && isFullScreen($0.element.title)
            }
            if fullScreen.contains(where: { !$0.element.keyEquivalent.isEmpty }) {
                for case let (index, item) in fullScreen where item.keyEquivalent.isEmpty {
                    removed.insert(index)
                }
            }
        }
        if menu == "Help" {
            for (index, item) in items.enumerated() where !item.isSeparator && isSystemFeedback(item.title) {
                removed.insert(index)
            }
        }
        var previousWasSeparator = false
        for index in items.indices where !removed.contains(index) {
            guard items[index].isSeparator else {
                previousWasSeparator = false
                continue
            }
            if previousWasSeparator || menu == "Help" {
                removed.insert(index)
            }
            previousWasSeparator = true
        }
        out.append(contentsOf: removed.sorted().map { Removal(path: path + [$0]) })
    }

    /// The item AppKit adds to Help: "Send <app> Feedback" or "Send <app>
    /// Feedback to Apple" (the wording follows the bundle).
    static func isSystemFeedback(_ title: String) -> Bool {
        (title.hasPrefix("Send ") && title.contains("Feedback")) || title.contains("Feedback to Apple")
    }

    /// AppKit's full-screen item and the app's: the same two titles.
    static func isFullScreen(_ title: String) -> Bool {
        title == "Enter Full Screen" || title == "Exit Full Screen"
    }
}

// MARK: - Applying them

@MainActor
extension MenuCleanup {
    private static var observers: [NSObjectProtocol] = []

    /// True while a pass is removing items. Removing one posts the change
    /// notifications this file observes; a nested pass would take its paths
    /// from a menu the outer pass has half changed.
    private static var cleaning = false

    /// The delay after the last change before a notification's pass runs. SwiftUI
    /// builds and rebuilds its menus item by item, in bursts: a pass made
    /// mid-build removes a separator that is only transient, and then SwiftUI
    /// stops filling its menu. Every change restarts the wait.
    private static let settleDelay: TimeInterval = 0.5
    private static var settling: DispatchWorkItem?

    /// Cleans the bar once it stops changing, when a menu opens and when the
    /// app activates (a person's open reads the bar then, so it cleans at once).
    static func start() {
        settle()
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { settle() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { clean(NSApp.mainMenu) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { clean(NSApp.mainMenu) }
        })
    }

    /// Runs one pass once the bar has been quiet for `settleDelay`.
    static func settle() {
        settling?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { clean(NSApp.mainMenu) }
        }
        settling = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: work)
    }

    /// One pass over the whole bar.
    static func clean(_ menu: NSMenu?) {
        guard let menu, !cleaning else { return }
        cleaning = true
        defer { cleaning = false }
        apply(removals(menu: menuName(menu), items: snapshot(of: menu)), to: menu)
    }

    /// A menu's name as the bar shows it. SwiftUI's submenus often carry no
    /// title of their own, so the bar item that owns the menu names it.
    static func menuName(_ menu: NSMenu) -> String {
        if !menu.title.isEmpty { return menu.title }
        for item in NSApp.mainMenu?.items ?? [] where item.submenu === menu {
            return item.title
        }
        return menu.title
    }

    static func snapshot(of menu: NSMenu) -> [Item] {
        menu.items.map { item in
            Item(title: item.title,
                 isSeparator: item.isSeparatorItem,
                 children: item.submenu.map { snapshot(of: $0) } ?? [],
                 keyEquivalent: item.keyEquivalent)
        }
    }

    /// Removals deepest first and, within a menu, highest index first, so every
    /// path still names the item it was computed for.
    private static func apply(_ removals: [Removal], to menu: NSMenu) {
        for removal in removals.sorted(by: deeperFirst) {
            var target = menu
            var ok = true
            for index in removal.path.dropLast() {
                guard index < target.items.count, let submenu = target.items[index].submenu else {
                    ok = false
                    break
                }
                target = submenu
            }
            guard ok, let last = removal.path.last, last < target.items.count else { continue }
            target.removeItem(at: last)
        }
    }

    /// Deepest first and, within one menu, highest index first: removing an
    /// item never invalidates a path computed before it.
    private static func deeperFirst(_ a: Removal, _ b: Removal) -> Bool {
        if a.path.count != b.path.count { return a.path.count > b.path.count }
        for (left, right) in zip(a.path, b.path) where left != right {
            return left > right
        }
        return false
    }
}
