// View ▸ Framed / Immersive / Hide Controls (docs/design/mac-redesign.md §3.8).
//
// Framed and Immersive are a radio pair for the front stream window, and Hide
// Controls is the reveal choice's submenu (the three delays, a separator,
// Always Visible), enabled only while the window is immersive. A choice cannot
// also be a submenu's parent — AppKit gives a submenu item its own disclosure
// and a SwiftUI Toggle does not re-read its state on a menu update — so the
// three items are AppKit's, built here and refreshed from StreamMenuState.
//
// SwiftUI can rebuild the View menu after us (a state change, a relaunch, a
// different activation path), and the rebuild replaces every item: an item
// inserted once is then gone, which is how the person's v104 menu lost
// Immersive. `ensureInstalled` builds them again whenever they are missing,
// from the refresh points and from AppKit's did-add-item notification (the same
// hook FullScreenMenu uses for its rebuilds). The parent menu is looked up
// fresh each time; SwiftUI's rebuilds make old references detached.

import AppKit

@MainActor
final class ImmersiveMenuInstaller: NSObject, NSMenuDelegate {
    static let shared = ImmersiveMenuInstaller()

    /// The View menu's three items, in their order.
    static let titles = ["Framed", "Immersive", "Hide Controls"]

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
        guard let view = viewMenu() else { return }
        if view.items.contains(where: { $0.title == "Hide Controls" }) {
            view.delegate = self
            return
        }
        // The design puts the pair between the Live Text/controls section and
        // Density: right after the separator that follows Live Text.
        guard let liveText = view.items.firstIndex(where: { $0.title == "Live Text" }) else { return }
        var at = liveText + 1
        if at < view.items.count, view.items[at].isSeparatorItem { at += 1 }

        let framed = NSMenuItem(title: WindowStyle.framed.label,
                                action: #selector(pickFramed(_:)), keyEquivalent: "")
        framed.target = self
        view.insertItem(framed, at: at)

        let immersive = NSMenuItem(title: WindowStyle.immersive.label,
                                   action: #selector(pickImmersiveStyle(_:)), keyEquivalent: "")
        immersive.target = self
        view.insertItem(immersive, at: at + 1)

        let hide = NSMenuItem(title: "Hide Controls", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Hide Controls")
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
        hide.submenu = submenu
        view.insertItem(hide, at: at + 2)
        view.delegate = self
    }

    /// One observer for the whole process: a rebuild adds items, and the items
    /// are put back then. Re-adding them adds more items (and so on), but the
    /// second pass finds them and stops.
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

    /// The style radio pair: the pick is the front window's style, nothing else.
    @objc private func pickFramed(_ sender: NSMenuItem) {
        AppEnvironment.shared.controller.windows.setKeyWindowStyle(.framed)
        refreshState(style: .framed)
    }

    @objc private func pickImmersiveStyle(_ sender: NSMenuItem) {
        AppEnvironment.shared.controller.windows.setKeyWindowStyle(.immersive)
        refreshState(style: .immersive)
    }

    /// One of Hide Controls' items: store the reveal choice, leave the style.
    @objc private func pick(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ImmersiveMenuItem,
              let pick = ImmersiveMenuModel.pick(entry) else { return }
        AppEnvironment.shared.controller.windows.setRevealDelay(pick.reveal)
        refreshState()
    }

    /// The states a person sees: one radio checked for the front window's
    /// style, Hide Controls enabled only while it is immersive, one checkmark
    /// on the stored reveal choice. Looked up fresh each time: SwiftUI can
    /// rebuild the View menu's items, and an old reference would be detached.
    private func refreshState(style: WindowStyle? = nil) {
        guard let view = viewMenu(),
              let framed = view.items.first(where: { $0.title == "Framed" }),
              let immersive = view.items.first(where: { $0.title == "Immersive" }),
              let hide = view.items.first(where: { $0.title == "Hide Controls" }) else { return }
        let current = style ?? StreamMenuState.shared.style
        framed.state = current == .framed ? .on : .off
        immersive.state = ImmersiveMenuModel.parentChecked(style: current) ? .on : .off
        hide.isEnabled = current == .immersive
        let reveal = AppEnvironment.shared.controller.windows.revealDelay
        for child in hide.submenu?.items ?? [] {
            guard let entry = child.representedObject as? ImmersiveMenuItem else { continue }
            child.state = ImmersiveMenuModel.isChecked(entry, reveal: reveal) ? .on : .off
        }
    }

    private func viewMenu() -> NSMenu? {
        NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        ensureInstalled()
        refreshState()
    }
}
