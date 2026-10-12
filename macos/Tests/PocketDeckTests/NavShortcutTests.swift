// Keyboard shortcuts -> protocol actions: Esc/⌘[ = back (Esc only when the
// window is focused with no sheet), ⇧⌘H = home and ⌘↑ = recents in phone mode.

import AppKit
import XCTest
@testable import PocketDeck

final class NavShortcutTests: XCTestCase {

    private enum Sent: Equatable {
        case nav(String)
        case key(UInt32)
        case text(String)
        case adjustDensity(Double)
        case resetDensity
        case touch
        case scroll
    }

    private func keyEvent(_ keyCode: UInt16, _ characters: String,
                          flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    private func mapper(phoneMode: Bool = false, escape: Bool = true) -> (InputMapper, () -> [Sent]) {
        let mapper = InputMapper(stream: 1)
        var sent: [Sent] = []
        mapper.isPhoneMode = phoneMode
        mapper.escapeAllowed = { escape }
        mapper.send = { command in
            switch command {
            case .nav(let action): sent.append(.nav(action))
            case .key: sent.append(.key(0))
            case .text(let text): sent.append(.text(text))
            case .adjustDensity(let delta): sent.append(.adjustDensity(delta))
            case .resetDensity: sent.append(.resetDensity)
            case .touch: sent.append(.touch)
            case .scroll: sent.append(.scroll)
            }
        }
        return (mapper, { sent })
    }

    // MARK: Back

    func testEscapeSendsBackWhenFocusedWithoutASheet() {
        let (map, sent) = mapper()
        map.keyDown(keyEvent(53, "\u{1b}"))
        XCTAssertEqual(sent(), [.nav("back")])
    }

    func testEscapeStaysLocalWhenTheWindowIsNotFocusedOrASheetIsOpen() {
        let (map, sent) = mapper(escape: false)
        map.keyDown(keyEvent(53, "\u{1b}"))
        XCTAssertTrue(sent().isEmpty)
    }

    func testCommandBracketSendsBack() {
        let (map, sent) = mapper()
        map.keyDown(keyEvent(33, "[", flags: [.command]))
        XCTAssertEqual(sent(), [.nav("back")])
    }

    func testCommandBracketSendsBackInPhoneModeToo() {
        let (map, sent) = mapper(phoneMode: true)
        map.keyDown(keyEvent(33, "[", flags: [.command]))
        XCTAssertEqual(sent(), [.nav("back")])
    }

    // MARK: Phone mode

    func testShiftCommandHSendsHomeOnlyInPhoneMode() {
        let (phone, phoneSent) = mapper(phoneMode: true)
        phone.keyDown(keyEvent(4, "H", flags: [.command, .shift]))
        XCTAssertEqual(phoneSent(), [.nav("home")])

        let (app, appSent) = mapper()
        app.keyDown(keyEvent(4, "H", flags: [.command, .shift]))
        XCTAssertTrue(appSent().isEmpty, "⇧⌘H must not reach a regular app window")
    }

    func testCommandUpArrowSendsRecentsOnlyInPhoneMode() {
        let (phone, phoneSent) = mapper(phoneMode: true)
        phone.keyDown(keyEvent(126, "\u{F700}", flags: [.command]))
        XCTAssertEqual(phoneSent(), [.nav("recents")])

        let (app, appSent) = mapper()
        app.keyDown(keyEvent(126, "\u{F700}", flags: [.command]))
        XCTAssertTrue(appSent().isEmpty, "⌘↑ must not reach a regular app window")
    }

    // MARK: Clicks stay

    /// Real NSEvents from synthesized CGEvents (like the e2e harness produces).
    private func mouse(_ type: CGEventType, button: CGMouseButton) -> NSEvent {
        let cg = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: button)!
        return NSEvent(cgEvent: cg)!
    }

    func testRightMouseDownStillSendsBack() {
        let (map, sent) = mapper()
        map.rightMouseDown(mouse(.rightMouseDown, button: .right))
        XCTAssertEqual(sent(), [.nav("back")])
    }

    func testMiddleMouseDownStillSendsHome() {
        let (map, sent) = mapper()
        map.otherMouseDown(mouse(.otherMouseDown, button: .center))
        XCTAssertEqual(sent(), [.nav("home")])
    }

    // MARK: Unrelated keys keep working

    func testPlainLetterStillBatchesText() {
        let (map, sent) = mapper()
        map.keyDown(keyEvent(0, "a"))
        map.flushText()
        XCTAssertEqual(sent(), [.text("a")])
    }

    func testShiftCommandHDoesNotTypeText() {
        let (phone, phoneSent) = mapper(phoneMode: true)
        phone.keyDown(keyEvent(4, "H", flags: [.command, .shift]))
        phone.flushText()
        XCTAssertEqual(phoneSent(), [.nav("home")], "the H must not also be typed")
    }
}
