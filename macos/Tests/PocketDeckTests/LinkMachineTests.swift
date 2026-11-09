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

    func testOnlyTheTwoRetryStatesAreDownForWindows() {
        XCTAssertTrue(Link.reconnecting(phone).isDown)
        XCTAssertTrue(Link.offline(phone, .unreachable).isDown)
        XCTAssertFalse(Link.connecting(phone).isDown)
        XCTAssertFalse(Link.online(phone).isDown)
        XCTAssertFalse(Link.idle.isDown)
        XCTAssertFalse(Link.needsPairing(phone).isDown)
        XCTAssertFalse(Link.pairing(phone, .contacting).isDown)
    }

    func testAPairingFailureDoesNotRestoreTheWindows() {
        // online -> needsPairing is not "down", but it is no session either.
        // The one-shot linkLost is the truth; the reconcile must leave it.
        XCTAssertEqual(Link.online(phone).windowDesiredDown, false)
        XCTAssertNil(Link.needsPairing(phone).windowDesiredDown)
        XCTAssertNil(Link.idle.windowDesiredDown)
        XCTAssertNil(Link.connecting(phone).windowDesiredDown)
        XCTAssertNil(Link.pairing(phone, .verifying).windowDesiredDown)
        XCTAssertEqual(Link.reconnecting(phone).windowDesiredDown, true)
        XCTAssertEqual(Link.offline(phone, .unreachable).windowDesiredDown, true)
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

    // MARK: PAIR-23: the phone no longer has this Mac

    func testNotPairedIsTheTrustLostStateAtOnce() {
        var machine = online()
        XCTAssertEqual(machine.handle(.attemptFailed(reason: "not_paired"), at: at(5)), [.stopAttempts])
        XCTAssertEqual(machine.link, .needsPairing(phone))
        XCTAssertEqual(machine.link.banner, Banner(text: "Pixel 9 no longer trusts this Mac.", action: .pairAgain))
        XCTAssertEqual(machine.link.chip, Chip(text: "Pair again", style: .orange))
    }

    func testARetryWhilePairingsAreOffKeepsItsSentenceAndBackoff() {
        var machine = LinkMachine()
        machine.handle(.launch(phone), at: t0)
        XCTAssertEqual(machine.handle(.attemptFailed(reason: "pairing_off"), at: at(1)), [.attempt(after: 1)])
        XCTAssertEqual(machine.link, .offline(phone, .pairingsOff))
        XCTAssertEqual(machine.link.banner?.text, "Pixel 9 isn't accepting new pairings.")
        // The retry cannot present a pin at all: that is the same refusal, not a
        // lost key (it used to become "no longer trusts this Mac" a second in).
        XCTAssertEqual(machine.handle(.attemptFailed(reason: "no-pin"), at: at(2)), [.attempt(after: 2)])
        XCTAssertEqual(machine.link, .offline(phone, .pairingsOff))
        XCTAssertEqual(machine.link.banner?.text, "Pixel 9 isn't accepting new pairings.")
        XCTAssertEqual(machine.handle(.attemptFailed(reason: "pairing_off"), at: at(4)), [.attempt(after: 4)])
        XCTAssertEqual(machine.link.banner?.text, "Pixel 9 isn't accepting new pairings.")
    }

    func testASilentEarlyCloseNeedsPairingOnlyTheSecondTimeInARow() {
        var machine = LinkMachine()
        machine.handle(.launch(phone), at: t0)
        // One close may be the phone restarting: retry on the normal backoff.
        XCTAssertEqual(machine.handle(.attemptFailed(reason: "closed-early"), at: at(1)), [.attempt(after: 1)])
        XCTAssertEqual(machine.link, .connecting(phone))
        XCTAssertNil(machine.link.banner)
        // The second in a row is the phone refusing this Mac without a word.
        XCTAssertEqual(machine.handle(.attemptFailed(reason: "closed-early"), at: at(3)), [.stopAttempts])
        XCTAssertEqual(machine.link, .needsPairing(phone))
    }

    func testAnEarlyCloseCounterStartsOverAfterASessionOrTryNow() {
        var onlineAgain = LinkMachine()
        onlineAgain.handle(.launch(phone), at: t0)
        onlineAgain.handle(.attemptFailed(reason: "closed-early"), at: at(1))
        onlineAgain.handle(.welcome(phone), at: at(3))
        XCTAssertEqual(onlineAgain.handle(.attemptFailed(reason: "closed-early"), at: at(5)), [.attempt(after: 1)])
        XCTAssertNotEqual(onlineAgain.link, .needsPairing(phone))

        var retried = LinkMachine()
        retried.handle(.launch(phone), at: t0)
        retried.handle(.attemptFailed(reason: "closed-early"), at: at(1))
        retried.handle(.tryNow, at: at(2))
        XCTAssertEqual(retried.handle(.attemptFailed(reason: "closed-early"), at: at(4)), [.attempt(after: 1)])
        XCTAssertNotEqual(retried.link, .needsPairing(phone))
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


    // MARK: Trust lost (PAIR-30..33)

    func testForgottenIsTrustLostAtOnce() {
        var machine = online()
        XCTAssertEqual(machine.handle(.attemptFailed(reason: "forgotten"), at: at(5)), [.stopAttempts])
        XCTAssertEqual(machine.link, .needsPairing(phone))
        XCTAssertEqual(machine.trustLossKind, .told)
        XCTAssertEqual(machine.link.banner, Banner(text: "Pixel 9 no longer trusts this Mac.",
                                                   action: .pairAgain))
        XCTAssertEqual(machine.link.chip, Chip(text: "Pair again", style: .orange))
    }

    func testACertificateUnknownTwiceIsTrustLost() {
        var machine = online()
        XCTAssertEqual(machine.handle(.attemptFailed(reason: "certificate_unknown"), at: at(5)),
                       [.attempt(after: 1)])
        XCTAssertEqual(machine.link, .reconnecting(phone))
        XCTAssertNil(machine.trustLossKind)
        XCTAssertEqual(machine.handle(.attemptFailed(reason: "certificate_unknown"), at: at(6)),
                       [.stopAttempts])
        XCTAssertEqual(machine.link, .needsPairing(phone))
        XCTAssertEqual(machine.trustLossKind, .told)
    }

    func testABadCertificateCountsLikeACertificateUnknown() {
        var machine = online()
        _ = machine.handle(.attemptFailed(reason: "bad_certificate"), at: at(5))
        XCTAssertEqual(machine.handle(.attemptFailed(reason: "bad_certificate"), at: at(6)), [.stopAttempts])
        XCTAssertEqual(machine.trustLossKind, .told)
    }

    func testOneCertificateUnknownRetries() {
        var machine = online()
        XCTAssertEqual(machine.handle(.attemptFailed(reason: "certificate_unknown"), at: at(5)),
                       [.attempt(after: 1)])
        XCTAssertEqual(machine.handle(.welcome(phone), at: at(6)).count, 0)
        XCTAssertEqual(machine.link, .online(phone))
        XCTAssertEqual(machine.handle(.attemptFailed(reason: "certificate_unknown"), at: at(7)),
                       [.attempt(after: 1)], "a session in between starts the count over")
    }

    func testAPinMismatchForAForeignPhoneKeepsRetrying() {
        var machine = online()
        XCTAssertEqual(machine.handle(.attemptFailed(reason: "foreign-pin"), at: at(5)), [.attempt(after: 1)])
        XCTAssertEqual(machine.link, .reconnecting(phone))
        XCTAssertNil(machine.trustLossKind)
    }

    func testInferredTrustLostRechecksQuietlyAndClearsOnPinPass() {
        var machine = online()
        _ = machine.handle(.reachability(advertised: true, hasAddress: true, changed: false), at: at(4))
        XCTAssertEqual(machine.handle(.attemptFailed(reason: "pin-mismatch"), at: at(5)), [])
        XCTAssertEqual(machine.link, .needsPairing(phone))
        XCTAssertEqual(machine.trustLossKind, .inferred)
        // The next re-check is the 60 s tick, not the 1/2/4 s reconnect loop.
        for second in 6...63 {
            XCTAssertEqual(machine.handle(.tick, at: at(Double(second))), [], "tick \(second)")
        }
        XCTAssertEqual(machine.handle(.tick, at: at(65)), [.attempt(after: 0)])
        // A passing pin ends it at once.
        _ = machine.handle(.welcome(phone), at: at(66))
        XCTAssertEqual(machine.link, .online(phone))
        XCTAssertNil(machine.trustLossKind)
    }

    func testAnAdvertisementChangeRechecksAnInferredPhoneAtOnce() {
        var machine = online()
        _ = machine.handle(.attemptFailed(reason: "pin-mismatch"), at: at(5))
        XCTAssertEqual(machine.trustLossKind, .inferred)
        XCTAssertEqual(machine.handle(.reachability(advertised: true, hasAddress: true, changed: true),
                                      at: at(6)), [.attempt(after: 0)])
        XCTAssertEqual(machine.handle(.reachability(advertised: true, hasAddress: true, changed: false),
                                      at: at(7)), [])
    }

    func testASpoofedAdvertisementCannotStopTheRealPhone() {
        var machine = online()
        _ = machine.handle(.reachability(advertised: true, hasAddress: true, changed: true), at: at(4))
        _ = machine.handle(.attemptFailed(reason: "pin-mismatch"), at: at(5))
        XCTAssertEqual(machine.trustLossKind, .inferred)
        // The real phone answers with the pinned certificate on a later re-check.
        _ = machine.handle(.tick, at: at(65))
        _ = machine.handle(.welcome(phone), at: at(66))
        XCTAssertEqual(machine.link, .online(phone))
        XCTAssertNil(machine.trustLossKind)
    }

    func testTheTrustLostBannerOffersPairAgainOnly() {
        let banner = Link.needsPairing(phone).banner
        XCTAssertEqual(banner?.text, "Pixel 9 no longer trusts this Mac.")
        XCTAssertEqual(banner?.action, .pairAgain)
        XCTAssertEqual(banner?.actionTitle, "Pair again")
        XCTAssertNil(Link.needsPairing(phone).windowDesiredDown, "no close leaves the windows down")
    }

    func testLaunchRestoresTrustLostWithoutAnAttempt() {
        var told = LinkMachine()
        XCTAssertEqual(told.handle(.restoreTrustLost(phone, .told), at: t0), [.stopAttempts])
        XCTAssertEqual(told.link, .needsPairing(phone))
        XCTAssertEqual(told.trustLossKind, .told)

        var inferred = LinkMachine()
        XCTAssertEqual(inferred.handle(.restoreTrustLost(phone, .inferred), at: t0), [])
        XCTAssertEqual(inferred.link, .needsPairing(phone))
        XCTAssertEqual(inferred.trustLossKind, .inferred)
        XCTAssertEqual(inferred.handle(.reachability(advertised: true, hasAddress: true, changed: true),
                                       at: at(1)), [.attempt(after: 0)])
    }

    func testWelcomeOrForgetEndsTrustLost() {
        var paid = LinkMachine()
        _ = paid.handle(.restoreTrustLost(phone, .told), at: t0)
        _ = paid.handle(.welcome(phone), at: at(1))
        XCTAssertNil(paid.trustLossKind)
        XCTAssertEqual(paid.link, .online(phone))

        var forgotten = LinkMachine()
        _ = forgotten.handle(.restoreTrustLost(phone, .inferred), at: t0)
        XCTAssertEqual(forgotten.handle(.forget(deviceId: "aaa"), at: at(1)), [.stopAttempts])
        XCTAssertNil(forgotten.trustLossKind)
        XCTAssertEqual(forgotten.link, .idle)
    }

    // MARK: Connections off and not found (PAIR-35)

    func testConnectionsOffShowsTheHintAndSlowsToThirtySeconds() {
        var machine = online()
        XCTAssertEqual(machine.handle(.attemptFailed(reason: "connections_off"), at: at(5)),
                       [.attempt(after: 30)])
        XCTAssertEqual(machine.link, .offline(phone, .connectionsOff))
        XCTAssertEqual(machine.link.banner,
                       Banner(text: "Connections are turned off on Pixel 9.", action: nil,
                              detail: "Turn on Allow connections in PocketDeck on your phone."))
        // A new advertisement retries now, then the next failure waits again.
        XCTAssertEqual(machine.handle(.reachability(advertised: true, hasAddress: true, changed: true),
                                      at: at(6)), [.attempt(after: 0)])
        XCTAssertEqual(machine.handle(.attemptFailed(reason: "connections_off"), at: at(7)),
                       [.attempt(after: 30)])
    }

    func testWelcomeClearsTheConnectionsOffBanner() {
        var machine = online()
        _ = machine.handle(.attemptFailed(reason: "connections_off"), at: at(5))
        XCTAssertNotNil(machine.link.banner)
        _ = machine.handle(.welcome(phone), at: at(6))
        XCTAssertNil(machine.link.banner)
    }

    func testNotFoundAfterThirtySecondsWithNoAdvertisementOrAddress() {
        var machine = LinkMachine()
        _ = machine.handle(.launch(phone), at: t0)
        _ = machine.handle(.reachability(advertised: false, hasAddress: false, changed: false), at: t0)
        for second in 1...29 { XCTAssertEqual(machine.handle(.tick, at: at(Double(second))), []) }
        XCTAssertEqual(machine.link, .connecting(phone))
        _ = machine.handle(.tick, at: at(30))
        XCTAssertEqual(machine.link, .offline(phone, .notFound))
        XCTAssertEqual(machine.link.banner,
                       Banner(text: "Can't find Pixel 9 on this network.",
                              action: nil,
                              detail: "Check that the phone is on the same Wi-Fi and PocketDeck is running."))
        XCTAssertEqual(machine.handle(.reachability(advertised: true, hasAddress: false, changed: true),
                                      at: at(31)), [.attempt(after: 0)])
    }

    func testANotFoundPhoneWithALastAddressOnlyEverSaysUnreachable() {
        var machine = LinkMachine()
        _ = machine.handle(.launch(phone), at: t0)
        _ = machine.handle(.reachability(advertised: false, hasAddress: true, changed: false), at: t0)
        _ = machine.handle(.tick, at: at(30))
        XCTAssertEqual(machine.link, .offline(phone, .unreachable))
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
