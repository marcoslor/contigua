// The menu tree as JSON (DebugInput's `menudump` verb): what the menus really
// contain, as AppKit built them, so the e2e checks can assert on titles,
// images, shortcuts and radio state instead of trusting the source.
//
// Two trees: `items` is the NSMenu the app owns, and `displayed` is the menu bar
// Accessibility exposes — what a person sees. AppKit adds its own items to the
// displayed bar (a full-screen item in any menu titled View, a feedback item in
// Help, extra separators) that never enter the NSMenu; the checks read the
// displayed tree for those.

import AppKit
import ApplicationServices

enum MenuDump {
    /// One item of the tree. Keys are the JSON the checks read.
    struct Item: Codable, Equatable {
        var title: String
        var hasImage: Bool
        var keyEquivalent: String
        var modifiers: [String]
        /// "on", "off" or "mixed" (NSControl.StateValue).
        var state: String
        var isSeparator: Bool
        /// Whether the item can be chosen now (a submenu whose choice is not
        /// active, like Hide Controls while framed, is disabled).
        var enabled: Bool
        /// The class of the item's target, nil when it has none. An item the
        /// app built with AppKit and put in the menu itself is owned by one of
        /// the app's own types ("PocketDeck.ImmersiveMenuInstaller"); a SwiftUI
        /// command's item is owned by SwiftUI. This is how the checks see the
        /// injection pattern that loses items on a rebuild.
        var targetClass: String?
        /// nil when the item has no submenu.
        var submenu: [Item]?
        /// AppKit's hidden flag: an item the menu keeps but does not show.
        var hidden: Bool = false
        /// The item's help tag (a disabled New Window item's sentence, WIN-27).
        var toolTip: String?
        /// The selector the item sends, named: an item with no action cannot be
        /// chosen, however enabled it looks (MENU-8).
        var action: String?
    }

    /// The whole menu bar (an NSMenu's items), in AppKit's order.
    static func snapshot(_ menu: NSMenu?) -> [Item] {
        guard let menu else { return [] }
        return menu.items.map(item)
    }

    static func item(_ menuItem: NSMenuItem) -> Item {
        let key = menuItem.keyEquivalent
        return Item(title: menuItem.title,
                    hasImage: menuItem.image != nil,
                    keyEquivalent: key,
                    modifiers: key.isEmpty ? [] : modifierNames(menuItem.keyEquivalentModifierMask),
                    state: stateName(menuItem.state),
                    isSeparator: menuItem.isSeparatorItem,
                    enabled: menuItem.isEnabled,
                    targetClass: menuItem.target.map { String(describing: type(of: $0)) },
                    submenu: menuItem.submenu.map(snapshot),
                    hidden: menuItem.isHidden,
                    toolTip: menuItem.toolTip,
                    action: menuItem.action.map(NSStringFromSelector))
    }

    /// Stable names, in the order AppKit's own menus show them. An item with no
    /// key equivalent carries AppKit's default mask (.command); it means
    /// nothing there, so the dump leaves it out.
    static func modifierNames(_ flags: NSEvent.ModifierFlags) -> [String] {
        var names: [String] = []
        for (flag, name) in [(NSEvent.ModifierFlags.command, "command"),
                             (.shift, "shift"),
                             (.option, "option"),
                             (.control, "control"),
                             (.function, "function"),
                             (.capsLock, "capsLock"),
                             (.numericPad, "numericPad")]
        where flags.contains(flag) {
            names.append(name)
        }
        return names
    }

    private static func stateName(_ state: NSControl.StateValue) -> String {
        switch state {
        case .on: return "on"
        case .mixed: return "mixed"
        default: return "off"
        }
    }

    /// Everything wrong with a menu's shape, as sentences the checks and the
    /// tests print: a leading, trailing or doubled separator. A menu's shape is
    /// what SwiftUI's rebuilds can break silently (an item vanishes and the two
    /// dividers around it meet), so it is checked as data, not by eye.
    static func shapeProblems(_ menu: String, _ items: [Item]) -> [String] {
        var problems: [String] = []
        func report(_ name: String, _ rows: [Item]) {
            if let first = rows.first, first.isSeparator {
                problems.append("\(name): leading separator")
            }
            if let last = rows.last, last.isSeparator {
                problems.append("\(name): trailing separator")
            }
            for (index, item) in rows.enumerated() where item.isSeparator && index > 0 {
                if rows[index - 1].isSeparator {
                    problems.append("\(name): separator \(index + 1) follows another")
                }
            }
        }
        report(menu, items)
        for item in items {
            if let submenu = item.submenu { report("\(menu)/\(item.title)", submenu) }
        }
        return problems
    }

    /// Every menu bar item and its shape problems, so a check can assert on the
    /// whole bar in one read.
    static func problems(_ menu: NSMenu?) -> [String] {
        guard let menu else { return [] }
        return menu.items.flatMap { item in
            shapeProblems(item.title, item.submenu.map(snapshot) ?? [])
        }
    }

    /// The whole dump: the bar's items and the shape problems found in them.
    private struct Document: Encodable {
        var items: [Item]
        var problems: [String]
        /// The menu bar as Accessibility shows it, when the caller asked for it.
        var displayed: [Item]?
        var displayedProblems: [String]?
    }

    /// The JSON the checks read; a file at PATH replaces any earlier one.
    static func json(_ menu: NSMenu?, displayed: Bool = false) throws -> Data {
        // The app's own tree first: reading the displayed bar makes AppKit
        // validate and rebuild the menus (its system items appear, SwiftUI
        // re-evaluates the commands), so the two trees are read in that order
        // and `items` is the state the app itself had.
        let items = snapshot(menu)
        let shape = problems(menu)
        var shown: [Item]?
        if displayed {
            // The first read is what makes AppKit add its own items. Then the
            // pass a person's open runs (MenuCleanup, on tracking) runs, and the
            // second read is what the person sees open.
            _ = displayedItems()
            MainActor.assumeIsolated { MenuCleanup.clean(NSApp.mainMenu) }
            shown = displayedItems()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Document(
            items: items,
            problems: shape,
            displayed: shown,
            displayedProblems: shown.map(displayedProblems)))
    }

    static func write(_ menu: NSMenu?, to path: String, displayed: Bool = false) throws {
        try json(menu, displayed: displayed).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    // MARK: - The displayed bar

    /// The app's own menu bar through Accessibility: every item AppKit shows,
    /// the system's additions included. Read from the app's own process, so the
    /// e2e needs no Automation permission and cannot read another app's bar.
    static func displayedItems() -> [Item] {
        let app = AXUIElementCreateApplication(getpid())
        guard let bar = copy(app, kAXMenuBarAttribute as String) else { return [] }
        return children(bar).compactMap { barItem in
            let title = string(barItem, kAXTitleAttribute)
            guard title != "Apple" else { return nil }
            return Item(title: title,
                        hasImage: false,
                        keyEquivalent: "",
                        modifiers: [],
                        state: "off",
                        isSeparator: false,
                        enabled: true,
                        targetClass: nil,
                        submenu: children(barItem).first.map(displayedMenu))
        }
    }

    /// One AXMenu's items, in the order the person reads them.
    static func displayedMenu(_ menu: AXUIElement) -> [Item] {
        children(menu).map { element in
            let title = string(element, kAXTitleAttribute)
            if title.isEmpty {
                return Item(title: "", hasImage: false, keyEquivalent: "", modifiers: [],
                            state: "off", isSeparator: true, enabled: false,
                            targetClass: nil, submenu: nil)
            }
            let command = string(element, kAXMenuItemCmdCharAttribute).lowercased()
            return Item(title: title,
                        hasImage: false,
                        keyEquivalent: command,
                        modifiers: command.isEmpty ? [] : displayedModifiers(element),
                        state: string(element, kAXMenuItemMarkCharAttribute).isEmpty ? "off" : "on",
                        isSeparator: false,
                        enabled: bool(element, kAXEnabledAttribute),
                        targetClass: nil,
                        submenu: children(element).first.map(displayedMenu))
        }
    }

    static func displayedProblems(_ items: [Item]) -> [String] {
        items.flatMap { item in
            shapeProblems(item.title, item.submenu ?? [])
        }
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return true }
        return value as? Bool ?? true
    }

    /// AX's command modifier mask (bit 0 shift, 1 option, 2 control, 3 no
    /// command, 4 function), named in the order the checks read: command first.
    private static func displayedModifiers(_ element: AXUIElement) -> [String] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMenuItemCmdModifiersAttribute as CFString, &value) == .success,
              let mask = value as? Int else { return ["command"] }
        var names: [String] = []
        if mask & 8 == 0 { names.append("command") }
        if mask & 1 != 0 { names.append("shift") }
        if mask & 2 != 0 { names.append("option") }
        if mask & 4 != 0 { names.append("control") }
        if mask & 16 != 0 { names.append("function") }
        return names
    }
}
