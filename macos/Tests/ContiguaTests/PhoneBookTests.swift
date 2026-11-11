// The phone book above Session: one connection record per phone, the claims
// that keep it alive, and the current phone's view. Pure: no sockets and no
// timers, so every rule in pairing.md PAIR-24..PAIR-29 is a unit test.

import XCTest
@testable import Contigua

@MainActor
final class PhoneBookTests: XCTestCase {
    private let a = PhoneRef(id: "aaa", name: "Pixel 9", model: "Pixel 9")
    private let b = PhoneRef(id: "bbb", name: "Galaxy", model: "SM-S936B")
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// The current phone online, plus another phone online through the test
    /// hook. The hook is what keeps the non-current phone's session alive.
    private func twoOnline() -> PhoneBook {
        let book = PhoneBook()
        book.setCurrent(a.id, phone: a)
        book.addClaim(.testHook, to: b.id, phone: b)
        _ = book.handle(.activate(a), from: a.id, at: t0)
        _ = book.handle(.activate(b), from: b.id, at: t0)
        _ = book.handle(.welcome(a), from: a.id, at: at(1))
        _ = book.handle(.welcome(b), from: b.id, at: at(1))
        return book
    }

    // MARK: Adopting a phone's id

    /// A provisional record (a manual pairing, or a hook endpoint the cache
    /// does not know) learns an id another record already holds: the old
    /// record is handed back so the controller closes its session instead of
    /// dropping it while it runs, and its claims move to the adopted record.
    func testAdoptingAnIdThatHasARecordHandsTheOldOneBack() {
        let book = PhoneBook()
        book.setCurrent(a.id, phone: a)
        book.addClaim(.testHook, to: b.id, phone: b)
        let old = book.record(for: b.id)
        let provisional = book.ensureRecord(for: "hook:pair-10.0.0.2:47994")

        let displaced = book.adopt(provisional, as: b.id)

        XCTAssertTrue(displaced === old)
        XCTAssertTrue(book.record(for: b.id) === provisional)
        XCTAssertNil(book.record(for: "hook:pair-10.0.0.2:47994"))
        XCTAssertEqual(provisional.claims, [.testHook])
        XCTAssertEqual(book.currentId, a.id)
        // Adopting the id a record already has hands nothing back.
        XCTAssertNil(book.adopt(provisional, as: b.id))
    }

    // MARK: Two sessions

    func testTwoSessionsAreIndependent() {
        let book = twoOnline()
        XCTAssertEqual(book.currentId, a.id)
        XCTAssertEqual(book.record(for: a.id)?.link, .online(a))
        XCTAssertEqual(book.record(for: b.id)?.link, .online(b))

        // Failing the non-current phone changes only that phone.
        book.handle(.attemptFailed(reason: "timeout"), from: b.id, at: at(2))
        XCTAssertEqual(book.record(for: a.id)?.link, .online(a))
        XCTAssertEqual(book.record(for: a.id)?.machine.consecutiveFailures, 0)
        XCTAssertEqual(book.record(for: b.id)?.link, .reconnecting(b))
        XCTAssertEqual(book.record(for: b.id)?.machine.consecutiveFailures, 1)

        // Failing the current phone changes only that phone.
        book.handle(.attemptFailed(reason: "timeout"), from: a.id, at: at(3))
        XCTAssertEqual(book.record(for: a.id)?.link, .reconnecting(a))
        XCTAssertEqual(book.record(for: b.id)?.link, .reconnecting(b))

        // A welcome on one phone leaves the other's link alone.
        book.handle(.welcome(b), from: b.id, at: at(4))
        XCTAssertEqual(book.record(for: b.id)?.link, .online(b))
        XCTAssertEqual(book.record(for: a.id)?.link, .reconnecting(a))
    }

    // MARK: Switching

    func testSwitchingChangesTheCurrentView() {
        let book = twoOnline()
        XCTAssertEqual(book.currentLink, .online(a))

        let actions = book.setCurrent(b.id)
        XCTAssertFalse(actions.contains(.connect(deviceId: b.id)), "B is already live: \(actions)")
        XCTAssertEqual(book.currentId, b.id)
        XCTAssertEqual(book.currentLink, .online(b))
        XCTAssertEqual(book.record(for: a.id)?.link, .idle, "A had no other claim")
    }

    func testSwitchingKeepsTheOtherSessionRunning() {
        let book = PhoneBook()
        book.setCurrent(a.id, phone: a)
        book.addClaim(.testHook, to: a.id, phone: a)
        _ = book.handle(.activate(a), from: a.id, at: t0)
        _ = book.handle(.welcome(a), from: a.id, at: at(1))
        book.setCurrent(b.id, phone: b)
        _ = book.handle(.activate(b), from: b.id, at: t0)
        _ = book.handle(.welcome(b), from: b.id, at: at(1))

        let actions = book.setCurrent(b.id)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(book.record(for: a.id)?.link, .online(a))
        XCTAssertEqual(book.record(for: b.id)?.link, .online(b))
    }

    func testSwitchingKeepsAPhoneATestHookNames() {
        let book = PhoneBook()
        book.setCurrent(a.id, phone: a)
        book.addClaim(.testHook, to: a.id, phone: a)
        _ = book.handle(.activate(a), from: a.id, at: t0)
        _ = book.handle(.welcome(a), from: a.id, at: at(1))

        let actions = book.setCurrent(b.id)
        XCTAssertFalse(actions.contains(.close(deviceId: a.id)), "the hook still names A: \(actions)")
        XCTAssertEqual(book.record(for: a.id)?.link, .online(a))
    }

    func testSwitchingClosesAPreviousPhoneNothingNames() {
        let book = PhoneBook()
        book.setCurrent(a.id, phone: a)
        _ = book.handle(.activate(a), from: a.id, at: t0)
        _ = book.handle(.welcome(a), from: a.id, at: at(1))

        let actions = book.setCurrent(b.id)
        XCTAssertTrue(actions.contains(.close(deviceId: a.id)), "A lost its last claim: \(actions)")
        XCTAssertEqual(book.record(for: a.id)?.link, .idle)
        XCTAssertEqual(book.currentId, b.id)
    }

    func testForgettingTheCurrentPhoneLeavesAnotherSessionRunning() {
        let book = twoOnline()
        let forgot = book.removeClaim(.current, from: a.id)
        XCTAssertTrue(forgot.contains(.close(deviceId: a.id)))
        XCTAssertEqual(book.record(for: a.id)?.link, .idle)

        let switched = book.setCurrent(b.id)
        XCTAssertTrue(switched.isEmpty, "B is already live: \(switched)")
        XCTAssertEqual(book.currentId, b.id)
        XCTAssertEqual(book.record(for: b.id)?.link, .online(b))
    }

    // MARK: Closing one

    func testClosingOneLeavesTheOtherReady() {
        let book = twoOnline()
        let actions = book.removeClaim(.testHook, from: b.id)
        XCTAssertEqual(actions, [.close(deviceId: b.id)])
        XCTAssertEqual(book.record(for: b.id)?.link, .idle)
        XCTAssertEqual(book.record(for: a.id)?.link, .online(a))

        XCTAssertEqual(book.addClaim(.testHook, to: b.id, phone: b), [.connect(deviceId: b.id)])
        book.handle(.activate(b), from: b.id, at: at(5))
        book.handle(.welcome(b), from: b.id, at: at(6))
        XCTAssertEqual(book.record(for: b.id)?.link, .online(b))
        XCTAssertEqual(book.record(for: a.id)?.link, .online(a))
    }

    func testDisconnectOnlyClosesThatPhone() {
        let book = twoOnline()
        let actions = book.removeClaim(.testHook, from: b.id)
        XCTAssertEqual(actions, [.close(deviceId: b.id)])
        XCTAssertEqual(book.record(for: a.id)?.link, .online(a))
        XCTAssertEqual(book.currentId, a.id)
    }

    // MARK: Events stay with their phone

    func testFailedEventOnBChangesNoAState() {
        let book = twoOnline()
        let before = book.record(for: a.id)?.link

        let result = book.handle(.attemptFailed(reason: "timeout"), from: b.id, at: at(2))
        XCTAssertEqual(book.record(for: a.id)?.link, before)
        XCTAssertFalse(result.affectsCurrent)
        XCTAssertFalse(result.currentLinkLost)
        XCTAssertEqual(book.record(for: b.id)?.link, .reconnecting(b))
    }

    func testANonCurrentEventNeverReachesTheCurrentSurfaces() {
        let book = twoOnline()
        let events: [LinkEvent] = [
            .attemptFailed(reason: "timeout"),
            .welcome(b),
            .reachabilityHint,
            .tick,
        ]
        for event in events {
            let result = book.handle(event, from: b.id, at: at(2))
            XCTAssertFalse(result.affectsCurrent, "\(event) leaked into the current phone")
        }
        XCTAssertEqual(book.record(for: a.id)?.link, .online(a))
        XCTAssertTrue(book.handle(.welcome(a), from: a.id, at: at(2)).affectsCurrent)

        // A drop on the current phone is the one event that tells the surfaces.
        book.handle(.attemptFailed(reason: "timeout"), from: a.id, at: at(3))
        let drop = book.handle(.attemptFailed(reason: "timeout"), from: a.id, at: at(4))
        XCTAssertTrue(drop.affectsCurrent)
    }

    // MARK: Per-phone retry

    func testEachPhoneRetriesOnItsOwnBackoff() {
        let book = PhoneBook()
        book.setCurrent(a.id, phone: a)
        book.addClaim(.testHook, to: b.id, phone: b)
        XCTAssertEqual(book.handle(.activate(a), from: a.id, at: t0).actions,
                       [.attempt(deviceId: a.id, after: 0)])
        XCTAssertEqual(book.handle(.activate(b), from: b.id, at: t0).actions,
                       [.attempt(deviceId: b.id, after: 0)])

        XCTAssertEqual(book.handle(.attemptFailed(reason: "timeout"), from: a.id, at: at(1)).actions,
                       [.attempt(deviceId: a.id, after: 1)])
        XCTAssertEqual(book.handle(.attemptFailed(reason: "timeout"), from: a.id, at: at(2)).actions,
                       [.attempt(deviceId: a.id, after: 2)])
        XCTAssertEqual(book.handle(.attemptFailed(reason: "timeout"), from: b.id, at: at(2)).actions,
                       [.attempt(deviceId: b.id, after: 1)])

        XCTAssertEqual(book.record(for: a.id)?.machine.consecutiveFailures, 2)
        XCTAssertEqual(book.record(for: b.id)?.machine.consecutiveFailures, 1)
    }

    // MARK: Lifecycle

    func testShutdownClosesEverySession() {
        let book = twoOnline()
        let actions = book.closeAll()
        XCTAssertTrue(actions.contains(.close(deviceId: a.id)))
        XCTAssertTrue(actions.contains(.close(deviceId: b.id)))
        XCTAssertEqual(book.record(for: a.id)?.link, .idle)
        XCTAssertEqual(book.record(for: b.id)?.link, .idle)
    }

    func testTheCurrentPhoneIsTheRememberedActiveOne() {
        let profile = Profile(name: "unit-phonebook-\(UUID().uuidString.prefix(8).lowercased())")!
        defer {
            if let suite = profile.defaultsSuiteName { profile.defaults.removePersistentDomain(forName: suite) }
            try? FileManager.default.removeItem(at: profile.supportDirectoryUrl)
        }
        let remembered = RememberedPhones(profile: profile)
        remembered.remember(a)
        remembered.remember(b)
        remembered.setActive(id: b.id)

        let book = PhoneBook()
        let result = book.start(active: remembered.active?.ref, at: t0)
        XCTAssertEqual(book.currentId, b.id)
        XCTAssertEqual(book.records.keys.sorted(), [b.id])
        XCTAssertEqual(result.actions, [.attempt(deviceId: b.id, after: 0)])
    }

    func testLaunchConnectsOnlyTheCurrentPhone() {
        let book = PhoneBook()
        let result = book.start(active: a, at: t0)
        XCTAssertEqual(book.currentId, a.id)
        XCTAssertEqual(book.records.keys.sorted(), [a.id])
        XCTAssertEqual(result.actions, [.attempt(deviceId: a.id, after: 0)])
        XCTAssertEqual(book.record(for: a.id)?.claims, [.current])
    }
}
