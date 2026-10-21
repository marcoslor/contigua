// View ▸ Immersive (docs/design/mac-redesign.md §3.8). SwiftUI builds the
// View menu, but a SwiftUI Picker's submenu parent cannot carry a checkmark
// (and its item state is reset on every menu update). This AppKit item is
// inserted after "Framed" with its submenu built here: the three reveal
// delays, a separator, Always Visible. Picking any of them stores the global
// choice and takes the focused window to immersive (ImmersiveMenuModel).
//
// SwiftUI can rebuild the View menu after us (a state change, a relaunch, a
// different activation path), and the rebuild replaces every item: an item
// inserted once is then gone, which is how the person's v104 menu lost
// Immersive. `ensureInstalled` builds it again whenever it is missing, from
// the refresh points and from AppKit's did-add-item notification (the same
// hook FullScreenMenu uses for its rebuilds). The parent is looked up fresh
// each time; SwiftUI's rebuilds make the old references detached.

import AppKit

@MainActor
final class ImmersiveMenuInstaller: NSObject, NSMenuDelegate {
    static let shared = ImmersiveMenuInstaller()

    private var observer: NSObjectProtocol?

    static func install() {
        shared.startWatching()
        shared.ensureInstalled()
        shared.refreshState()
    }

    static func refresh(style: WindowStyle? = nil) {
        shared.ensureInstalled()
        shared.refreshState(style: style)
    }

    /// Rebuilds the AppKit items when the View menu is new or was rebuilt.
    /// Internal for the rebuild test.
    func ensureInstalled() {
        guard let main = NSApp.mainMenu,
              let view = main.items.first(where: { $0.title == "View" })?.submenu else { return }
        if view.items.contains(where: { $0.title == "Immersive" }) {
            view.delegate = self
            return
        }
        // Wait for SwiftUI to add "Framed": the design puts Immersive right
        // after it, and the did-add-item hook runs again on the next item.
        guard let framed = view.items.firstIndex(where: { $0.title == "Framed" }) else { return }

        let item = NSMenuItem(title: "Immersive", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Immersive")
        submenu.delegate = self
        for entry in ImmersiveMenuModel.items {
            switch entry {
            case .separator:
                submenu.addItem(.separator())
            default:
                let child = NSMenuItem(title: entry.title,
                                       action: #selector(pick(_:)), keyEquivalent: "")
                child.target = self
                child.representedObject = entry
                submenu.addItem(child)
            }
        }
        item.submenu = submenu
        view.insertItem(item, at: framed + 1)
        view.delegate = self
    }

    /// One observer for the whole process: a rebuild adds items, and the item
    /// is put back then. Re-adding it adds another item (and so on), but the
    /// second pass finds it and stops.
    private func startWatching() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didAddItemNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                ImmersiveMenuInstaller.shared.ensureInstalled()
                ImmersiveMenuInstaller.shared.refreshState()
            }
        }
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ImmersiveMenuItem else { return }
        AppEnvironment.shared.controller.windows.pickImmersive(entry)
        // The pick's own checks now, from the choice itself: correct even
        // before the store's change has reached the display copy.
        for child in parent(submenu: sender.menu) {
            guard let other = child.representedObject as? ImmersiveMenuItem else { continue }
            child.state = ImmersiveMenuModel.isChecked(other, reveal: entryReveal(entry)) ? .on : .off
        }
        refreshState()
    }

    private func entryReveal(_ entry: ImmersiveMenuItem) -> RevealDelay {
        ImmersiveMenuModel.pick(entry)?.reveal ?? .short
    }

    private func parent(submenu: NSMenu?) -> [NSMenuItem] {
        submenu?.items ?? []
    }

    /// The states a person sees: the parent checked while the key window is
    /// immersive, one checkmark on the stored reveal choice. Looked up fresh
    /// each time: SwiftUI can rebuild the View menu's items, and an old
    /// reference would be a detached item.
    private func refreshState(style: WindowStyle? = nil) {
        guard let main = NSApp.mainMenu,
              let view = main.items.first(where: { $0.title == "View" })?.submenu,
              let parent = view.items.first(where: { $0.title == "Immersive" }) else { return }
        parent.state = ImmersiveMenuModel.parentChecked(style: style ?? StreamMenuState.shared.style) ? .on : .off
        let reveal = AppEnvironment.shared.controller.windows.revealDelay
        for child in parent.submenu?.items ?? [] {
            guard let entry = child.representedObject as? ImmersiveMenuItem else { continue }
            child.state = ImmersiveMenuModel.isChecked(entry, reveal: reveal) ? .on : .off
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        ensureInstalled()
        refreshState()
    }
}
