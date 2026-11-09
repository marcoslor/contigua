// R1 (one truth) and R2 (the cooldown is told): every surface reads the one
// Link value, and the countdown lives in the machine's state.

import Observation
import XCTest
@testable import PocketDeck

@MainActor
final class LinkPresentationTests: XCTestCase {
    private let phone = PhoneRef(id: "aaa", name: "Pixel 9", model: "Pixel 9")
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private var everyLink: [Link] {
        var links: [Link] = [.idle, .connecting(phone), .online(phone), .reconnecting(phone)]
        let causes: [Cause] = [.unreachable, .busy, .versionMismatch, .localNetworkDenied,
                               .connectionsOff, .pairingsOff, .notFound]
        for cause in causes { links.append(.offline(phone, cause)) }
        links.append(.needsPairing(phone))
        let pairings: [Pairing] = [.contacting, .comparing(code: "123456"), .verifying,
                                   .denied(until: at(30)), .coolingDown(until: at(30)),
                                   .refused("connections_off"), .timedOut, .unreachable]
        for pairing in pairings { links.append(.pairing(phone, pairing)) }
        return links
    }

    /// R1: the Deck's banner and interactivity, the menu-bar panel's notice and
    /// the Settings row are one derivation of one Link value, for every state.
    func testEverySurfaceReadsTheOneLinkValue() {
        for link in everyLink {
            let presentation = LinkPresentation(link: link)
            XCTAssertEqual(presentation.banner, link.banner, "\(link)")
            XCTAssertEqual(presentation.deckInteractive, link.isOnline, "\(link)")
            XCTAssertEqual(presentation.panelNotice, PhonePanelNotice.banner(for: link), "\(link)")
            XCTAssertEqual(presentation.settingsPresence, DevicePresence(link), "\(link)")
            XCTAssertEqual(presentation.chip, link.chip, "\(link)")
        }
    }

    /// R1: trust lost is the same words, the same way out and the same
    /// non-interactive Deck on all three surfaces.
    func testTrustLostIsOneStateEverywhere() {
        let presentation = LinkPresentation(link: .needsPairing(phone))
        XCTAssertEqual(presentation.banner?.text, "Pixel 9 no longer trusts this Mac.")
        XCTAssertEqual(presentation.banner?.action, .pairAgain)
        XCTAssertNil(presentation.banner?.detail)
        XCTAssertEqual(presentation.panelNotice?.action, .pairAgain)
        XCTAssertEqual(presentation.settingsPresence, .pairAgain)
        XCTAssertEqual(PhonePageHeaderAction.of(presence: presentation.settingsPresence,
                                                inUse: true), .pairAgain)
        XCTAssertFalse(presentation.deckInteractive)
    }

    /// R1's cause: the controller's link is a computed value over the book, so
    /// the book's records must be observable or SwiftUI never re-renders.
    func testTheCurrentLinkIsObservable() {
        let book = PhoneBook()
        book.start(active: phone, at: t0)
        final class Flag: @unchecked Sendable { var changed = false }
        let flag = Flag()
        withObservationTracking {
            _ = book.currentLink
        } onChange: {
            flag.changed = true
        }
        let record = book.record(for: phone.id)!
        record.machine = LinkMachine(link: .needsPairing(phone))
        XCTAssertTrue(flag.changed, "a machine change never reached the observer")
    }

    // MARK: R2: the countdown is the machine's state

    /// R2 rule 1: a refusal the Mac sees itself counts from that moment + 30 s.
    func testACooldownCountsFromTheRefusal() {
        var machine = LinkMachine()
        machine.handle(.beginPairing(phone), at: t0)
        machine.handle(.attemptFailed(reason: "pair_cooldown"), at: at(7))
        XCTAssertEqual(machine.link, .pairing(phone, .coolingDown(until: at(37))))
    }

    /// R2 rule 1: a denial the Mac saw counts from the denial + 30 s.
    func testADenialCountsFromTheDenial() {
        var machine = LinkMachine()
        machine.handle(.beginPairing(phone), at: t0)
        machine.handle(.attemptFailed(reason: "pair_denied"), at: at(4))
        XCTAssertEqual(machine.link, .pairing(phone, .denied(until: at(34))))
    }

    /// R2 rule 3: Try Again meeting the cooldown again restarts the window.
    func testASecondCooldownRestartsTheWindow() {
        var machine = LinkMachine()
        machine.handle(.beginPairing(phone), at: t0)
        machine.handle(.attemptFailed(reason: "pair_cooldown"), at: at(1))
        XCTAssertEqual(machine.link, .pairing(phone, .coolingDown(until: at(31))))
        machine.handle(.attemptFailed(reason: "pair_cooldown"), at: at(12))
        XCTAssertEqual(machine.link, .pairing(phone, .coolingDown(until: at(42))))
    }

    /// R2 rule 2: Try Again is offered only at 0, and nothing retries by itself.
    func testTryAgainOnlyWhenTheCountdownEnds() {
        let cooling = Pairing.coolingDown(until: at(30))
        XCTAssertEqual(cooling.remaining(at: at(7)), 23)
        XCTAssertEqual(cooling.remaining(at: at(30)), 0)
        XCTAssertEqual(cooling.remaining(at: at(31)), 0)
        XCTAssertFalse(cooling.canTryAgain(at: at(29)))
        XCTAssertTrue(cooling.canTryAgain(at: at(30)))
        XCTAssertTrue(Pairing.contacting.canTryAgain(at: at(0)))
        XCTAssertEqual(PairingCopy.countdown(23), "23 s")
        XCTAssertEqual(PairingCopy.countdown(-1), "0 s")
    }

    /// R2 rule 4: the same seconds line rides the banner when no sheet is open.
    func testTheBannerCarriesTheCountdown() {
        let until = at(30)
        for pairing in [Pairing.coolingDown(until: until), .denied(until: until)] {
            let banner = Link.pairing(phone, pairing).banner
            XCTAssertEqual(banner?.countdownUntil, until, "\(pairing)")
            XCTAssertNotNil(banner?.text, "\(pairing)")
        }
        XCTAssertNil(Link.online(phone).banner?.countdownUntil)
    }
}
