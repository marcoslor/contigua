// The Window menu's Enter/Exit Full Screen item.
//
// AppKit adds its own full-screen item to the View menu of an active app; that
// system item is the only one that can carry the standard Fn (🌐) shortcut,
// because NSMenuItem refuses .function on items an app creates. AppKit's item
// is not available to a background app (the e2e runs never activate), so the
// Window menu's item is this app's own, and it reports the Fn mask through the
// property's getter — the setter would refuse it for an app-created item. The
// title and the symbol follow the key window (setState, from
// StreamWindowController's full-screen delegate calls).

import AppKit

final class WindowFullScreenItem: NSMenuItem {
    /// AppKit's setter drops .function for app-created items; the menu reads
    /// the mask through this getter, which is what 🌐F needs.
    override var keyEquivalentModifierMask: NSEvent.ModifierFlags {
        get { [.function] }
        set { super.keyEquivalentModifierMask = newValue }
    }

    init() {
        super.init(title: "Enter Full Screen",
                   action: #selector(NSWindow.toggleFullScreen(_:)),
                   keyEquivalent: "f")
        // The action goes through the responder chain to the key window, as
        // AppKit's own item does.
        target = nil
        image = Self.symbol(fullScreen: false)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setState(fullScreen: Bool) {
        title = fullScreen ? "Exit Full Screen" : "Enter Full Screen"
        image = Self.symbol(fullScreen: fullScreen)
    }

    private static func symbol(fullScreen: Bool) -> NSImage? {
        NSImage(systemSymbolName: fullScreen ? "arrow.down.right.and.arrow.up.left"
                                             : "arrow.up.left.and.arrow.down.right",
                accessibilityDescription: nil)
    }
}

@MainActor
enum FullScreenMenu {
    private static var item: WindowFullScreenItem?
    private static var observer: NSObjectProtocol?

    /// Puts the item in the Window menu, after Zoom as in Apple's apps. The
    /// View menu's own full-screen item is turned off at launch
    /// (NSFullScreenMenuItemEverywhere), so this is the only one.
    static func install() {
        guard item == nil,
              let main = NSApp.mainMenu,
              let window = main.items.first(where: { $0.title == "Window" })?.submenu else { return }
        let entry = WindowFullScreenItem()
        let zoom = window.items.firstIndex { $0.action == #selector(NSWindow.performZoom(_:)) }
        let at = (zoom ?? -1) + 1
        if at >= window.items.count || !window.items[at].isSeparatorItem {
            window.insertItem(.separator(), at: at)
        }
        window.insertItem(entry, at: at + 1)
        collapseSeparators(in: window)
        item = entry
        // A rebuild can make AppKit add its own item again; the Window menu's
        // stays the only one.
        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didAddItemNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in removeStrays() }
        }
    }

    /// The key window's full-screen state: the item's title and symbol.
    static func setState(fullScreen: Bool) {
        item?.setState(fullScreen: fullScreen)
    }

    private static func removeStrays() {
        guard let main = NSApp.mainMenu,
              let window = main.items.first(where: { $0.title == "Window" })?.submenu else { return }
        for menu in allMenus(main) where menu !== window {
            for stray in menu.items where stray.action == #selector(NSWindow.toggleFullScreen(_:)) {
                menu.removeItem(stray)
            }
        }
    }

    private static func collapseSeparators(in menu: NSMenu) {
        var index = menu.items.count - 1
        while index > 0 {
            if menu.items[index].isSeparatorItem, menu.items[index - 1].isSeparatorItem {
                menu.removeItem(at: index)
            }
            index -= 1
        }
    }

    private static func allMenus(_ menu: NSMenu) -> [NSMenu] {
        [menu] + menu.items.compactMap(\.submenu).flatMap(allMenus)
    }
}
