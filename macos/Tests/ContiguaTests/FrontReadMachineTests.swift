// The shared `task.front` budget as a pure machine (PROTOCOL.md "Foreground
// app" §3, MCP-32, PANEL-26; #266 item 2): one test per transition.

import XCTest
@testable import Contigua

final class FrontReadMachineTests: XCTestCase {
    private typealias M = FrontReadMachine
    private let t0 = ContinuousClock.now

    private func at(_ ms: Int) -> ContinuousClock.Instant { t0 + .milliseconds(ms) }

    /// A machine with a request out, asked at `ms`.
    private func out(at ms: Int = 0) -> M {
        M.step(M(), .ask(now: at(ms))).0
    }

    /// A machine whose request (asked at `ms`) was answered `read`.
    private func answered(_ read: FrontRead = .pkg("org.example.maps"), at ms: Int = 0) -> M {
        let machine = out(at: ms)
        switch read {
        case .pkg(let pkg): return M.step(machine, .reply(seq: machine.seq, pkg: pkg)).0
        case .none: return M.step(machine, .reply(seq: machine.seq, pkg: nil)).0
        case .notSupported: return M.step(machine, .unavailable).0
        case .timeout: return machine
        }
    }

    // MARK: ask

    func testAnAskWithNoRequestSendsOne_MCP32() {
        let (next, actions) = M.step(M(), .ask(now: at(0)))
        XCTAssertEqual(next.seq, 1)
        XCTAssertEqual(next.phase, .out(at: at(0)))
        XCTAssertEqual(actions, [.send(seq: 1)])
    }

    func testAnAskUnder2sAfterARequestOutSendsNothing_MCP32() {
        let machine = out()
        let (next, actions) = M.step(machine, .ask(now: at(1999)))
        XCTAssertEqual(next, machine)
        XCTAssertEqual(actions, [])
    }

    func testAnAskUnder2sAfterAnAnswerSendsNothing_MCP32() {
        let machine = answered()
        let (next, actions) = M.step(machine, .ask(now: at(1999)))
        XCTAssertEqual(next, machine)
        XCTAssertEqual(actions, [])
    }

    func testAnAsk2sAfterARequestOutSendsANewOne_MCP32() {
        let (next, actions) = M.step(out(), .ask(now: at(2000)))
        XCTAssertEqual(next.seq, 2)
        XCTAssertEqual(next.phase, .out(at: at(2000)))
        XCTAssertEqual(actions, [.send(seq: 2)])
    }

    func testAnAsk2sAfterAnAnswerSendsANewOne_MCP32() {
        let (next, actions) = M.step(answered(), .ask(now: at(2000)))
        XCTAssertEqual(next.seq, 2)
        XCTAssertEqual(next.phase, .out(at: at(2000)))
        XCTAssertEqual(actions, [.send(seq: 2)])
    }

    /// PANEL-26 (#266 item 1): the card's next ask is due 2 s after the last
    /// request, whoever sent it.
    func testTheNextAskIsDue2sAfterTheLastRequest_PANEL26() {
        XCTAssertNil(M().nextAsk)
        XCTAssertEqual(out(at: 500).nextAsk, at(2500))
        XCTAssertEqual(answered(at: 700).nextAsk, at(2700))
        XCTAssertNil(M.step(out(), .reset).0.nextAsk)
    }

    // MARK: read

    func testAReadWithNoRequestSendsOneAndWaits_MCP32() {
        let (next, actions) = M.step(M(), .read(waiter: 7, now: at(0)))
        XCTAssertEqual(next.seq, 1)
        XCTAssertEqual(next.waiters, [7: 1])
        XCTAssertEqual(actions, [.send(seq: 1), .startTimer(waiter: 7)])
    }

    func testAReadWhileARequestIsOutWaitsForIt_MCP32() {
        let (next, actions) = M.step(out(), .read(waiter: 7, now: at(1000)))
        XCTAssertEqual(next.seq, 1)
        XCTAssertEqual(next.waiters, [7: 1])
        XCTAssertEqual(actions, [.startTimer(waiter: 7)])
    }

    func testAReadUnder2sAfterAnAnswerReusesIt_MCP32() {
        let machine = answered(.pkg("org.example.maps"))
        let (next, actions) = M.step(machine, .read(waiter: 7, now: at(1900)))
        XCTAssertEqual(next, machine)
        XCTAssertEqual(actions, [.answer(waiter: 7, .pkg("org.example.maps"))])
    }

    func testAReadAfter2sAsksAgain_MCP32() {
        let (next, actions) = M.step(answered(), .read(waiter: 7, now: at(2000)))
        XCTAssertEqual(next.seq, 2)
        XCTAssertEqual(next.waiters, [7: 2])
        XCTAssertEqual(actions, [.send(seq: 2), .startTimer(waiter: 7)])
    }

    // MARK: reply

    func testTheNewestReplyAnswersItsWaiters_MCP32() {
        var machine = out()
        machine = M.step(machine, .read(waiter: 1, now: at(100))).0
        machine = M.step(machine, .read(waiter: 2, now: at(200))).0
        let (next, actions) = M.step(machine, .reply(seq: 1, pkg: "org.example.maps"))
        XCTAssertEqual(next.phase, .answered(at: at(0), .pkg("org.example.maps")))
        XCTAssertEqual(next.waiters, [:])
        XCTAssertEqual(Set(actions), [.answer(waiter: 1, .pkg("org.example.maps")),
                                      .answer(waiter: 2, .pkg("org.example.maps"))])
    }

    func testANullPackageIsNone_MCP32() {
        var machine = M.step(out(), .read(waiter: 1, now: at(0))).0
        let actions: [M.Action]
        (machine, actions) = M.step(machine, .reply(seq: 1, pkg: nil))
        XCTAssertEqual(machine.phase, .answered(at: at(0), .none))
        XCTAssertEqual(actions, [.answer(waiter: 1, .none)])
    }

    /// #266 item 2: a reply for an older request is stale and ignored; the
    /// newer request's waiter keeps waiting.
    func testAnOlderReplyIsIgnored_MCP32() {
        var machine = M.step(out(at: 0), .ask(now: at(2000))).0
        machine = M.step(machine, .read(waiter: 1, now: at(2100))).0
        XCTAssertEqual(machine.seq, 2)
        let (next, actions) = M.step(machine, .reply(seq: 1, pkg: "org.example.stale"))
        XCTAssertEqual(next, machine)
        XCTAssertEqual(actions, [])
    }

    func testASecondReplyToAnAnsweredRequestIsIgnored_MCP32() {
        let machine = answered(.pkg("org.example.maps"))
        let (next, actions) = M.step(machine, .reply(seq: 1, pkg: "org.example.other"))
        XCTAssertEqual(next, machine)
        XCTAssertEqual(actions, [])
    }

    func testAReplyWithNoRequestIsIgnored_MCP32() {
        let (next, actions) = M.step(M(), .reply(seq: 0, pkg: "org.example.maps"))
        XCTAssertEqual(next, M())
        XCTAssertEqual(actions, [])
    }

    // MARK: unavailable

    func testNotAvailableAnswersTheRequestOutNotSupported_MCP32() {
        let machine = M.step(out(), .read(waiter: 1, now: at(0))).0
        let (next, actions) = M.step(machine, .unavailable)
        XCTAssertEqual(next.phase, .answered(at: at(0), .notSupported))
        XCTAssertEqual(actions, [.answer(waiter: 1, .notSupported)])
    }

    func testNotAvailableWithNoRequestOutIsIgnored_MCP32() {
        for machine in [M(), answered()] {
            let (next, actions) = M.step(machine, .unavailable)
            XCTAssertEqual(next, machine)
            XCTAssertEqual(actions, [])
        }
    }

    // MARK: reset

    /// #266 item 2: a link loss or a phone change answers every waiting read
    /// `timeout`, whatever request it waited for, and leaves any reply stale.
    func testAResetAnswersEveryWaiterTimeout_MCP32() {
        var machine = M.step(out(at: 0), .read(waiter: 1, now: at(0))).0
        machine = M.step(machine, .ask(now: at(2000))).0
        machine = M.step(machine, .read(waiter: 2, now: at(2000))).0
        XCTAssertEqual(machine.waiters, [1: 1, 2: 2])
        let (next, actions) = M.step(machine, .reset)
        XCTAssertEqual(next.seq, 3)
        XCTAssertEqual(next.phase, .idle)
        XCTAssertEqual(next.waiters, [:])
        XCTAssertEqual(Set(actions), [.answer(waiter: 1, .timeout), .answer(waiter: 2, .timeout)])
        XCTAssertEqual(M.step(next, .reply(seq: 2, pkg: "org.example.late")).1, [],
                       "a reply from before the reset is stale")
    }

    func testAResetWithNothingOutOnlyBumpsTheSeq_MCP32() {
        let (next, actions) = M.step(answered(), .reset)
        XCTAssertEqual(next.seq, 2)
        XCTAssertEqual(next.phase, .idle)
        XCTAssertEqual(actions, [])
    }

    // MARK: expired

    func testAWaiterThatExpiresIsAnsweredTimeout_MCP32() {
        var machine = M.step(out(), .read(waiter: 1, now: at(0))).0
        machine = M.step(machine, .read(waiter: 2, now: at(0))).0
        let (next, actions) = M.step(machine, .expired(waiter: 1))
        XCTAssertEqual(next.waiters, [2: 1])
        XCTAssertEqual(next.phase, machine.phase, "the request stays out for the other waiter")
        XCTAssertEqual(actions, [.answer(waiter: 1, .timeout)])
    }

    func testAnExpiryForAnAnsweredWaiterIsIgnored_MCP32() {
        var machine = M.step(out(), .read(waiter: 1, now: at(0))).0
        machine = M.step(machine, .reply(seq: 1, pkg: nil)).0
        let (next, actions) = M.step(machine, .expired(waiter: 1))
        XCTAssertEqual(next, machine)
        XCTAssertEqual(actions, [])
    }
}
