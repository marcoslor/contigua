import XCTest
@testable import PocketDeck

/// The panel's volume slider is a small state machine, not a binding onto the
/// phone's last echo (docs/design/mac-redesign.md §3.8): while the person drags,
/// the thumb and the % follow the pointer; the phone's replies are ignored until
/// the drag ends. When the phone echoes the value that was sent, the machine is
/// idle again. A phone that never echoes gives up after a second and its value
/// wins.
final class PhoneVolumeTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private let quantum = 1.0 / 30.0

    private func machine(_ shown: Double = 0.4) -> PhoneVolumeControl {
        var control = PhoneVolumeControl()
        control.sync(phone: shown, tolerance: quantum, at: t0)
        return control
    }

    func testIdleShowsThePhoneValue() {
        var control = machine()
        XCTAssertEqual(control.phase, .idle)
        XCTAssertEqual(control.display, 0.4, accuracy: 0.0001)
        control.sync(phone: 0.2, tolerance: quantum, at: t0)
        XCTAssertEqual(control.display, 0.2, accuracy: 0.0001)
        XCTAssertEqual(control.phase, .idle)
    }

    func testDraggingFollowsEveryStepAndIgnoresThePhoneEcho() {
        var control = machine(0.4)
        control.begin(at: t0)
        XCTAssertTrue(control.drag(to: 0.2, at: t0))
        XCTAssertEqual(control.display, 0.2, accuracy: 0.0001)
        // The phone answers the first send with its old value while the person
        // is still dragging: the thumb must not jump back.
        control.sync(phone: 0.4, tolerance: quantum, at: t0.addingTimeInterval(0.01))
        XCTAssertEqual(control.display, 0.2, accuracy: 0.0001)
        XCTAssertEqual(control.phase, .dragging)

        // 50 ms later: no second send, but the thumb still follows.
        XCTAssertFalse(control.drag(to: 0.3, at: t0.addingTimeInterval(0.05)))
        XCTAssertEqual(control.display, 0.3, accuracy: 0.0001)
        control.sync(phone: 0.2, tolerance: quantum, at: t0.addingTimeInterval(0.06))
        XCTAssertEqual(control.display, 0.3, accuracy: 0.0001)
        XCTAssertEqual(control.phase, .dragging)
    }

    func testTheDragSendsAtMostTenTimesASecondAndAlwaysSendsTheRelease() {
        var control = machine(0.4)
        control.begin(at: t0)
        var sends = 0
        // Ten pointer steps over 200 ms: sends at 0, 100 and 200 ms.
        for step in 0...10 {
            let now = t0.addingTimeInterval(Double(step) / 50)
            if control.drag(to: Double(step) / 10, at: now) { sends += 1 }
        }
        XCTAssertEqual(sends, 3, "one send per 100 ms")
        XCTAssertEqual(control.end(at: t0.addingTimeInterval(0.21)), 1.0)
        XCTAssertEqual(control.phase, .settling(sent: 1.0,
                                               since: t0.addingTimeInterval(0.21)))
    }

    func testSettlingShowsTheSentValueUntilThePhoneEchoesIt() {
        var control = machine(0.4)
        control.begin(at: t0)
        _ = control.drag(to: 0.2, at: t0)
        XCTAssertEqual(control.end(at: t0.addingTimeInterval(0.2)), 0.2)
        // A reply that is not the sent value (the phone still had 0.4) does not
        // move the thumb while settling.
        control.sync(phone: 0.4, tolerance: quantum, at: t0.addingTimeInterval(0.25))
        XCTAssertEqual(control.display, 0.2, accuracy: 0.0001)
        XCTAssertEqual(control.phase, .settling(sent: 0.2, since: t0.addingTimeInterval(0.2)))
        // The matching echo (3/15 for 0.2) ends settling.
        control.sync(phone: 0.2, tolerance: quantum, at: t0.addingTimeInterval(0.3))
        XCTAssertEqual(control.phase, .idle)
        XCTAssertEqual(control.display, 0.2, accuracy: 0.0001)
    }

    func testAfterOneSecondThePhonesDifferentValueWins() {
        var control = machine(0.4)
        control.begin(at: t0)
        _ = control.drag(to: 0.5, at: t0)
        _ = control.end(at: t0)
        control.sync(phone: 0.4, tolerance: quantum, at: t0.addingTimeInterval(0.9))
        XCTAssertEqual(control.display, 0.5, accuracy: 0.0001)
        XCTAssertTrue(control.expire(at: t0.addingTimeInterval(1.0), phone: 0.4))
        XCTAssertEqual(control.phase, .idle)
        XCTAssertEqual(control.display, 0.4, accuracy: 0.0001)
    }

    func testAPhoneEchoDuringTheDragDoesNotEndIt() {
        var control = machine(0.4)
        control.begin(at: t0)
        _ = control.drag(to: 0.6, at: t0)
        control.sync(phone: 0.6, tolerance: quantum, at: t0.addingTimeInterval(0.01))
        XCTAssertEqual(control.phase, .dragging)
        _ = control.drag(to: 0.65, at: t0.addingTimeInterval(0.02))
        XCTAssertEqual(control.display, 0.65, accuracy: 0.0001)
    }

    func testAValueOutsideTheRangeIsClamped() {
        var control = machine(0.4)
        control.sync(phone: 1.4, tolerance: quantum, at: t0)
        XCTAssertEqual(control.display, 1.0)
        control.sync(phone: -0.3, tolerance: quantum, at: t0)
        XCTAssertEqual(control.display, 0.0)
    }
}
