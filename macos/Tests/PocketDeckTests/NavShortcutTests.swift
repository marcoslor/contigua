// Keyboard shortcuts and mouse-utility input -> protocol actions: Esc/⌘[ =
// back (the ⌘ once per press, no repeat while held; Esc only when the window
// is focused with no sheet), a .swipe event from mouse utilities with
// deltaX > 0 = back, ⇧⌘H = home and ⌘↑ = recents in phone mode.

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
                          flags: NSEvent.ModifierFlags = [], isARepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: isARepeat, keyCode: keyCode)!
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
            case .hover: break
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

    func testCommandBracketHeldSendsExactlyOneBack() {
        let (map, sent) = mapper()
        map.keyDown(keyEvent(33, "[", flags: [.command]))
        map.keyDown(keyEvent(33, "[", flags: [.command], isARepeat: true)) // a held ⌘[ fires repeats
        map.keyUp(keyEvent(33, "[", flags: [.command]))
        XCTAssertEqual(sent(), [.nav("back")], "the repeat and the release add nothing")
    }

    func testCommandBracketIsBackNeverAKey() {
        let (map, sent) = mapper()
        map.keyDown(keyEvent(33, "[", flags: [.command]))
        map.keyUp(keyEvent(33, "[", flags: [.command]))
        XCTAssertEqual(sent(), [.nav("back")], "exactly one nav back, no KEY frame for [ or its up")
    }

    // MARK: Mouse-utility swipe

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

    // MARK: Mouse side buttons

    /// An extra-button NSEvent (buttonNumber 2/3/4…) like the e2e helper posts
    /// with kCGEventOtherMouseDown and kCGMouseEventButtonNumber.
    private func otherMouse(_ type: CGEventType, number: Int) -> NSEvent {
        // The field, not the CGMouseButton enum (left/right/center), is what
        // NSEvent.buttonNumber reads, so set it for buttons 3/4.
        let cg = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .center)!
        cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(number))
        return NSEvent(cgEvent: cg)!
    }

    func testNavActionMapping() {
        XCTAssertEqual(InputMapper.navAction(forButton: 2), "home", "middle keeps what it does")
        XCTAssertEqual(InputMapper.navAction(forButton: 3), "back", "the usual side Back button")
        XCTAssertNil(InputMapper.navAction(forButton: 4), "the Forward button does nothing")
        XCTAssertNil(InputMapper.navAction(forButton: 0))
        XCTAssertNil(InputMapper.navAction(forButton: 1), "the right button has its own path")
        XCTAssertNil(InputMapper.navAction(forButton: 5))
    }

    func testSideBackButtonSendsExactlyOneBackNoTouch() {
        let (map, sent) = mapper()
        map.otherMouseDown(otherMouse(.otherMouseDown, number: 3))
        XCTAssertEqual(sent(), [.nav("back")], "one Back for the press, not a touch")
    }

    func testForwardButtonSendsNothing() {
        let (map, sent) = mapper()
        map.otherMouseDown(otherMouse(.otherMouseDown, number: 4))
        XCTAssertTrue(sent().isEmpty, "Forward is inert")
    }

    /// A held button drags and releases through the view: none of that may
    /// reach the mapper's touch path or repeat the nav from the down.
    func testOtherButtonDragAndReleaseNeverTouchOrRepeat() {
        let (map, sent) = mapper()
        let view = VideoLayerView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.inputMapper = map
        view.otherMouseDown(with: otherMouse(.otherMouseDown, number: 3))
        view.otherMouseDragged(with: otherMouse(.otherMouseDragged, number: 3))
        view.otherMouseDragged(with: otherMouse(.otherMouseDragged, number: 3))
        view.otherMouseUp(with: otherMouse(.otherMouseUp, number: 3))
        XCTAssertEqual(sent(), [.nav("back")], "down maps once; drag and release send nothing")
    }

    // MARK: Swipe navigation from mouse utilities

    /// NSEvent has no synthesizer for type .swipe (what mouse utilities send
    /// for a Back button), so the mapper takes the event's deltaX as the seam
    /// and `navAction(forSwipeDeltaX:)` is the tested mapping.
    func testSwipeDeltaMapping() {
        XCTAssertEqual(InputMapper.navAction(forSwipeDeltaX: 1.0), "back", "deltaX +1 is a swipe back")
        XCTAssertEqual(InputMapper.navAction(forSwipeDeltaX: 0.1), "back")
        XCTAssertNil(InputMapper.navAction(forSwipeDeltaX: -1.0), "deltaX −1 is forward and stays inert")
        XCTAssertNil(InputMapper.navAction(forSwipeDeltaX: -0.1))
        XCTAssertNil(InputMapper.navAction(forSwipeDeltaX: 0.0))
    }

    func testSwipeBackSendsExactlyOneBackNoTouch() {
        let (map, sent) = mapper()
        map.swipe(deltaX: 1.0)
        XCTAssertEqual(sent(), [.nav("back")], "one Back for the swipe, not a touch")
    }

    func testForwardSwipeSendsNothing() {
        let (map, sent) = mapper()
        map.swipe(deltaX: -1.0)
        XCTAssertTrue(sent().isEmpty, "swipe forward is inert, like the Forward button")
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
