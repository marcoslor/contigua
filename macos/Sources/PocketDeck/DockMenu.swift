// The Dock icon's own menu (`applicationDockMenu`): the two commands a person
// starts from the Dock, Find Apps and Phone Mirror. They are the menus' own
// commands through the panel's shared actions, and they are enabled by the same
// mapping (View ▸ Find Apps always works; Phone ▸ Phone Mirror needs an online
// phone), so the Dock cannot offer what the bar would refuse.

import AppKit

/// One row of the Dock menu, as a value the tests can read.
struct DockMenuEntry: Equatable {
    enum Command: String, Equatable {
        case findApps
        case phoneMirror
    }

    var command: Command
    var title: String
    var enabled: Bool
}

/// The menu's model: pure, so the two rows and their enablement are pinned
/// without a Dock.
enum DockMenuModel {
    static func entries(mirrorEnabled: Bool) -> [DockMenuEntry] {
        [
            DockMenuEntry(command: .findApps, title: PhonePanelItem.findApps.label, enabled: true),
            DockMenuEntry(command: .phoneMirror, title: PhonePanelItem.phoneScreen.label,
                          enabled: mirrorEnabled),
        ]
    }
}

/// The AppKit target: every pick runs one of the shared `PhoneControlsActions`
/// closures, the same ones the menu bar panel's window row and the Phone menu
/// use.
@MainActor
final class DockMenuTarget: NSObject {
    var findApps: () -> Void = {}
    var phoneMirror: () -> Void = {}

    @objc func findAppsClicked(_ sender: NSMenuItem) { findApps() }
    @objc func phoneMirrorClicked(_ sender: NSMenuItem) { phoneMirror() }
}

@MainActor
enum DockMenu {
    /// The menu `applicationDockMenu` returns, built fresh on every open so
    /// Phone Mirror follows the link at the moment the Dock asks.
    static func make(controller: ConnectionController,
                     openDeck: (() -> Void)? = nil) -> NSMenu {
        let state = PhoneControlsState(controller: controller)
        let actions = PhoneControlsActions(controller: controller,
                                           openDeck: openDeck ?? { DeckWindow.open() })
        return make(entries: DockMenuModel.entries(
                        mirrorEnabled: PhonePanelItem.phoneScreen.isEnabled(in: state)),
                    findApps: actions.findApps, phoneMirror: actions.openPhoneScreen)
    }

    /// The AppKit build, with the picks injected so a test can read a real
    /// menu's titles and flags and run what a pick runs.
    static func make(entries: [DockMenuEntry],
                     findApps: @escaping () -> Void,
                     phoneMirror: @escaping () -> Void) -> NSMenu {
        let target = DockMenuTarget()
        target.findApps = findApps
        target.phoneMirror = phoneMirror
        let menu = NSMenu(title: "PocketDeck")
        for entry in entries {
            let selector: Selector
            switch entry.command {
            case .findApps: selector = #selector(DockMenuTarget.findAppsClicked(_:))
            case .phoneMirror: selector = #selector(DockMenuTarget.phoneMirrorClicked(_:))
            }
            let item = NSMenuItem(title: entry.title, action: selector, keyEquivalent: "")
            item.target = target
            // The item retains its represented object, which keeps the target
            // (a weak target otherwise) alive for as long as the menu.
            item.representedObject = target
            item.isEnabled = entry.enabled
            menu.addItem(item)
        }
        return menu
    }
}
