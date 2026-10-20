// View ▸ Immersive (docs/design/mac-redesign.md §3.8). SwiftUI builds the
// View menu, but a SwiftUI Picker's submenu parent cannot carry a checkmark
// (and its item state is reset on every menu update). This AppKit item is
// inserted after "Framed" with its submenu built here: the three reveal
// delays, a separator, Always Visible. Picking any of them stores the global
// choice and takes the focused window to immersive (ImmersiveMenuModel).
//
// The parent stays put across SwiftUI's menu updates, as FullScreenMenu's
// Window item does; its state follows the key window's style.

import AppKit

@MainActor
final class ImmersiveMenuInstaller: NSObject, NSMenuDelegate {
    static let shared = ImmersiveMenuInstaller()

    private var parentItem: NSMenuItem?
    private var children: [NSMenuItem] = []

    static func install() {
        shared.install()
    }

    static func refresh(style: WindowStyle? = nil) {
        shared.refresh(style: style)
    }

    private func install() {
        guard parentItem == nil,
              let main = NSApp.mainMenu,
              let view = main.items.first(where: { $0.title == "View" })?.submenu,
              !view.items.contains(where: { $0.title == "Immersive" }) else { return }

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
                children.append(child)
            }
        }
        item.submenu = submenu
        // Right after Framed, where the design puts it.
        if let framed = view.items.firstIndex(where: { $0.title == "Framed" }) {
            view.insertItem(item, at: framed + 1)
        } else {
            view.addItem(item)
        }
        parentItem = item
        refresh()
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ImmersiveMenuItem else { return }
        AppEnvironment.shared.controller.windows.pickImmersive(entry)
        refresh()
    }

    /// The states a person sees: the parent checked while the key window is
    /// immersive, one checkmark on the stored reveal choice.
    func refresh(style: WindowStyle? = nil) {
        guard let parentItem else { return }
        parentItem.state = ImmersiveMenuModel.parentChecked(style: style ?? StreamMenuState.shared.style) ? .on : .off
        let reveal = StreamMenuState.shared.revealDelay
        for child in children {
            guard let entry = child.representedObject as? ImmersiveMenuItem else { continue }
            child.state = ImmersiveMenuModel.isChecked(entry, reveal: reveal) ? .on : .off
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }
}
