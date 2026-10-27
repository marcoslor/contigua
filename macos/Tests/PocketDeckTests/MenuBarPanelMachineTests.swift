// The menu bar panel's modes (MenuBarPanel.swift): every transition, including
// the events that must be ignored, and the reported bug as one test.

import XCTest
@testable import PocketDeck

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
        assert(.closed, .iconSecondaryClick, becomes: .closed, actions: [.showMenu])
        assert(.closed, .clickOutside, becomes: .closed, actions: [])
        assert(.closed, .escape, becomes: .closed, actions: [])
        assert(.closed, .openWindow, becomes: .closed, actions: [])
        assert(.closed, .hideFinished, becomes: .closed, actions: [])

        // Open: the icon and every dismissal close it; the secondary click
        // closes it at once and still shows the menu.
        assert(.open, .iconClick, becomes: .closing, actions: [.hide])
        assert(.open, .iconSecondaryClick, becomes: .closed,
               actions: [.hideImmediately, .showMenu])
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
    }

    /// The person's right-click: with the panel open it closes first, at once,
    /// and the menu the person asked for still opens; with no panel it just
    /// opens. The panel is never left closing behind a menu.
    func testASecondaryClickClosesThePanelFirstThenShowsTheMenu() {
        var machine = MenuBarPanelMachine()
        XCTAssertEqual(machine.handle(.iconClick), [.show])
        XCTAssertEqual(machine.handle(.iconSecondaryClick), [.hideImmediately, .showMenu])
        XCTAssertEqual(machine.state, .closed)
        XCTAssertEqual(machine.handle(.iconSecondaryClick), [.showMenu])
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
}
