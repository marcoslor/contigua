// Settings ▸ Input "Secondary click (two-finger click)" (SecondaryClick): the
// default is Long press — the touch goes down at the click and stays down for
// Android's long-press timeout, so the app's context menu opens; a drag while
// held moves the touch, before the hold only records the point. Back and
// Nothing are the other choices.

import AppKit
import XCTest
@testable import PocketDeck

final class SecondaryClickTests: XCTestCase {
    private var scheduled: (() -> Void)?

    private func makeMapper(_ setting: SecondaryClick) -> (InputMapper, () -> [String]) {
        let mapper = InputMapper(stream: 1)
        var log: [String] = []
        mapper.secondaryClick = { setting }
        mapper.locationProvider = { _ in CGPoint(x: 50, y: 50) }
        mapper.videoRectProvider = { CGRect(x: 0, y: 0, width: 100, height: 100) }
        mapper.viewIsFlipped = { false }
        scheduled = nil
        mapper.scheduleSecondaryLongPress = { [weak self] work in self?.scheduled = work }
        mapper.send = { command in
            switch command {
            case .touch(let event):
                switch event.action {
                case .down: log.append("down")
                case .up: log.append("up")
                case .move: log.append("move")
                case .cancel: log.append("cancel")
                }
            case .nav(let action): log.append("nav:\(action)")
            default: break
            }
        }
        return (mapper, { log })
    }

    private func rightMouse(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1,
                           pressure: 1)!
    }

    func testLongPressIsTheDefaultSetting() {
        let name = "dev.pocketdeck.tests.secondary.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(SecondaryClick.stored(in: defaults), .longPress)
        defaults.set(SecondaryClick.back.rawValue, forKey: SecondaryClick.key)
        XCTAssertEqual(SecondaryClick.stored(in: defaults), .back)
        defaults.set("nonsense", forKey: SecondaryClick.key)
        XCTAssertEqual(SecondaryClick.stored(in: defaults), .longPress, "an unreadable value is the default")
    }

    /// A quick two-finger click still becomes a long press: down now, up only
    /// after the hold, so Android's long-press detector fires.
    func testAQuickClickHoldsTheTouchToTheLongPressTimeout() {
        let (map, log) = makeMapper(.longPress)
        map.rightMouseDown(rightMouse(.rightMouseDown))
        XCTAssertEqual(log(), ["down"])
        map.rightMouseUp(rightMouse(.rightMouseUp))
        XCTAssertEqual(log(), ["down"], "the release waits for the hold")

        let hold = scheduled
        XCTAssertNotNil(hold, "the long press is scheduled")
        hold?()
        XCTAssertEqual(log(), ["down", "up"], "the hold ends the touch")
    }

    func testAHeldClickEndsAsSoonAsTheButtonIsReleased() {
        let (map, log) = makeMapper(.longPress)
        map.rightMouseDown(rightMouse(.rightMouseDown))
        scheduled?()
        XCTAssertEqual(log(), ["down"], "still held: no touch up")
        map.rightMouseUp(rightMouse(.rightMouseUp))
        XCTAssertEqual(log(), ["down", "up"])
    }

    /// A drag while the button is held moves the touch after the long press;
    /// before it, the point is remembered (a move would cancel the detector).
    func testADragWhileHeldMovesTheTouchAfterTheLongPress() {
        let (map, log) = makeMapper(.longPress)
        map.rightMouseDown(rightMouse(.rightMouseDown))
        map.rightMouseDragged(rightMouse(.rightMouseDragged))
        XCTAssertEqual(log(), ["down"], "a move before the hold reaches the phone as nothing")
        scheduled?()
        XCTAssertEqual(log(), ["down", "move"], "the held point moves once the long press is reached")
        map.rightMouseDragged(rightMouse(.rightMouseDragged))
        XCTAssertEqual(log(), ["down", "move", "move"])
        map.rightMouseUp(rightMouse(.rightMouseUp))
        XCTAssertEqual(log(), ["down", "move", "move", "up"])
    }

    func testBackSettingSendsOneBackAndNoTouch() {
        let (map, log) = makeMapper(.back)
        map.rightMouseDown(rightMouse(.rightMouseDown))
        map.rightMouseUp(rightMouse(.rightMouseUp))
        XCTAssertEqual(log(), ["nav:back"])
        XCTAssertNil(scheduled)
    }

    func testNothingSettingSendsNothing() {
        let (map, log) = makeMapper(.nothing)
        map.rightMouseDown(rightMouse(.rightMouseDown))
        map.rightMouseUp(rightMouse(.rightMouseUp))
        XCTAssertTrue(log().isEmpty)
        XCTAssertNil(scheduled)
    }
}
