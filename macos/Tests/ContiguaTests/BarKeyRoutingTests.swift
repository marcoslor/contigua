// Where a key goes in a stream window (MIRROR-13): Tab is the phone's until
// ⌃Tab hands the keyboard to the bar, and while the bar has it none of the
// bar's keys reach the phone. BarFocus decides; the InputMapper passes the keys
// through its own gate, which is what these tests drive.

import AppKit
import XCTest
@testable import Contigua

final class BarKeyRoutingTests: XCTestCase {
    private enum Sent: Equatable { case key(UInt16), nav(String) }

    private func keyEvent(_ keyCode: UInt16, _ characters: String,
                          flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false,
                         keyCode: keyCode)!
    }

    /// The machine the mapper's gate reads: escaping closures cannot capture an
    /// `inout`, and the window's own machine lives in the controller.
    private final class FocusBox {
        var focus = BarFocus()
    }

    /// A mapper whose bar gate is this machine, as the window wires it.
    private func mapper(_ box: FocusBox, focusable: [Int] = [0, 1, 2, 3])
        -> (InputMapper, () -> [Sent]) {
        let map = InputMapper(stream: 1)
        map.isPhoneMode = true
        var sent: [Sent] = []
        map.send = { command in
            switch command {
            case .key(let key): sent.append(.key(UInt16(key.keycode)))
            case .nav(let action): sent.append(.nav(action))
            default: break
            }
        }
        map.barKey = { event in
            guard let barEvent = BarFocus.event(keyCode: event.keyCode,
                                                control: event.modifierFlags.contains(.control),
                                                shift: event.modifierFlags.contains(.shift))
            else { return false }
            return box.focus.route(barEvent, focusable: focusable).consumed
        }
        map.barKeyUp = { event in
            guard box.focus.isOnBar else { return false }
            return BarFocus.event(keyCode: event.keyCode,
                                  control: event.modifierFlags.contains(.control),
                                  shift: event.modifierFlags.contains(.shift)) != nil
        }
        return (map, { sent })
    }

    func testTabReachesThePhoneUntilTheBarHasTheFocus() {
        let box = FocusBox()
        let (map, sent) = mapper(box)
        map.keyDown(keyEvent(48, "\t"))
        XCTAssertEqual(sent(), [.key(61)], "a bare Tab is Android's")
        XCTAssertEqual(box.focus.state, .picture)
    }

    func testControlTabTakesTheKeyboardAndNeverReachesThePhone() {
        let box = FocusBox()
        let (map, sent) = mapper(box)
        map.keyDown(keyEvent(48, "\t", flags: [.control]))
        XCTAssertEqual(sent(), [], "⌃Tab is the Mac's key")
        XCTAssertEqual(box.focus.state, .bar(0))
    }

    /// While the bar has the focus, Return, the arrows, Tab and Esc do nothing
    /// on the phone: Return presses instead, and Esc comes back to the picture
    /// without sending Back.
    func testTheBarsKeysDoNotReachThePhone() {
        let box = FocusBox()
        let (map, sent) = mapper(box)
        map.keyDown(keyEvent(48, "\t", flags: [.control]))
        // Return and Space press without moving; ← wraps Back to the last
        // button, → comes back, Tab goes forward.
        let steps: [(UInt16, String, BarFocus.State)] = [
            (36, "\r", .bar(0)), (49, " ", .bar(0)), (123, "\u{F702}", .bar(3)),
            (124, "\u{F703}", .bar(0)), (48, "\t", .bar(1)),
        ]
        for (code, characters, expected) in steps {
            map.keyDown(keyEvent(code, characters))
            XCTAssertEqual(box.focus.state, expected, "key \(code)")
        }
        XCTAssertEqual(sent(), [])
        // Esc leaves the bar: no Back, and the phone's keys are its own again.
        map.keyDown(keyEvent(53, "\u{1b}"))
        XCTAssertEqual(sent(), [])
        XCTAssertEqual(box.focus.state, .picture)
        map.keyDown(keyEvent(53, "\u{1b}"))
        XCTAssertEqual(sent(), [.nav("back")], "on the picture Esc is Back again")
    }
}
