// The marks a SwiftUI menu item cannot keep.
//
// SwiftUI builds a command item once and never re-reads its state: a check
// mark, an enabled flag or a title that depends on the running window keeps the
// value it had when the commands were built (measured in an activated app, see
// .agent/menu-ux/report.md). The app keeps every item SwiftUI's, so no rebuild
// can drop one, and corrects those few values on the items it already has. It
// never adds, removes or replaces an item.
//
// `edits` is the rule as a value — the menu's title, its items and the state —
// so K2 tests it without AppKit. `apply` is the only side effect: it writes the
// values onto the items the rules name.

import AppKit

enum MenuMarks {
    /// A menu's item, as far as the rules care: its title, whether it is a
    /// separator, and its submenu's items.
    struct Item: Equatable {
        let title: String
        let isSeparator: Bool
        var children: [Item] = []

        init(title: String, isSeparator: Bool = false, children: [Item] = []) {
            self.title = title
            self.isSeparator = isSeparator
            self.children = children
        }
    }

    /// One correction, addressed by the titles from the menu's root.
    enum Edit: Equatable {
        case mark([String], Bool)
        case enable([String], Bool)
        case retitle([String], String)
    }

    /// The menus whose items carry a mark or a title that follows the window.
    static let menus = ["View", "Window"]

    /// The Density item that names the Settings default: its own title carries
    /// the percentage, so a rule addresses it by this marker and the applier
    /// finds the item whose title starts with "Default (".
    static let defaultDensityItem = "Default (…)"

    /// What to write on `menu`'s items for `state`. Only items the snapshot
    /// holds are named, so the result is the same whatever SwiftUI last wrote
    /// on them: a rebuild that resets a mark to its launch value is corrected
    /// by the next call.
    static func edits(menu: String, items: [Item], state: StreamMenuState) -> [Edit] {
        var edits: [Edit] = []
        for item in items where !item.isSeparator {
            switch (menu, item.title) {
            case ("View", "Framed"):
                // The pair acts on the key stream window: with the Deck (or
                // nothing) key, neither may be checked or enabled.
                edits.append(.mark([item.title], state.hasStream && state.style == .framed))
                edits.append(.enable([item.title], state.hasStream))
            case ("View", "Immersive"):
                edits.append(.mark([item.title], state.hasStream && state.style == .immersive))
                edits.append(.enable([item.title], state.hasStream))
            case ("View", "Hide Controls"):
                // The reveal choice is only meaningful while the window is
                // immersive; the mark inside follows the stored choice.
                edits.append(.enable([item.title], MenuModel.hideControlsEnabled(style: state.style)))
                for child in item.children where !child.isSeparator {
                    guard let entry = ImmersiveMenuModel.items.first(where: { $0.title == child.title }),
                          entry != .separator else { continue }
                    edits.append(.mark([item.title, child.title],
                                       ImmersiveMenuModel.isChecked(entry, reveal: state.revealDelay)))
                }
            case ("View", "Show Touches"):
                edits.append(.mark([item.title], state.showTouches))
            case ("View", "Live Text"):
                edits.append(.mark([item.title], state.liveText))
            case ("View", "Density"):
                edits.append(.enable([item.title], state.hasStream && state.densityPackage != nil))
                for child in item.children where !child.isSeparator {
                    if child.title.hasPrefix("Default (") {
                        edits.append(.retitle([item.title, child.title],
                                              MenuModel.densityDefaultTitle(settings: state.settingsDensity)))
                        edits.append(.mark([item.title, child.title], state.densityOverride == nil))
                    } else if let option = WindowDensity.options.first(where: { $0.label == child.title }) {
                        edits.append(.mark([item.title, child.title], state.densityOverride == option.value))
                    }
                }
            case ("Window", let title) where title.contains("Full Screen"):
                edits.append(.retitle([title], MenuModel.fullScreenTitle(fullScreen: state.fullScreen)))
                edits.append(.enable([title], state.fullScreenAllowed))
            default:
                break
            }
        }
        return edits
    }
}

// MARK: - Applying them

@MainActor
extension MenuMarks {
    private static var observer: NSObjectProtocol?

    /// Corrects the bar's View and Window menus whenever a menu starts
    /// tracking, so the person reads the window's state, not the launch's.
    /// The notification is AppKit's own: SwiftUI keeps its menu delegate.
    static func start() {
        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { apply(to: NSApp.mainMenu) }
        }
    }

    /// Corrects both menus now: on open, and for the debug routes that stand
    /// for what a person reads in an open menu (the e2e's dump and pick).
    static func apply(to mainMenu: NSMenu?) {
        guard let mainMenu else { return }
        for title in menus {
            guard let menu = mainMenu.items.first(where: { $0.title == title })?.submenu else { continue }
            for edit in edits(menu: title, items: snapshot(of: menu), state: StreamMenuState.shared) {
                apply(edit, in: menu)
            }
        }
        if let phone = mainMenu.items.first(where: { $0.title == "Phone" })?.submenu {
            let state = PhoneControlsState(controller: AppEnvironment.shared.controller)
            for edit in phoneEdits(items: snapshot(of: phone), phone: state) {
                apply(edit, in: phone)
            }
        }
    }

    /// Phone ▸ Phone Mirror (⌘P) is enabled while the phone is online, read when
    /// the menu starts tracking: SwiftUI's own flag for the item can lag a
    /// connect, and then the item does nothing. Turn Off Phone Screen's check
    /// follows the phone's own `state.panel`, so an open menu never shows a
    /// value from before the report.
    static func phoneEdits(items: [Item], phone: PhoneControlsState) -> [Edit] {
        var edits: [Edit] = []
        for item in items where !item.isSeparator && item.title == "Phone Mirror" {
            edits.append(.enable([item.title], PhonePanelItem.phoneScreen.isEnabled(in: phone)))
        }
        if items.contains(where: { !$0.isSeparator && $0.title == "Turn Off Phone Screen" }) {
            edits.append(.mark(["Turn Off Phone Screen"], phone.panelOff))
        }
        return edits
    }

    /// The menu's items as values, for the rules.
    static func snapshot(of menu: NSMenu) -> [Item] {
        menu.items.map { item in
            Item(title: item.title,
                 isSeparator: item.isSeparatorItem,
                 children: item.submenu.map { snapshot(of: $0) } ?? [])
        }
    }

    private static func apply(_ edit: Edit, in menu: NSMenu) {
        switch edit {
        case .mark(let path, let on):
            resolve(path, in: menu)?.state = on ? .on : .off
        case .enable(let path, let on):
            resolve(path, in: menu)?.isEnabled = on
        case .retitle(let path, let title):
            resolve(path, in: menu)?.title = title
        }
    }

    /// The item at `path`, by title; the Density default is found by its
    /// marker, because its title carries the percentage.
    private static func resolve(_ path: [String], in menu: NSMenu) -> NSMenuItem? {
        guard let first = path.first else { return nil }
        let item = menu.items.first { $0.title == first }
            ?? (first == defaultDensityItem ? menu.items.first { $0.title.hasPrefix("Default (") } : nil)
        guard let item else { return nil }
        guard path.count > 1, let submenu = item.submenu else { return path.count == 1 ? item : nil }
        return resolve(Array(path.dropFirst()), in: submenu)
    }
}
