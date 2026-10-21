// The menu dump the e2e menus check reads (MenuDump.swift): titles, images,
// shortcuts, state and submenus of a hand-built NSMenu.

import AppKit
import XCTest
@testable import PocketDeck

final class MenuDumpTests: XCTestCase {
    private func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Main")
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "File")
        let open = NSMenuItem(title: "Open", action: nil, keyEquivalent: "o")
        open.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        submenu.addItem(open)
        submenu.addItem(.separator())
        let framed = NSMenuItem(title: "Framed", action: nil, keyEquivalent: "")
        framed.state = .on
        submenu.addItem(framed)
        file.submenu = submenu
        menu.addItem(file)
        menu.addItem(.separator())
        return menu
    }

    func testDumpsTheTreeWithImagesShortcutsAndState() {
        let items = MenuDump.snapshot(makeMenu())
        XCTAssertEqual(items.count, 2)

        XCTAssertEqual(items[0].title, "File")
        XCTAssertFalse(items[0].hasImage)
        XCTAssertEqual(items[0].keyEquivalent, "")
        XCTAssertEqual(items[0].modifiers, [])
        XCTAssertEqual(items[0].state, "off")
        XCTAssertFalse(items[0].isSeparator)

        let submenu = items[0].submenu
        XCTAssertEqual(submenu?.count, 3)
        XCTAssertEqual(submenu?[0].title, "Open")
        XCTAssertTrue(submenu?[0].hasImage ?? false, "a Label's symbol reaches the item as an image")
        XCTAssertEqual(submenu?[0].keyEquivalent, "o")
        XCTAssertEqual(submenu?[0].modifiers, ["command"])
        XCTAssertTrue(submenu?[1].isSeparator ?? false)
        XCTAssertEqual(submenu?[2].title, "Framed")
        XCTAssertEqual(submenu?[2].state, "on", "the radio check is reported")
        XCTAssertNil(submenu?[2].submenu)

        XCTAssertTrue(items[1].isSeparator)
    }

    func testShapeProblemsFindLeadingTrailingAndDoubledSeparators() {
        func items(_ titles: [String]) -> [MenuDump.Item] {
            titles.map { title in
                MenuDump.Item(title: title, hasImage: false, keyEquivalent: "", modifiers: [],
                              state: "off", isSeparator: title == "—", enabled: true,
                              targetClass: nil, submenu: nil)
            }
        }
        XCTAssertEqual(MenuDump.shapeProblems("View", items(["A", "B"])), [])
        XCTAssertEqual(MenuDump.shapeProblems("View", items(["—", "A"])), ["View: leading separator"])
        XCTAssertEqual(MenuDump.shapeProblems("View", items(["A", "—"])), ["View: trailing separator"])
        XCTAssertEqual(MenuDump.shapeProblems("View", items(["A", "—", "—", "B"])),
                       ["View: separator 3 follows another"])
        // A submenu is reported under its parent's title.
        var parent = MenuDump.Item(title: "Density", hasImage: false, keyEquivalent: "", modifiers: [],
                                   state: "off", isSeparator: false, enabled: true,
                                   targetClass: nil, submenu: items(["—", "100%"]))
        parent.submenu = items(["—", "100%"])
        XCTAssertEqual(MenuDump.shapeProblems("View", [parent]), ["View/Density: leading separator"])
    }

    func testTheJSONCarriesTheShapeProblemsOfTheWholeBar() throws {
        let data = try MenuDump.json(makeMenu())
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // makeMenu's File submenu ends with an item, so the bar is clean.
        XCTAssertEqual(root["problems"] as? [String], [])
        let menu = makeMenu()
        let file = try XCTUnwrap(menu.items.first { $0.title == "File" }?.submenu)
        file.addItem(.separator())
        let broken = try XCTUnwrap(JSONSerialization.jsonObject(with: MenuDump.json(menu)) as? [String: Any])
        XCTAssertEqual(broken["problems"] as? [String], ["File: trailing separator"])
    }

    func testTheTargetsClassNamesTheItemsOwner() {
        let menu = NSMenu(title: "Main")
        let injected = NSMenuItem(title: "Injected", action: nil, keyEquivalent: "")
        injected.target = menu
        menu.addItem(injected)
        menu.addItem(NSMenuItem(title: "Plain", action: nil, keyEquivalent: ""))
        let items = MenuDump.snapshot(menu)
        XCTAssertEqual(items[0].targetClass, "NSMenu", "an item the app installed is owned by the app's type")
        XCTAssertNil(items[1].targetClass)
    }

    func testModifierNamesAreStableAndOrdered() {
        XCTAssertEqual(MenuDump.modifierNames([.option, .command]), ["command", "option"])
        XCTAssertEqual(MenuDump.modifierNames([.function]), ["function"])
        XCTAssertEqual(MenuDump.modifierNames([]), [])
    }

    func testJSONHasTheKeysTheChecksRead() throws {
        let data = try MenuDump.json(makeMenu())
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let items = try XCTUnwrap(root["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        let first = items[0]
        XCTAssertEqual(first["title"] as? String, "File")
        XCTAssertEqual(first["hasImage"] as? Bool, false)
        XCTAssertEqual(first["keyEquivalent"] as? String, "")
        XCTAssertEqual(first["modifiers"] as? [String], [])
        XCTAssertEqual(first["state"] as? String, "off")
        XCTAssertEqual(first["isSeparator"] as? Bool, false)
        let submenu = try XCTUnwrap(first["submenu"] as? [[String: Any]])
        XCTAssertEqual(submenu[0]["keyEquivalent"] as? String, "o")
        XCTAssertEqual(submenu[0]["modifiers"] as? [String], ["command"])
        XCTAssertEqual(submenu[2]["state"] as? String, "on")
    }
}
