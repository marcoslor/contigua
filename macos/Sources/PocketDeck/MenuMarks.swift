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
        /// The item's key, empty for none: File's New item is addressed by its
        /// ⌘N, because its title is what changes (MENU-2).
        var keyEquivalent: String
        /// The item's own modifiers: the full-screen alternate is the only item
        /// with ⌃⌘F, AppKit's is fn-F (MENU-8).
        var modifiers: NSEvent.ModifierFlags

        init(title: String, isSeparator: Bool = false, children: [Item] = [],
             keyEquivalent: String = "", modifiers: NSEvent.ModifierFlags = []) {
            self.title = title
            self.isSeparator = isSeparator
            self.children = children
            self.keyEquivalent = keyEquivalent
            self.modifiers = modifiers
        }
    }

    /// One correction, addressed by the titles from the menu's root.
    enum Edit: Equatable {
        case mark([String], Bool)
        case enable([String], Bool)
        case retitle([String], String)
        /// The handoff item, addressed by its ⇧⌘C key because its title is one
        /// of the values that follows the phone (PANEL-28).
        case handoff(title: String, enabled: Bool, help: String?)
        /// Hide the app's ⌃⌘F alternate but keep its key equivalent.
        case hide
    }

    /// File ▸ New <App> Window's one correction: SwiftUI built the item at
    /// launch, when no app window was key, so its title, flag and sentence are
    /// written onto the item the person's menu already holds (MENU-2, WIN-25,
    /// WIN-27, WIN-32, WIN-34).
    static func fileNew(_ item: NewWindowItem) -> (title: String, enabled: Bool, help: String?) {
        (item.title, item.enabled, item.help)
    }

    /// The menus whose items carry a mark or a title that follows the window.
    /// Window's own items are AppKit's (the next-window flag is written below,
    /// and full screen is the system's: MENU-4, MENU-7).
    static let menus = ["View", "Navigate"]

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
                edits.append(.enable([item.title],
                                     state.hasStream && MenuModel.hideControlsEnabled(style: state.style)))
                for child in item.children where !child.isSeparator {
                    guard let entry = ImmersiveMenuModel.items.first(where: { $0.title == child.title }),
                          entry != .separator else { continue }
                    edits.append(.mark([item.title, child.title],
                                       ImmersiveMenuModel.isChecked(entry, reveal: state.revealDelay)))
                }
            case ("View", "Show Touches"):
                // The key stream window's item: with the Deck (or nothing) key
                // it is off and disabled, whatever the window behind it shows
                // (MENU-4, MENU-9, ISS-88).
                edits.append(.mark([item.title], state.hasStream && state.showTouches))
                edits.append(.enable([item.title], state.hasStream))
            case ("View", "Live Text"):
                edits.append(.mark([item.title], state.hasStream && state.liveText))
                edits.append(.enable([item.title], state.hasStream))
            case ("View", "Icon Size"):
                // The Deck's stored choice: one of the four percentages is
                // checked (DECK-6). The value is read when the menu opens.
                for child in item.children where !child.isSeparator {
                    guard let option = DeckZoom.options.first(where: {
                        MenuModel.iconSizeTitle($0) == child.title
                    }) else { continue }
                    edits.append(.mark([item.title, child.title],
                                       abs(state.deckZoom - option) < 0.0005))
                }
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
            case ("View", "Enter Full Screen")
                where item.keyEquivalent == "f"
                    && item.modifiers.isSuperset(of: [.control, .command]):
                // The app's ⌃⌘F alternate: hidden, but allowed to take its key
                // while hidden. AppKit's own fn-F item has no ⌃⌘F and is never
                // touched (MENU-4, MENU-8, MENU-11).
                edits.append(.hide)
            case ("Navigate", "Back"), ("Navigate", "Home"), ("Navigate", "Recents"):
                // The three act on the key stream window through its responder
                // chain: with the Deck (or nothing) key there is nothing to
                // act on, so they are disabled (MENU-6, ISS-88). With a
                // stream window key today's rule stands: frozen (Live Text or
                // a cover) and a down link disable them.
                edits.append(.enable([item.title],
                                     state.hasStream && !state.frozen && !state.phoneOffline))
            default:
                break
            }
        }
        return edits
    }
}

// MARK: - The one action SwiftUI leaves out

/// Window ▸ Next Window's target. SwiftUI builds that item inert, so the app
/// supplies the method it names when the menu opens (see `MenuMarks.apply`).
@MainActor
final class NextWindowAction: NSObject {
    static let shared = NextWindowAction()

    @objc func cycle(_ sender: Any?) { AppEnvironment.shared.controller.cycleWindow() }
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
        // The Deck's icon size is a stored choice, and its checkmark must follow
        // a ⌘+ pressed a moment before the menu opened: read it now, not from
        // the last poll.
        StreamMenuState.shared.deckZoom = DeckZoom.stored(in: Profile.active.defaults)
        for title in menus {
            guard let menu = mainMenu.items.first(where: { $0.title == title })?.submenu else { continue }
            for edit in edits(menu: title, items: snapshot(of: menu), state: StreamMenuState.shared) {
                apply(edit, in: menu)
            }
        }
        if let phone = mainMenu.items.first(where: { $0.title == "Phone" })?.submenu {
            let state = PhoneControlsState(controller: AppEnvironment.shared.controller)
            for edit in phoneEdits(items: snapshot(of: phone), phone: state,
                                   stream: StreamMenuState.shared) {
                apply(edit, in: phone)
            }
        }
        // Window ▸ Next Window follows how many windows the key app has, which
        // this value does not carry: the running window set decides (WIN-29).
        if let window = mainMenu.items.first(where: { $0.title == "Window" })?.submenu,
           let next = window.items.first(where: { $0.title == "Next Window" }) {
            next.isEnabled = AppEnvironment.shared.controller.windows.canCycleWindows
            // SwiftUI builds this one item without a target and an action at
            // all (measured: `action == nil` beside an Enter Full Screen that
            // has its own), so a person's click and its ⌘` would do nothing.
            // The app attaches the one method the item names, on SwiftUI's own
            // item — the same rule as the marks above, never a new item.
            if next.action == nil {
                next.target = NextWindowAction.shared
                next.action = #selector(NextWindowAction.cycle(_:))
            }
        }
        // File ▸ New <App> Window: addressed by its ⌘N, because the title is
        // one of the values that follows the key app.
        if let file = mainMenu.items.first(where: { $0.title == "File" })?.submenu {
            let item = AppEnvironment.shared.controller.windows.keyNewWindowItem
            let wanted = fileNew(item)
            if let new = file.items.first(where: {
                !$0.isSeparatorItem && $0.keyEquivalent == "n"
                    && $0.keyEquivalentModifierMask.intersection([.shift, .option, .control]).isEmpty
            }) {
                if new.title != wanted.title { new.title = wanted.title }
                new.isEnabled = wanted.enabled
                new.toolTip = wanted.help
            }
        }
    }

    /// Phone ▸ Phone Mirror (⌘P) is enabled while the phone is online, read when
    /// the menu starts tracking: SwiftUI's own flag for the item can lag a
    /// connect, and then the item does nothing. Turn Off Phone Screen acts on
    /// the key phone window only, so it is disabled with any other key window
    /// (MENU-5, ISS-88); its check follows the phone's own `state.panel`, so an
    /// open menu never shows a value from before the report.
    static func phoneEdits(items: [Item], phone: PhoneControlsState,
                           stream: StreamMenuState) -> [Edit] {
        var edits: [Edit] = []
        for item in items where !item.isSeparator && item.title == "Phone Mirror" {
            edits.append(.enable([item.title], PhonePanelItem.phoneScreen.isEnabled(in: phone)))
        }
        if items.contains(where: { !$0.isSeparator && $0.title == "Turn Off Phone Screen" }) {
            edits.append(.enable(["Turn Off Phone Screen"],
                                 stream.phoneWindow && !stream.phoneOffline))
            edits.append(.mark(["Turn Off Phone Screen"], phone.panelOff))
        }
        // The item's title, enablement and reason follow the foreground reply,
        // which SwiftUI built once at launch (PANEL-28).
        edits.append(.handoff(title: phone.continueTitle, enabled: phone.continueEnabled,
                              help: phone.continueReason))
        return edits
    }

    /// The menu's items as values, for the rules.
    static func snapshot(of menu: NSMenu) -> [Item] {
        menu.items.map { item in
            Item(title: item.title,
                 isSeparator: item.isSeparatorItem,
                 children: item.submenu.map { snapshot(of: $0) } ?? [],
                 keyEquivalent: item.keyEquivalent,
                 modifiers: item.keyEquivalent.isEmpty ? [] : item.keyEquivalentModifierMask)
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
        case .handoff(let title, let enabled, let help):
            // By the shortcut, never by title: the title is what changes.
            guard let item = menu.items.first(where: {
                $0.keyEquivalent == "c"
                    && $0.keyEquivalentModifierMask.isSuperset(of: [.command, .shift])
            }) else { return }
            item.title = title
            item.isEnabled = enabled
            item.toolTip = help
        case .hide:
            // By the shortcut, never by title alone: AppKit's own item shares
            // the title and must stay visible (MENU-11).
            guard let item = menu.items.first(where: {
                $0.keyEquivalent == "f"
                    && $0.keyEquivalentModifierMask.isSuperset(of: [.control, .command])
            }) else { return }
            item.isHidden = true
            // A hidden item normally gives up its key; this one is the app's
            // ⌃⌘F route while the person reads macOS's own fn-F item.
            item.allowsKeyEquivalentWhenHidden = true
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
