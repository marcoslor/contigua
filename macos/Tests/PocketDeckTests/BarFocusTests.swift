// The mirror's bar from the keyboard (MIRROR-13, CONV-MAC-03): ⌃Tab takes the
// focus into the bar, ←/→ and Tab move between its buttons, Return and Space
// press, Esc and ⌃Tab come back to the picture. The machine is pure, so every
// edge is pinned here, including the keys that must NOT move the focus (Tab with
// the picture focused still types on Android) and a frozen bar with no buttons.

import AppKit
import XCTest
@testable import PocketDeck

final class BarFocusTests: XCTestCase {
    private let bar = [0, 1, 2, 3]

    func testControlTabEntersTheBarAndEscapeLeavesIt() {
        var focus = BarFocus()
        XCTAssertEqual(focus.state, .picture)
        XCTAssertEqual(focus.handle(.controlTab, focusable: bar), .focus(0))
        XCTAssertEqual(focus.state, .bar(0))
        XCTAssertEqual(focus.handle(.escape, focusable: bar), .picture)
        XCTAssertEqual(focus.state, .picture)
        // ⌃Tab is the way in and the way out.
        XCTAssertEqual(focus.handle(.controlTab, focusable: bar), .focus(0))
        XCTAssertEqual(focus.handle(.controlTab, focusable: bar), .picture)
        XCTAssertEqual(focus.state, .picture)
    }

    func testArrowsAndTabMoveBetweenTheButtonsAndWrap() {
        var focus = BarFocus()
        focus.handle(.controlTab, focusable: bar)
        XCTAssertEqual(focus.handle(.right, focusable: bar), .focus(1))
        XCTAssertEqual(focus.handle(.tab, focusable: bar), .focus(2))
        XCTAssertEqual(focus.handle(.right, focusable: bar), .focus(3))
        // Wrapping: the bar of four is a ring.
        XCTAssertEqual(focus.handle(.right, focusable: bar), .focus(0))
        XCTAssertEqual(focus.handle(.left, focusable: bar), .focus(3))
        XCTAssertEqual(focus.handle(.shiftTab, focusable: bar), .focus(2))
    }

    func testReturnAndSpacePressTheFocusedButtonAndStay() {
        var focus = BarFocus()
        focus.handle(.controlTab, focusable: bar)
        focus.handle(.right, focusable: bar)
        XCTAssertEqual(focus.handle(.activate, focusable: bar), .press(1))
        XCTAssertEqual(focus.state, .bar(1), "a press does not move the ring")
        XCTAssertEqual(focus.handle(.space, focusable: bar), .press(1))
        XCTAssertEqual(focus.state, .bar(1))
    }

    /// With the picture focused, every bar key but ⌃Tab is the phone's: Tab
    /// still types on Android, and Return, Esc and the arrows keep their phone
    /// meanings (MIRROR-13/CONV-MAC-03).
    func testThePictureKeepsItsOwnKeys() {
        var focus = BarFocus()
        for event in [BarFocus.Event.tab, .shiftTab, .left, .right, .activate,
                      .space, .escape] {
            XCTAssertNil(focus.handle(event, focusable: bar), "\(event) must reach the phone")
            XCTAssertEqual(focus.state, .picture)
        }
    }

    /// A frozen picture blocks every bar action whatever the machine returned
    /// (Live Text and the covers freeze all of them but Live Text's own button).
    func testAFrozenBarNeverActs() {
        var focus = BarFocus()
        focus.handle(.controlTab, focusable: bar)
        XCTAssertEqual(focus.handle(.activate, focusable: bar), .press(0))
        XCTAssertFalse(HeaderActionPolicy.isEnabled(.back, frozen: true))
        XCTAssertFalse(HeaderActionPolicy.isEnabled(.custom, frozen: true))
        XCTAssertTrue(HeaderActionPolicy.isEnabled(.liveText, frozen: true))
    }

    /// A frozen bar has no enabled buttons: ⌃Tab has nowhere to go, so the
    /// keyboard stays on the phone (the cover freezes it too).
    func testAFrozenBarTakesNoFocus() {
        var focus = BarFocus()
        XCTAssertNil(focus.handle(.controlTab, focusable: []))
        XCTAssertEqual(focus.state, .picture)
        // A button that vanished (the bar was rebuilt) starts at that end.
        focus.handle(.controlTab, focusable: [2, 3])
        XCTAssertEqual(focus.handle(.right, focusable: [3]), .focus(3))
    }

    /// The key map: only ⌃Tab enters; Tab and ⇧Tab are the bar's move keys once
    /// inside, and the phone's outside.
    func testTheKeyMap() {
        XCTAssertEqual(BarFocus.event(keyCode: 48, control: true, shift: false), .controlTab)
        XCTAssertEqual(BarFocus.event(keyCode: 48, control: false, shift: false), .tab)
        XCTAssertEqual(BarFocus.event(keyCode: 48, control: false, shift: true), .shiftTab)
        XCTAssertEqual(BarFocus.event(keyCode: 123, control: false, shift: false), .left)
        XCTAssertEqual(BarFocus.event(keyCode: 124, control: false, shift: false), .right)
        XCTAssertEqual(BarFocus.event(keyCode: 36, control: false, shift: false), .activate)
        XCTAssertEqual(BarFocus.event(keyCode: 76, control: false, shift: false), .activate)
        XCTAssertEqual(BarFocus.event(keyCode: 49, control: false, shift: false), .space)
        XCTAssertEqual(BarFocus.event(keyCode: 53, control: false, shift: false), .escape)
        XCTAssertNil(BarFocus.event(keyCode: 0, control: true, shift: false), "⌘A is not the bar's")
    }

    /// Every bar button says what it does, for the pointer and for VoiceOver
    /// (MIRROR-13/MIRROR-22, CONV-PD-09).
    func testEveryBarButtonNamesItsAction() {
        let actions = [HeaderAction.back {}, .home {}, .recents {},
                       HeaderAction(kind: .custom, customSymbol: "iphone", help: "Turn Off Phone Screen") {}]
        let barView = HeaderBarView(frame: NSRect(x: 0, y: 0, width: 128, height: 28))
        barView.setActions(actions, liveTextActive: false)
        XCTAssertEqual(barView.focusableIndices, [0, 1, 2, 3])
        for (index, action) in actions.enumerated() {
            let button = barView.button(for: action.kind)
            XCTAssertNotNil(button, "no button for \(action.help)")
            XCTAssertEqual(button?.toolTip, action.help, "the help tag names the action")
            XCTAssertEqual(button?.accessibilityLabel(), action.help, "VoiceOver reads the action")
            XCTAssertEqual(button?.accessibilityRole(), .button)
            XCTAssertTrue(button?.accessibilityHelp()?.contains(action.help) == true,
                          "the AX help names the action")
            XCTAssertTrue(button?.accessibilityHelp()?.contains("⌃Tab") == true,
                          "the AX help names the key that reaches the bar")
            XCTAssertEqual(barView.action(at: index)?.help, action.help)
        }
        // A frozen bar is skipped by the focus, never focused while disabled.
        barView.setFrozen(true)
        XCTAssertEqual(barView.focusableIndices, [], "a frozen bar has no focusable button")
    }

    /// The ring is drawn on the focused button only, and it survives a rebuild
    /// (the panel glyph changes the bar's actions).
    func testTheFocusRingFollowsTheBar() {
        let actions = [HeaderAction.back {}, .home {}, .recents {}]
        let barView = HeaderBarView(frame: NSRect(x: 0, y: 0, width: 96, height: 28))
        barView.setActions(actions, liveTextActive: false)
        barView.setFocus(1)
        let focused = (0..<3).compactMap { barView.button(for: actions[$0].kind) }
            .map(\.showsFocus)
        XCTAssertEqual(focused, [false, true, false])
        barView.setActions([HeaderAction.back {}, .home {}, .recents {}], liveTextActive: false)
        let afterRebuild = (0..<3).compactMap { barView.button(for: actions[$0].kind) }
            .map(\.showsFocus)
        XCTAssertEqual(afterRebuild, [false, true, false])
        barView.setFocus(nil)
        XCTAssertEqual((0..<3).compactMap { barView.button(for: actions[$0].kind) }
            .map(\.showsFocus), [false, false, false])
    }
}
