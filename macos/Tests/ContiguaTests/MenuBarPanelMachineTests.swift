// The menu bar panel (MenuBarPanel.swift): every mode transition, including the
// events that must be ignored, the reported bug as one test, which click is the
// secondary one, and the icon's menu.

import AppKit
import XCTest
@testable import Contigua

final class MenuBarPanelMachineTests: XCTestCase {
    private func machine(_ state: MenuBarPanelState) -> MenuBarPanelMachine {
        var machine = MenuBarPanelMachine()
        switch state {
        case .closed:
            break
        case .open:
            XCTAssertEqual(machine.handle(.iconClick), [.show])
        case .closing:
            XCTAssertEqual(machine.handle(.iconClick), [.show])
            XCTAssertEqual(machine.handle(.iconClick), [.hide])
        }
        XCTAssertEqual(machine.state, state)
        return machine
    }

    private func assert(_ state: MenuBarPanelState, _ event: MenuBarPanelEvent,
                        becomes next: MenuBarPanelState, actions: [MenuBarPanelAction],
                        file: StaticString = #filePath, line: UInt = #line) {
        var machine = machine(state)
        XCTAssertEqual(machine.handle(event), actions, "\(state) --\(event)-- actions", file: file, line: line)
        XCTAssertEqual(machine.state, next, "\(state) --\(event)-- state", file: file, line: line)
    }

    /// The reported bug: click opens, the same click again closes, and the
    /// next click opens it again — never a panel that stays open.
    func testIconClickTogglesThePanel() {
        var machine = MenuBarPanelMachine()
        XCTAssertEqual(machine.handle(.iconClick), [.show])
        XCTAssertEqual(machine.state, .open)
        XCTAssertEqual(machine.handle(.iconClick), [.hide])
        XCTAssertEqual(machine.state, .closing)
        XCTAssertEqual(machine.handle(.hideFinished), [])
        XCTAssertEqual(machine.state, .closed)
        XCTAssertEqual(machine.handle(.iconClick), [.show])
        XCTAssertEqual(machine.state, .open)
    }

    func testEveryTransition() {
        // Closed: only the icon opens it.
        assert(.closed, .iconClick, becomes: .open, actions: [.show])
        assert(.closed, .iconSecondaryClick, becomes: .closed, actions: [.showMenu(anchor: nil)])
        assert(.closed, .clickOutside, becomes: .closed, actions: [])
        assert(.closed, .escape, becomes: .closed, actions: [])
        assert(.closed, .openWindow, becomes: .closed, actions: [])
        assert(.closed, .hideFinished, becomes: .closed, actions: [])

        // Open: the icon and every dismissal close it; the secondary click
        // closes it at once and still shows the menu.
        assert(.open, .iconClick, becomes: .closing, actions: [.hide])
        assert(.open, .iconSecondaryClick, becomes: .closed,
               actions: [.hideImmediately, .showMenu(anchor: nil)])
        assert(.open, .clickOutside, becomes: .closing, actions: [.hide])
        assert(.open, .escape, becomes: .closing, actions: [.hide])
        assert(.open, .openWindow, becomes: .closing, actions: [.hide])
        assert(.open, .hideFinished, becomes: .open, actions: [])

        // Closing: only the animation's end finishes it; a second icon click
        // must not reopen the panel it is closing, and a second secondary
        // click must not stack a menu under the first.
        assert(.closing, .iconClick, becomes: .closing, actions: [])
        assert(.closing, .iconSecondaryClick, becomes: .closing, actions: [])
        assert(.closing, .clickOutside, becomes: .closing, actions: [])
        assert(.closing, .escape, becomes: .closing, actions: [])
        assert(.closing, .openWindow, becomes: .closing, actions: [])
        assert(.closing, .hideFinished, becomes: .closed, actions: [])

        // The card's gear is the secondary click with an anchor (PANEL-3):
        // the same states and actions, carrying the gear's screen rect.
        let gear = NSRect(x: 300, y: 500, width: 22, height: 22)
        assert(.closed, .gear(gear), becomes: .closed, actions: [.showMenu(anchor: gear)])
        assert(.open, .gear(gear), becomes: .closed,
               actions: [.hideImmediately, .showMenu(anchor: gear)])
        assert(.closing, .gear(gear), becomes: .closing, actions: [])
    }

    /// The person's right-click: with the panel open it closes first, at once,
    /// and the menu the person asked for still opens; with no panel it just
    /// opens. The panel is never left closing behind a menu.
    func testASecondaryClickClosesThePanelFirstThenShowsTheMenu() {
        var machine = MenuBarPanelMachine()
        XCTAssertEqual(machine.handle(.iconClick), [.show])
        XCTAssertEqual(machine.handle(.iconSecondaryClick), [.hideImmediately, .showMenu(anchor: nil)])
        XCTAssertEqual(machine.state, .closed)
        XCTAssertEqual(machine.handle(.iconSecondaryClick), [.showMenu(anchor: nil)])
        XCTAssertEqual(machine.state, .closed, "the menu is not the panel's open state")
        XCTAssertEqual(machine.handle(.iconClick), [.show])
        XCTAssertEqual(machine.state, .open)
    }

    /// A click while Closing leaves the panel on its way out: after the hide
    /// finishes it is Closed, whatever was clicked in between.
    func testAClickWhileClosingStillEndsClosed() {
        var machine = machine(.closing)
        XCTAssertEqual(machine.handle(.iconClick), [])
        XCTAssertEqual(machine.handle(.hideFinished), [])
        XCTAssertEqual(machine.state, .closed)
    }

    // MARK: - Which click

    /// A right-click opens the menu; a Control-click (a left click carrying ⌃)
    /// is the same request; every other left click still toggles the panel.
    func testTheSecondaryClickIsARightClickOrAControlClick() {
        XCTAssertEqual(MenuBarPanelClick.of(type: .rightMouseUp, modifiers: []), .secondary)
        XCTAssertEqual(MenuBarPanelClick.of(type: .rightMouseDown, modifiers: []), .primary)
        XCTAssertEqual(MenuBarPanelClick.of(type: .leftMouseUp, modifiers: [.control]), .secondary)
        XCTAssertEqual(MenuBarPanelClick.of(type: .leftMouseUp, modifiers: [.shift]), .primary)
        XCTAssertEqual(MenuBarPanelClick.of(type: .leftMouseUp, modifiers: []), .primary)
        XCTAssertEqual(MenuBarPanelClick.of(type: nil, modifiers: []), .primary)
        XCTAssertEqual(MenuBarPanelClick.of(type: nil, modifiers: [.control]), .secondary,
                       "the status item's action can arrive without an event; ⌃ still counts")
    }

    // MARK: - The menu

    /// The icon's menu is Settings… ⌘, · About Contigua · rule · Quit
    /// Contigua ⌘Q, in that order, with nothing enabled by the responder
    /// chain (the status item is outside the app's windows).
    func testTheIconMenuIsSettingsAboutQuit() throws {
        let target = NSObject()
        let menu = MenuBarMenu.make(target: target)
        XCTAssertEqual(menu.items.map(\.title),
                       [MenuBarMenu.settingsTitle, MenuBarMenu.aboutTitle, "",
                        MenuBarMenu.quitTitle])
        XCTAssertEqual(menu.items.map(\.keyEquivalent), [",", "", "", "q"])
        XCTAssertTrue(menu.items.allSatisfy { $0.keyEquivalentModifierMask.contains(.command) },
                      "both keys are ⌘ shortcuts (CONV-MAC-06)")
        XCTAssertEqual(menu.items[2].isSeparatorItem, true)
        XCTAssertEqual(menu.items.filter(\.isSeparatorItem).count, 1)
        XCTAssertFalse(menu.autoenablesItems, "the item's targets answer for themselves")
        for item in menu.items where !item.isSeparatorItem {
            XCTAssertTrue(item.target === target)
            XCTAssertNotNil(item.action)
        }
        XCTAssertEqual(Set(menu.items.compactMap(\.action)).count, 3, "one action per command")
    }
}

/// The gear's menu anchor (ISS-75): a pull-down opens under the control that
/// asked, kept inside the screen's visible frame.
final class MenuBarMenuAnchorTests: XCTestCase {
    private let visible = NSRect(x: 0, y: 0, width: 1280, height: 800)

    /// A gear with room to its right: the menu's top-left is the gear's
    /// bottom-left, so its top edge touches the button's bottom.
    func testAPullDownOpensUnderItsButton() {
        let gear = NSRect(x: 500, y: 600, width: 22, height: 22)
        let point = MenuBarMenuAnchor.pullDownPoint(under: gear, menuWidth: 180, in: visible)
        XCTAssertEqual(point, NSPoint(x: 500, y: 600))
    }

    /// The card sits under the status item, near the right edge: a menu that
    /// would leave the screen moves left, keeping the 8 pt margin.
    func testAPullDownNearTheRightEdgeMovesLeft() {
        let gear = NSRect(x: 1200, y: 600, width: 22, height: 22)
        let point = MenuBarMenuAnchor.pullDownPoint(under: gear, menuWidth: 180, in: visible)
        XCTAssertEqual(point, NSPoint(x: 1280 - 180 - 8, y: 600))
    }

    /// A button at or past the left edge still leaves the margin, and a zero
    /// menu width (before AppKit lays the menu out) never inverts the clamp.
    func testAPullDownNeverLeavesTheScreensMargin() {
        let left = NSRect(x: -30, y: 400, width: 22, height: 22)
        XCTAssertEqual(MenuBarMenuAnchor.pullDownPoint(under: left, menuWidth: 180, in: visible),
                       NSPoint(x: 8, y: 400))
        let wide = NSRect(x: 100, y: 400, width: 22, height: 22)
        XCTAssertEqual(MenuBarMenuAnchor.pullDownPoint(under: wide, menuWidth: 0, in: visible),
                       NSPoint(x: 100, y: 400))
    }
}
