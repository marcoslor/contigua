// The resize request coalescer: what the Mac may send, when. A person's burst
// of ⌘+/⌘- presses, or a resize during a reconfigure, used to send every value
// and re-attach the phone's encoder once per press; overlapping attaches lose
// frames (the 10-27 report: 7 s with no frame). The machine below is the rule:
// one request in flight, at most one pending (latest wins), and nothing is ever
// sent twice.

import XCTest
@testable import PocketDeck

final class ResizeCoalescerTests: XCTestCase {
    private let a = ResizeRequest(w: 1600, h: 1200, dpi: 240)
    private let b = ResizeRequest(w: 1600, h: 1200, dpi: 300)
    private let c = ResizeRequest(w: 1600, h: 1200, dpi: 360)

    /// The requests a transition wants sent.
    private func sent(_ actions: [ResizeCoalescer.Action]) -> [ResizeRequest] {
        actions.compactMap {
            if case .send(let request) = $0 { return request }
            return nil
        }
    }

    private func idle(_ last: ResizeRequest? = nil) -> ResizeCoalescer {
        var machine = ResizeCoalescer()
        machine.reset(to: last)
        return machine
    }

    func testTheFirstRequestGoesOutAndIsInFlight() {
        var machine = idle()
        XCTAssertEqual(machine.apply(.request(a)), [.send(a)])
        XCTAssertEqual(machine.state, .inFlight(a, pending: nil))
    }

    func testAPressThatAsksForTheValueAlreadySentIsANoOp() {
        var machine = idle()
        XCTAssertEqual(machine.apply(.request(a)), [.send(a)])
        XCTAssertEqual(machine.apply(.settled(a)), [])
        XCTAssertEqual(machine.state, .idle(last: a))
        // The clamp: ⌘+ at the top sends nothing at all.
        XCTAssertEqual(machine.apply(.request(a)), [])
        XCTAssertEqual(machine.state, .idle(last: a), "the no-op leaves the state alone")
    }

    func testAPressEqualToTheRequestInFlightSendsNothing() {
        var machine = idle()
        _ = machine.apply(.request(a))
        XCTAssertEqual(machine.apply(.request(a)), [])
        XCTAssertEqual(machine.state, .inFlight(a, pending: nil))
    }

    func testABurstKeepsOnlyTheLatestPendingValue() {
        var machine = idle()
        XCTAssertEqual(machine.apply(.request(a)), [.send(a)])
        XCTAssertEqual(machine.apply(.request(b)), [], "a second value waits for the first")
        XCTAssertEqual(machine.state, .inFlight(a, pending: b))
        XCTAssertEqual(machine.apply(.request(c)), [], "a third replaces the second: latest wins")
        XCTAssertEqual(machine.state, .inFlight(a, pending: c))
        XCTAssertEqual(machine.apply(.request(b)), [], "an older pending value is not re-admitted")
        XCTAssertEqual(machine.state, .inFlight(a, pending: b))
    }

    func testThePendingValueGoesOutWhenThePhoneSettlesTheOneInFlight() {
        var machine = idle()
        _ = machine.apply(.request(a))
        _ = machine.apply(.request(b))
        XCTAssertEqual(machine.apply(.settled(a)), [.send(b)])
        XCTAssertEqual(machine.state, .inFlight(b, pending: nil))
    }

    func testASettleWithNothingPendingGoesIdle() {
        var machine = idle()
        _ = machine.apply(.request(a))
        XCTAssertEqual(machine.apply(.settled(a)), [])
        XCTAssertEqual(machine.state, .idle(last: a))
    }

    func testASettleForAnotherRequestIsIgnored() {
        var machine = idle()
        _ = machine.apply(.request(a))
        // A late answer for the stream's old size (or its open) is not this
        // request's ack: sending the pending value on it would overlap attaches.
        XCTAssertEqual(machine.apply(.settled(b)), [])
        XCTAssertEqual(machine.state, .inFlight(a, pending: nil))
        _ = machine.apply(.request(b))
        XCTAssertEqual(machine.apply(.settled(c)), [])
        XCTAssertEqual(machine.state, .inFlight(a, pending: b))
    }

    func testASettleWhileIdleChangesNothing() {
        var machine = idle()
        XCTAssertEqual(machine.apply(.settled(a)), [])
        XCTAssertEqual(machine.state, .idle(last: nil))
        _ = machine.apply(.request(b))
        _ = machine.apply(.settled(b))
        XCTAssertEqual(machine.apply(.settled(a)), [])
        XCTAssertEqual(machine.state, .idle(last: b), "the last sent value is what a repeat is measured against")
    }

    func testAWindowReopenForgetsTheLastValue() {
        var machine = idle()
        _ = machine.apply(.request(a))
        _ = machine.apply(.settled(a))
        // A fresh `window.open` sizes the stream itself: the first resize after
        // it may repeat the size the display already has.
        XCTAssertEqual(machine.apply(.reset), [])
        XCTAssertEqual(machine.state, .idle(last: nil))
        XCTAssertEqual(machine.apply(.request(a)), [.send(a)])
    }

    func testABurstOfTenPressesSendsOneRequestPerNewValueAndNothingAtTheClamp() {
        var machine = idle()
        var went: [ResizeRequest] = []
        // 100% → 125% → 150% (the clamp), then eight presses that ask for 150%
        // again, each answered before the next press.
        for request in [a, b, c, c, c, c, c, c, c, c] {
            went += sent(machine.apply(.request(request)))
            went += sent(machine.apply(.settled(request)))
        }
        XCTAssertEqual(went, [a, b, c], "no press after the clamp sends anything")
    }

    func testABurstOfTenPressesWithNoAcksSendsOneAndKeepsTheLast() {
        var machine = idle()
        var went: [ResizeRequest] = []
        for request in [a, b, c, b, a, c, b, a, c, b] {
            went += sent(machine.apply(.request(request)))
        }
        XCTAssertEqual(went, [a], "one in flight for the whole burst")
        XCTAssertEqual(machine.state, .inFlight(a, pending: b))
        XCTAssertEqual(machine.apply(.settled(a)), [.send(b)], "then exactly one more: the last value")
    }

    func testALostAckStillLetsTheLatestValueThroughOnTheNextSettle() {
        var machine = idle()
        _ = machine.apply(.request(a))
        _ = machine.apply(.request(b))
        // The phone reports a no-op for `a` (it was already there); the pending
        // value must still go out.
        XCTAssertEqual(machine.apply(.settled(a)), [.send(b)])
    }

    // MARK: The stall bound (a phone that answers nothing)

    func testATimeoutWithAValueWaitingSendsIt() {
        var machine = idle()
        _ = machine.apply(.request(a))
        _ = machine.apply(.request(b))
        // No ack and no CONFIG is coming: an old phone, a paused stream, a
        // refused resize. The window must not stay stuck on `a`.
        XCTAssertEqual(machine.apply(.settleTimeout), [.send(b)])
        XCTAssertEqual(machine.state, .inFlight(b, pending: nil))
    }

    func testATimeoutWithNothingWaitingGoesIdle() {
        var machine = idle()
        _ = machine.apply(.request(a))
        XCTAssertEqual(machine.apply(.settleTimeout), [])
        XCTAssertEqual(machine.state, .idle(last: a))
    }

    func testATimeoutWhileIdleChangesNothing() {
        var machine = idle(a)
        XCTAssertEqual(machine.apply(.settleTimeout), [])
        XCTAssertEqual(machine.state, .idle(last: a))
    }

    func testAnAckThatArrivesAfterTheTimeoutIsIgnored() {
        var machine = idle()
        _ = machine.apply(.request(a))
        _ = machine.apply(.request(b))
        XCTAssertEqual(machine.apply(.settleTimeout), [.send(b)])
        // The phone's answer to `a` is late: it must not settle `b` (that would
        // overlap two encoder re-attaches) and must not send anything.
        XCTAssertEqual(machine.apply(.settled(a)), [])
        XCTAssertEqual(machine.state, .inFlight(b, pending: nil))
    }

    func testAnAckAfterATimeoutWithNothingWaitingIsIgnored() {
        var machine = idle()
        _ = machine.apply(.request(a))
        _ = machine.apply(.settleTimeout)
        XCTAssertEqual(machine.apply(.settled(a)), [])
        XCTAssertEqual(machine.state, .idle(last: a))
        // The value the phone did apply is what a repeat is measured against.
        XCTAssertEqual(machine.apply(.request(a)), [])
    }

    func testTheTimeoutIsTheStallLimitNotADebounce() {
        // NFR `density_burst_stall_ms` (docs/NFR.md): the same 1.5 s the
        // window's own "Not responding" rule uses.
        XCTAssertEqual(StreamWindowController.resizeSettleTimeout, 1.5)
        XCTAssertEqual(StreamWindowController.resizeSettleTimeout, FrameWatchdog.staleAfter)
    }
}
