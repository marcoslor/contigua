// The connection state machine the UI sees (docs/design/mac-redesign.md §4.3),
// driven with a fake clock: no sockets, no timers.

import XCTest
@testable import PocketDeck

final class LinkMachineTests: XCTestCase {
    private let phone = PhoneRef(id: "aaa", name: "Pixel 9", model: "Pixel 9")
    private let other = PhoneRef(id: "bbb", name: "Galaxy", model: "SM-S936B")
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func online() -> LinkMachine {
        var machine = LinkMachine()
        machine.handle(.launch(phone), at: t0)
        machine.handle(.welcome(phone), at: at(1))
        return machine
    }

    // MARK: Launch

    func testLaunchWithoutARememberedPhoneStaysIdle() {
        var machine = LinkMachine()
        XCTAssertEqual(machine.handle(.launch(nil), at: t0), [])
        XCTAssertEqual(machine.link, .idle)
    }

    func testLaunchWithARememberedPhoneConnectsAtOnceWithoutAScreen() {
        var machine = LinkMachine()
        XCTAssertEqual(machine.handle(.launch(phone), at: t0), [.attempt(after: 0)])
        XCTAssertEqual(machine.link, .connecting(phone))
        XCTAssertNil(machine.link.banner)
        XCTAssertEqual(machine.link.chip, Chip(text: "Connecting…", style: .grey))
    }

    func testWelcomeGoesOnline() {
        let machine = online()
        XCTAssertEqual(machine.link, .online(phone))
        XCTAssertEqual(machine.link.chip, Chip(text: "Connected", style: .green))
        XCTAssertNil(machine.link.banner)
    }

    // MARK: Transient failures are silent

    func testTransientFailuresBackOffAndShowNothing() {
        var machine = LinkMachine()
        machine.handle(.launch(phone), at: t0)
        for (index, delay) in [1.0, 2, 4, 8, 15, 15, 15].enumerated() {
            let actions = machine.handle(.attemptFailed(reason: "closed-by-peer"), at: at(Double(index)))
            XCTAssertEqual(actions, [.attempt(after: delay)], "failure \(index + 1)")
            XCTAssertEqual(machine.link, .connecting(phone))
            XCTAssertNil(machine.link.banner)
        }
    }

    func testEveryTransientReasonOnlyRetries() {
        for reason in ["closed-by-peer", "timeout", "receive", "failed", "cancelled", "framing", "closed"] {
            var machine = online()
            let actions = machine.handle(.attemptFailed(reason: reason), at: at(5))
            XCTAssertEqual(actions, [.attempt(after: 1)], reason)
            XCTAssertEqual(machine.link, .reconnecting(phone), reason)
            XCTAssertNil(machine.link.banner, reason)
        }
    }

    func testLinkLossWhileOnlineBecomesReconnecting() {
        var machine = online()
        machine.handle(.attemptFailed(reason: "closed-by-peer"), at: at(10))
        XCTAssertEqual(machine.link, .reconnecting(phone))
        XCTAssertEqual(machine.link.chip, Chip(text: "Reconnecting…", style: .pulsingOrange))
    }

    func testOfflineOnlyAfterFifteenSecondsWithoutASession() {
        var machine = online()
        machine.handle(.attemptFailed(reason: "closed-by-peer"), at: at(10))
        machine.handle(.tick, at: at(24.9))
        XCTAssertEqual(machine.link, .reconnecting(phone))
        machine.handle(.tick, at: at(25))
        XCTAssertEqual(machine.link, .offline(phone, .unreachable))
        XCTAssertEqual(machine.link.banner?.action, .tryNow)
        XCTAssertEqual(machine.link.banner?.text, "Can't reach Pixel 9. Check that it's on the same Wi-Fi.")
    }

    func testOfflineAtLaunchUsesTheSameFifteenSeconds() {
        var machine = LinkMachine()
        machine.handle(.launch(phone), at: t0)
        machine.handle(.tick, at: at(14))
        XCTAssertEqual(machine.link, .connecting(phone))
        machine.handle(.tick, at: at(15))
        XCTAssertEqual(machine.link, .offline(phone, .unreachable))
    }

    func testOfflineRetriesKeepTheFifteenSecondCadenceAndRecoverSilently() {
        var machine = LinkMachine()
        machine.handle(.launch(phone), at: t0)
        machine.handle(.tick, at: at(15))
        let actions = machine.handle(.attemptFailed(reason: "timeout"), at: at(16))
        XCTAssertEqual(actions, [.attempt(after: 1)])
        XCTAssertEqual(machine.link, .offline(phone, .unreachable))
        machine.handle(.welcome(phone), at: at(40))
        XCTAssertEqual(machine.link, .online(phone))
        XCTAssertNil(machine.link.banner)
    }

    // MARK: Hints reset the backoff

    func testReachabilityHintsAndTryNowRetryImmediately() {
        for event in [LinkEvent.reachabilityHint, .tryNow] {
            var machine = LinkMachine()
            machine.handle(.launch(phone), at: t0)
            for _ in 0..<4 { machine.handle(.attemptFailed(reason: "timeout"), at: at(1)) }
            XCTAssertEqual(machine.consecutiveFailures, 4)
            XCTAssertEqual(machine.handle(event, at: at(5)), [.attempt(after: 0)], "\(event)")
            XCTAssertEqual(machine.consecutiveFailures, 0)
        }
    }

    func testHintsDoNothingWhileOnlineOrWaitingForTheUser() {
        var machine = online()
        XCTAssertEqual(machine.handle(.reachabilityHint, at: at(5)), [])
        machine.handle(.attemptFailed(reason: "pin-mismatch"), at: at(6))
        XCTAssertEqual(machine.link, .needsPairing(phone))
        XCTAssertEqual(machine.handle(.reachabilityHint, at: at(7)), [])
        XCTAssertEqual(machine.handle(.tryNow, at: at(8)), [])
    }

    // MARK: Failures that need the user

    func testRejectedKeyNeedsPairingAndStopsRetrying() {
        var machine = online()
        XCTAssertEqual(machine.handle(.attemptFailed(reason: "pin-mismatch"), at: at(5)), [.stopAttempts])
        XCTAssertEqual(machine.link, .needsPairing(phone))
        XCTAssertEqual(machine.link.banner, Banner(text: "Pixel 9 no longer trusts this Mac.", action: .pairAgain))
        XCTAssertEqual(machine.link.chip, Chip(text: "Pair again", style: .orange))
    }

    func testBusyShowsTheBannerAtOnceAndRetriesSlowly() {
        var machine = LinkMachine()
        machine.handle(.launch(phone), at: t0)
        let actions = machine.handle(.attemptFailed(reason: "busy"), at: at(2))
        XCTAssertEqual(actions, [.attempt(after: 15)])
        XCTAssertEqual(machine.link, .offline(phone, .busy))
        XCTAssertEqual(machine.link.banner?.text, "Another Mac is connected to Pixel 9.")
        // The other Mac goes away: any other failure reads as unreachable again.
        machine.handle(.attemptFailed(reason: "timeout"), at: at(20))
        XCTAssertEqual(machine.link, .offline(phone, .unreachable))
    }

    func testConnectionsOffNamesThePhoneAndKeepsTheBackoff() {
        var machine = online()
        XCTAssertEqual(machine.handle(.attemptFailed(reason: "connections_off"), at: at(5)),
                       [.attempt(after: 1)])
        XCTAssertEqual(machine.link, .offline(phone, .connectionsOff))
        XCTAssertEqual(machine.link.banner?.text, "Connections are turned off on Pixel 9.")
        XCTAssertNil(machine.link.banner?.action)
        // The next retry waits longer: the same schedule as every other drop.
        XCTAssertEqual(machine.handle(.attemptFailed(reason: "connections_off"), at: at(6)),
                       [.attempt(after: 2)])
    }

    func testPairingsOffNamesThePhoneAndKeepsTheBackoff() {
        var machine = online()
        XCTAssertEqual(machine.handle(.attemptFailed(reason: "pairing_off"), at: at(5)),
                       [.attempt(after: 1)])
        XCTAssertEqual(machine.link, .offline(phone, .pairingsOff))
        XCTAssertEqual(machine.link.banner?.text, "Pixel 9 isn't accepting new pairings.")
    }

    func testPairingRefusedByThePhoneStaysInTheSheet() {
        var machine = LinkMachine()
        machine.handle(.beginPairing(phone), at: t0)
        machine.handle(.attemptFailed(reason: "pairing_off"), at: at(2))
        XCTAssertEqual(machine.link, .pairing(phone, .refused("pairing_off")))
    }

    func testVersionMismatchStopsRetryingButTryNowRestarts() {
        var machine = online()
        XCTAssertEqual(machine.handle(.attemptFailed(reason: "version"), at: at(5)), [.stopAttempts])
        XCTAssertEqual(machine.link, .offline(phone, .versionMismatch))
        XCTAssertNil(machine.link.banner?.action)
        XCTAssertEqual(machine.handle(.tryNow, at: at(9)), [.attempt(after: 0)])
    }

    func testLocalNetworkDeniedStopsAndExplains() {
        var machine = LinkMachine()
        machine.handle(.launch(phone), at: t0)
        XCTAssertEqual(machine.handle(.localNetworkDenied, at: at(1)), [.stopAttempts])
        XCTAssertEqual(machine.link.banner?.action, .openSettings)
    }

    // MARK: Pairing

    func testPairingIsUserDrivenAndBlocksAutomaticAttempts() {
        var machine = LinkMachine()
        let actions = machine.handle(.beginPairing(phone), at: t0)
        XCTAssertEqual(actions, [.stopAttempts, .startPairing(phone)])
        XCTAssertEqual(machine.link, .pairing(phone, .contacting))
        XCTAssertNil(machine.link.chip)
    }

    func testComparingTheCodeToOnline() {
        var machine = LinkMachine()
        machine.handle(.beginPairing(phone), at: t0)
        machine.handle(.codeShown(phone, code: "123456"), at: at(1))
        XCTAssertEqual(machine.link, .pairing(phone, .comparing(code: "123456")))
        machine.handle(.pairApproved, at: at(30))
        XCTAssertEqual(machine.link, .pairing(phone, .verifying))
        machine.handle(.welcome(phone), at: at(30.2))
        XCTAssertEqual(machine.link, .online(phone))
    }

    func testWaitingForAPersonNeverTimesOutOnTheMac() {
        var machine = LinkMachine()
        machine.handle(.beginPairing(phone), at: t0)
        machine.handle(.codeShown(phone, code: "123456"), at: at(1))
        for second in stride(from: 2.0, through: 125.0, by: 1.0) {
            XCTAssertEqual(machine.handle(.tick, at: at(second)), [])
        }
        XCTAssertEqual(machine.link, .pairing(phone, .comparing(code: "123456")))
    }

    /// PAIR-5: a phone inside its cooldown answers with its own code, and the
    /// sheet can say to wait instead of repeating a denial.
    func testACooldownIsItsOwnStateWithItsOwnWords() {
        var machine = LinkMachine()
        machine.handle(.beginPairing(phone), at: t0)
        machine.handle(.codeShown(phone, code: "123456"), at: at(1))
        machine.handle(.attemptFailed(reason: "pair_cooldown"), at: at(2))
        XCTAssertEqual(machine.link, .pairing(phone, .coolingDown))
        XCTAssertEqual(PairingCopy.coolingDown, "Wait a moment, then try again.")
        // PAIR-6: the 20 s hint appears exactly at the mark, not before.
        XCTAssertNil(PairingCopy.slowHint(after: 19.9))
        XCTAssertEqual(PairingCopy.slowHint(after: 20),
                       "Check your phone: PocketDeck's notifications may be turned off.")

        // A launch (no code on screen yet) that meets the same cooldown shows
        // the sheet too, instead of a silent offline link.
        var launch = LinkMachine()
        launch.handle(.launch(phone), at: t0)
        XCTAssertEqual(launch.handle(.attemptFailed(reason: "pair_cooldown"), at: at(1)), [.stopAttempts])
        XCTAssertEqual(launch.link, .pairing(phone, .coolingDown))
    }

    func testDeniedTimedOutAndLostAreInlineStates() {
        var machine = LinkMachine()
        machine.handle(.beginPairing(phone), at: t0)
        machine.handle(.codeShown(phone, code: "123456"), at: at(1))
        machine.handle(.attemptFailed(reason: "pair_denied"), at: at(2))
        XCTAssertEqual(machine.link, .pairing(phone, .denied))

        var timedOut = LinkMachine()
        timedOut.handle(.beginPairing(phone), at: t0)
        timedOut.handle(.codeShown(phone, code: "123456"), at: at(1))
        XCTAssertEqual(timedOut.handle(.attemptFailed(reason: "pair_timeout"), at: at(121)), [])
        XCTAssertEqual(timedOut.link, .pairing(phone, .timedOut))

        // A connection that drops is not "nobody answered": the person may be mid-tap.
        var lost = LinkMachine()
        lost.handle(.beginPairing(phone), at: t0)
        lost.handle(.codeShown(phone, code: "123456"), at: at(1))
        lost.handle(.attemptFailed(reason: "closed-by-peer"), at: at(5))
        XCTAssertEqual(lost.link, .pairing(phone, .unreachable))
    }

    func testUnreachableWhilePairing() {
        var machine = LinkMachine()
        machine.handle(.beginPairing(phone), at: t0)
        machine.handle(.attemptFailed(reason: "timeout"), at: at(6))
        XCTAssertEqual(machine.link, .pairing(phone, .unreachable))
    }

    func testPairingNeverRetriesOnItsOwn() {
        var machine = LinkMachine()
        machine.handle(.beginPairing(phone), at: t0)
        for reason in ["closed-by-peer", "timeout", "pair_denied", "pair_timeout", "busy"] {
            XCTAssertEqual(machine.handle(.attemptFailed(reason: reason), at: at(3)), [], reason)
        }
        XCTAssertEqual(machine.handle(.reachabilityHint, at: at(4)), [])
        XCTAssertEqual(machine.handle(.tryNow, at: at(4)), [])
    }

    func testTryAgainIsANewPairing() {
        var machine = LinkMachine()
        machine.handle(.beginPairing(phone), at: t0)
        machine.handle(.attemptFailed(reason: "pair_timeout"), at: at(16))
        XCTAssertEqual(machine.handle(.beginPairing(phone), at: at(20)), [.stopAttempts, .startPairing(phone)])
        XCTAssertEqual(machine.link, .pairing(phone, .contacting))
    }

    func testCancelReturnsToWhereTheUserWas() {
        var remembered = online()
        remembered.handle(.attemptFailed(reason: "pin-mismatch"), at: at(5))
        remembered.handle(.beginPairing(phone), at: at(6))
        XCTAssertEqual(remembered.handle(.cancelPairing, at: at(7)), [])
        XCTAssertEqual(remembered.link, .needsPairing(phone))

        var recovering = LinkMachine()
        recovering.handle(.launch(phone), at: t0)
        recovering.handle(.beginPairing(other), at: at(2))
        XCTAssertEqual(recovering.handle(.cancelPairing, at: at(3)), [.attempt(after: 0)])
        XCTAssertEqual(recovering.link, .connecting(phone))

        var fresh = LinkMachine()
        fresh.handle(.beginPairing(phone), at: t0)
        XCTAssertEqual(fresh.handle(.cancelPairing, at: at(1)), [])
        XCTAssertEqual(fresh.link, .idle)
    }

    func testAManualLaunchThatAsksForACodeBecomesPairing() {
        var machine = LinkMachine()
        machine.handle(.launch(phone), at: t0)
        XCTAssertEqual(machine.handle(.codeShown(phone, code: "123456"), at: at(1)), [.stopAttempts])
        XCTAssertEqual(machine.link, .pairing(phone, .comparing(code: "123456")))
    }

    // MARK: Switching and forgetting

    func testForgetTheActivePhoneLeavesIdleAndStops() {
        var machine = online()
        XCTAssertEqual(machine.handle(.forget(deviceId: "aaa"), at: at(5)), [.stopAttempts])
        XCTAssertEqual(machine.link, .idle)
    }

    func testForgettingAnotherPhoneChangesNothing() {
        var machine = online()
        XCTAssertEqual(machine.handle(.forget(deviceId: "bbb"), at: at(5)), [])
        XCTAssertEqual(machine.link, .online(phone))
    }

    func testActivateConnectsToTheOtherPhone() {
        var machine = online()
        XCTAssertEqual(machine.handle(.activate(other), at: at(5)), [.attempt(after: 0)])
        XCTAssertEqual(machine.link, .connecting(other))
    }

    func testRetrySchedule() {
        XCTAssertEqual(ReconnectPolicy.delay(afterFailures: 0), 0)
        XCTAssertEqual((1...8).map { ReconnectPolicy.delay(afterFailures: $0) }, [1, 2, 4, 8, 15, 15, 15, 15])
    }

    func testBannersNeverMentionReasonCodes() {
        let links: [Link] = [.offline(phone, .unreachable), .offline(phone, .busy), .offline(phone, .versionMismatch),
                             .offline(phone, .localNetworkDenied), .needsPairing(phone)]
        for link in links {
            let text = link.banner?.text ?? ""
            for forbidden in ["closed-by-peer", "timeout", "pin-mismatch", "busy)", "(", "port"] {
                XCTAssertFalse(text.contains(forbidden), "\(link): \(text)")
            }
        }
    }
}
