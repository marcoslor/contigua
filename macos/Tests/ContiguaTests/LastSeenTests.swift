// DECK-14/15: while the phone is away the Deck says when it was last seen —
// the chip's help tag and the offline banner. The timestamp is the link
// machine's own state: stamped when the phone is reached and on every tick of a
// live session, seeded at launch from the record this Mac remembered, and never
// inferred from a counter or a flag.

import XCTest
@testable import Contigua

@MainActor
final class LastSeenTests: XCTestCase {
    private let phone = PhoneRef(id: "aaa", name: "Pixel 9", model: "Pixel 9")
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// A welcome stamps the sighting; every tick of the live session refreshes
    /// it; a drop keeps the last one (the phone was seen then, not now).
    func testTheMachineStampsTheLastSightingAndKeepsItThroughADrop() {
        var machine = LinkMachine()
        machine.handle(.launch(phone), at: t0)
        XCTAssertNil(machine.lastSeen, "a launch is not a sighting")
        machine.handle(.welcome(phone), at: at(2))
        XCTAssertEqual(machine.lastSeen, at(2))
        machine.handle(.tick, at: at(32))
        XCTAssertEqual(machine.lastSeen, at(32), "a live session is a sighting")
        machine.handle(.attemptFailed(reason: "timeout"), at: at(33))
        XCTAssertEqual(machine.link, .reconnecting(phone))
        XCTAssertEqual(machine.lastSeen, at(32), "the drop is not a sighting")
        machine.handle(.tick, at: at(60))
        XCTAssertEqual(machine.lastSeen, at(32), "ticks while reconnecting change nothing")
    }

    /// The launch seeds the stamp from what this Mac remembered, so a phone
    /// that is away from the first second still says when it was here.
    func testTheLaunchSeedsTheRememberedSighting() {
        var machine = LinkMachine(lastSeen: at(-7200))
        machine.handle(.launch(phone), at: t0)
        XCTAssertEqual(machine.lastSeen, at(-7200))
        let book = PhoneBook()
        book.start(active: phone, at: t0, lastSeen: at(-7200))
        XCTAssertEqual(book.record(for: phone.id)?.machine.lastSeen, at(-7200))
        book.start(active: phone, at: at(1), lastSeen: nil)
        XCTAssertEqual(book.record(for: phone.id)?.machine.lastSeen, at(-7200),
                       "a second start never clears the stamp")
    }

    /// Every offline banner carries the stamp; the other states do not.
    func testEveryOfflineBannerCarriesTheLastSeenStamp() {
        let causes: [Cause] = [.unreachable, .busy, .versionMismatch, .localNetworkDenied,
                               .connectionsOff, .pairingsOff, .notFound]
        for cause in causes {
            let banner = Link.offline(phone, cause).banner(lastSeen: at(-60))
            XCTAssertEqual(banner?.lastSeen, at(-60), "\(cause)")
        }
        XCTAssertNil(Link.online(phone).banner(lastSeen: at(-60))?.lastSeen)
        XCTAssertNil(Link.connecting(phone).banner(lastSeen: at(-60))?.lastSeen)
        XCTAssertNil(Link.needsPairing(phone).banner(lastSeen: at(-60))?.lastSeen)
        XCTAssertNil(Link.offline(phone, .unreachable).banner?.lastSeen,
                     "without a stamp the banner says nothing")
    }

    /// "Last seen 21:13" today; before today the date joins the time. The
    /// person's locale decides the clock and the order (FormatStyle).
    func testTheLastSeenLineIsTimeOnlyTodayAndDateAndTimeBefore() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_GB")
        XCTAssertEqual(LastSeen.line(at(0), now: at(3600), calendar: calendar, locale: locale),
                       "Last seen 22:13")
        XCTAssertEqual(LastSeen.line(at(-3 * 86_400), now: at(0), calendar: calendar, locale: locale),
                       "Last seen 11 Nov at 22:13")
    }
}
