// The shim's handshake and the host's answer (docs/design/dock.md §Launch →
// window): a slow launch loses the bind's one `opened`, so the shim says it is
// listening (`ready`) until the host answers, and a bound shim never quits on
// its own. The machine is pure, so every transition is here.

import XCTest
@testable import PocketDeck

final class DockShimAckTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// The automatic path after its observers are registered.
    private func automatic() -> DockShimMachine.State {
        let (state, actions) = DockShimMachine.transition(
            .starting, .launch(automatic: true, now: t0))
        XCTAssertEqual(actions, [.post(.ready), .startRetry])
        XCTAssertEqual(state, .waiting(kind: .ready, since: t0, hostLaunched: false))
        return state
    }

    func testAutomaticLaunchPostsReadyEverySecondUntilAnswered() {
        let state = automatic()
        for tick in 1...5 {
            let (next, actions) = DockShimMachine.transition(
                state, .tick(now: at(TimeInterval(tick))))
            XCTAssertEqual(next, state, "a tick while waiting keeps the wait")
            XCTAssertEqual(actions, [.post(.ready)], "tick \(tick)")
        }
        let (bound, answered) = DockShimMachine.transition(state, .opened)
        XCTAssertEqual(bound, .bound)
        XCTAssertEqual(answered, [.stopRetry], "an answer ends the ready posts")
        let (later, quiet) = DockShimMachine.transition(bound, .tick(now: at(600)))
        XCTAssertEqual(later, .bound)
        XCTAssertEqual(quiet, [], "a bound shim never ticks itself out")
    }

    func testManualLaunchIsUnchanged() {
        let (waiting, posted) = DockShimMachine.transition(
            .starting, .launch(automatic: false, now: t0))
        XCTAssertEqual(waiting, .waiting(kind: .open, since: t0, hostLaunched: false))
        XCTAssertEqual(posted, [.post(.open), .startRetry])

        let (early, earlyActions) = DockShimMachine.transition(waiting, .tick(now: at(1)))
        XCTAssertEqual(early, waiting)
        XCTAssertEqual(earlyActions, [.post(.open)], "no host launch before 2 s")

        let (launched, launchActions) = DockShimMachine.transition(early, .tick(now: at(2)))
        XCTAssertEqual(launched, .waiting(kind: .open, since: t0, hostLaunched: true))
        XCTAssertEqual(launchActions, [.launchHost, .post(.open)], "2 s with no host: launch it")

        let (again, againActions) = DockShimMachine.transition(launched, .tick(now: at(3)))
        XCTAssertEqual(again, launched)
        XCTAssertEqual(againActions, [.post(.open)], "the host is launched once")
    }

    func testNoAnswerQuitsAfterThirtySecondsForBothWaits() {
        for kind in [DockShimMachine.WaitKind.open, .ready] {
            let state = DockShimMachine.State.waiting(kind: kind, since: t0, hostLaunched: true)
            let (still, actions) = DockShimMachine.transition(state, .tick(now: at(30)))
            XCTAssertEqual(still, state, "30 s is not past the limit yet (\(kind))")
            XCTAssertEqual(actions, [kind == .open ? .post(.open) : .post(.ready)])

            let (quitting, quit) = DockShimMachine.transition(state, .tick(now: at(30.5)))
            XCTAssertEqual(quitting, .quitting, "\(kind)")
            XCTAssertEqual(quit, [.post(.quit), .terminate],
                           "the self-quit closes the window and stops the shim")
        }
    }

    func testClosedExitsFromEveryState() {
        let states: [DockShimMachine.State] = [
            .starting,
            .waiting(kind: .open, since: t0, hostLaunched: false),
            .waiting(kind: .ready, since: t0, hostLaunched: true),
            .bound,
            .quitting,
        ]
        for state in states {
            let (next, actions) = DockShimMachine.transition(state, .closed)
            XCTAssertEqual(next, .quitting)
            XCTAssertEqual(actions, [.exit])
        }
    }

    func testActivateRaisesTheWindowOnlyWhenBound() {
        XCTAssertEqual(DockShimMachine.transition(.bound, .activate).1, [.post(.open)])
        XCTAssertEqual(DockShimMachine.transition(
            .waiting(kind: .ready, since: t0, hostLaunched: false), .activate).1, [])
        XCTAssertEqual(DockShimMachine.transition(.starting, .activate).1, [])
        XCTAssertEqual(DockShimMachine.transition(.quitting, .activate).1, [])
    }

    func testAReopenStartsTheManualWaitAgain() {
        let (state, actions) = DockShimMachine.transition(.bound, .reopen(now: at(40)))
        XCTAssertEqual(state, .waiting(kind: .open, since: at(40), hostLaunched: false))
        XCTAssertEqual(actions, [.post(.open), .startRetry])
    }

    func testQuittingPostsQuitOnce() {
        let waiting = DockShimMachine.State.waiting(kind: .ready, since: t0, hostLaunched: false)
        let (quitting, actions) = DockShimMachine.transition(waiting, .terminate)
        XCTAssertEqual(quitting, .quitting)
        XCTAssertEqual(actions, [.post(.quit)])
        XCTAssertEqual(DockShimMachine.transition(quitting, .terminate).1, [],
                       "the self-quit already posted quit")
    }

    func testADuplicateLaunchDoesNotRestartTheWait() {
        let state = automatic()
        let (next, actions) = DockShimMachine.transition(
            state, .launch(automatic: true, now: at(5)))
        XCTAssertEqual(next, state)
        XCTAssertEqual(actions, [])
    }

    // The host's answer to `ready`: only a bound pid with the bundle's token.

    func testReadyFromABoundPidIsAnsweredWithOpened() {
        XCTAssertEqual(DockReady.decide(bound: true, tokenMatches: true), .answer)
    }

    func testReadyFromAnUnboundPidIsNotAnswered() {
        XCTAssertEqual(DockReady.decide(bound: false, tokenMatches: true), .ignoreUnbound,
                       "the bind's own opened will reach the shim")
    }

    func testReadyWithAWrongTokenIsNeverAnswered() {
        XCTAssertEqual(DockReady.decide(bound: true, tokenMatches: false), .ignoreToken)
        XCTAssertEqual(DockReady.decide(bound: false, tokenMatches: false), .ignoreToken)
    }
}
