import AppKit
import XCTest
@testable import PocketDeck

/// Live Text's input gate (InputMapper.inputSuspended): while the mode is on,
/// nothing reaches the phone through any input path, and Esc leaves the mode.
final class LiveTextInputGateTests: XCTestCase {

    private var mapper: InputMapper!
    private var commands: [InputMapper.Command] = []
    private var suspended = false
    private var escapes = 0

    override func setUp() {
        super.setUp()
        mapper = InputMapper(stream: 1)
        commands = []
        suspended = false
        escapes = 0
        mapper.send = { [weak self] command in self?.commands.append(command) }
        mapper.inputSuspended = { [weak self] in self?.suspended ?? false }
        mapper.onLiveTextEscape = { [weak self] in self?.escapes += 1 }
    }

    func testPointerAndClickAreDropped() {
        suspended = true
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
            mapper.mouseDown( event(type))
            mapper.mouseDragged( event(type))
            mapper.mouseUp( event(type))
        }
        mapper.rightMouseDown( event(.rightMouseDown))
        mapper.otherMouseDown( event(.otherMouseDown))
        mapper.swipe(deltaX: 1)
        mapper.edgeSwipeBack()
        XCTAssertTrue(commands.isEmpty, "\(commands.count) command(s) reached the phone")
    }

    func testScrollIsDropped() {
        suspended = true
        mapper.scroll(ScrollSample(phase: .changed, deltaY: 10), at: CGPoint(x: 10, y: 10))
        XCTAssertTrue(commands.isEmpty)
    }

    func testHoverIsDropped() {
        suspended = true
        mapper.hoverMove(at: CGPoint(x: 10, y: 10))
        mapper.hoverExit()
        XCTAssertTrue(commands.isEmpty)
    }

    func testKeyboardIsDroppedAndEscLeavesTheMode() {
        suspended = true
        mapper.keyDown( keyEvent("a", code: 0))
        mapper.keyUp( keyEvent("a", code: 0))
        mapper.keyDown( keyEvent("\u{1b}", code: InputMapper.keyCodeEscape))
        mapper.keyUp( keyEvent("\u{1b}", code: InputMapper.keyCodeEscape))
        XCTAssertTrue(commands.isEmpty, "keys reached the phone in the mode")
        XCTAssertEqual(escapes, 1, "Esc must leave the mode")
    }

    func testCommandShortcutsAreDropped() {
        suspended = true
        mapper.keyDown( keyEvent("c", code: 8, flags: [.command]))
        mapper.keyDown( keyEvent("v", code: 9, flags: [.command]))
        XCTAssertTrue(commands.isEmpty)
    }

    /// R6 follow-up: the frozen frame must not kill the bar's keys or the
    /// paste pill's Esc. Both are local UI and run before the phone gate.
    func testBarAndOverlayKeysSurviveTheFrozenFrame() {
        suspended = true
        var barKeys = 0
        var barUp = 0
        var overlayKeys = 0
        mapper.barKey = { _ in barKeys += 1; return true }
        mapper.barKeyUp = { _ in barUp += 1; return true }
        mapper.overlayKey = { _ in overlayKeys += 1; return true }

        mapper.keyDown(keyEvent("x", code: 7))
        mapper.keyUp(keyEvent("x", code: 7))
        XCTAssertEqual(barKeys, 1, "the bar must see its key while frozen")
        XCTAssertEqual(barUp, 1, "the bar must see the release too")
        XCTAssertEqual(overlayKeys, 0, "the bar consumed it first")
        XCTAssertTrue(commands.isEmpty)

        // The bar declines Esc; the paste pill takes it before Live Text.
        mapper.barKey = { _ in false }
        mapper.keyDown(keyEvent("\u{1b}", code: InputMapper.keyCodeEscape))
        XCTAssertEqual(overlayKeys, 1, "the paste pill's Esc must still dismiss")
        XCTAssertEqual(escapes, 0, "the overlay consumed Esc before the mode")
        XCTAssertTrue(commands.isEmpty)
    }

    func testTrackpadGesturesAreDropped() {
        suspended = true
        let fingers = [TrackpadFinger(id: 1, x: 0.4, y: 0.5), TrackpadFinger(id: 2, x: 0.6, y: 0.5)]
        mapper.trackpadFingers(fingers, surface: .fallback, cursor: .zero)
        mapper.magnify(phase: .began, magnification: 0, at: .zero)
        mapper.rotate(phase: .changed, rotation: 5, at: .zero)
        mapper.smartMagnify(at: .zero)
        XCTAssertTrue(commands.isEmpty)
    }

    func testNothingChangesWhenTheGateIsOff() {
        mapper.mouseDown( event(.leftMouseDown))
        mapper.mouseUp( event(.leftMouseUp))
        mapper.keyDown( keyEvent("a", code: 0))
        mapper.flushText()
        XCTAssertEqual(commands.count, 3, "click down, click up and text must pass with the gate off")
        XCTAssertEqual(escapes, 0)
    }

    func testDropPendingInputSendsNoPendingText() {
        mapper.keyDown( keyEvent("h", code: 4))
        mapper.keyDown( keyEvent("i", code: 34))
        mapper.dropPendingInput()
        mapper.flushText()
        XCTAssertTrue(commands.isEmpty)
    }

    func testEnteringMidDragCancelsTheHeldTouch() {
        mapper.mouseDown( event(.leftMouseDown))
        mapper.mouseDragged( event(.leftMouseDragged))
        suspended = true
        commands = []
        mapper.dropPendingInput()
        guard case .touch(let touch)? = commands.first, commands.count == 1 else {
            return XCTFail("expected one touch cancel, got \(commands.count) command(s)")
        }
        XCTAssertEqual(touch.action, .cancel)
        mapper.mouseUp( event(.leftMouseUp))
        XCTAssertEqual(commands.count, 1, "the release under the frozen frame reaches nothing")
    }

    // MARK: Helpers

    private func event(_ type: NSEvent.EventType, at point: CGPoint = CGPoint(x: 10, y: 10)) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: 0, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: 1)!
    }

    private func keyEvent(_ characters: String, code: UInt16,
                     flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false,
                         keyCode: code)!
    }
}
