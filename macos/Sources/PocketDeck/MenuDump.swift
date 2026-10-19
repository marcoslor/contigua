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

    /// The JSON the checks read; a file at PATH replaces any earlier one.
    static func json(_ menu: NSMenu?) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(["items": snapshot(menu)])
    }

    static func write(_ menu: NSMenu?, to path: String) throws {
        try json(menu).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
