// The menu tree as JSON (DebugInput's `menudump` verb): what the menus really
// contain, as AppKit built them, so the e2e checks can assert on titles,
// images, shortcuts and radio state instead of trusting the source.

import AppKit

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
                    submenu: menuItem.submenu.map(snapshot))
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
    }

    /// The JSON the checks read; a file at PATH replaces any earlier one.
    static func json(_ menu: NSMenu?) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Document(items: snapshot(menu), problems: problems(menu)))
    }

    static func write(_ menu: NSMenu?, to path: String) throws {
        try json(menu).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
