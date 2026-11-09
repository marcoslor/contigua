// Discovery coalescing, the remembered-phone store, the apps cache and the
// small pure helpers the views use.

import Network
import XCTest
@testable import PocketDeck

final class DiscoveryCoalesceTests: XCTestCase {
    private func candidate(_ name: String, id: String?, rank: Int = 0, version: String? = "1",
                           model: String = "Pixel") -> DiscoveryCandidate {
        var txt = ["name": name, "model": model]
        if let id { txt["id"] = id }
        if let version { txt["v"] = version }
        return DiscoveryCandidate(serviceName: name, txt: txt, interfaceRank: rank,
                                  endpoint: .service(name: name, type: "_pocketdeck._tcp", domain: "local", interface: nil))
    }

    func testOneRowPerDeviceIdAcrossInterfaces() {
        let phones = Discovery.phones(from: [candidate("Pixel", id: "aaa", rank: 3), candidate("Pixel", id: "aaa", rank: 0),
                                             candidate("Pixel", id: "aaa", rank: 2)])
        XCTAssertEqual(phones.map(\.deviceId), ["aaa"])
    }

    func testResultsWithoutATextIdAreIgnored() {
        XCTAssertTrue(Discovery.phones(from: [candidate("Pixel Walk", id: nil)]).isEmpty)
        XCTAssertTrue(Discovery.phones(from: [candidate("Pixel Walk", id: "")]).isEmpty)
    }

    func testTheDeviceIdIsNeverTheServiceName() {
        let phones = Discovery.phones(from: [candidate("Pixel Walk", id: nil), candidate("Pixel Walk", id: "0b8daa")])
        XCTAssertEqual(phones.map(\.deviceId), ["0b8daa"])
    }

    func testSortedByNameAndOtherVersionsSkipped() {
        let phones = Discovery.phones(from: [candidate("Zed", id: "z"), candidate("alpha", id: "a"),
                                             candidate("Old", id: "o", version: "2")])
        XCTAssertEqual(phones.map(\.name), ["alpha", "Zed"])
    }
}

final class RememberedPhonesTests: XCTestCase {
    private let suite = "dev.pocketdeck.tests.remembered"
    private var defaults: UserDefaults!
    private var directory: URL!

    override func setUpWithError() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pd-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private let phone = PhoneRef(id: "aaa", name: "Pixel 9", model: "Pixel 9")

    func testRememberingKeepsNameAndMakesThePhoneActive() {
        let store = RememberedPhones(defaults: defaults)
        XCTAssertNil(store.active)
        store.remember(phone)
        XCTAssertEqual(store.active?.name, "Pixel 9")
        XCTAssertEqual(store.all.map(\.id), ["aaa"])
    }

    func testTheMostRecentlyUsedPhoneIsActiveUntilOneIsChosen() {
        let store = RememberedPhones(defaults: defaults)
        store.remember(phone, at: Date(timeIntervalSince1970: 100))
        store.remember(PhoneRef(id: "bbb", name: "Galaxy", model: ""), at: Date(timeIntervalSince1970: 200), makeActive: false)
        XCTAssertEqual(store.active?.id, "aaa") // explicit choice from remember()
        defaults.removeObject(forKey: "activePhoneId")
        XCTAssertEqual(store.active?.id, "bbb")
        store.setActive(id: "aaa")
        XCTAssertEqual(store.active?.id, "aaa")
    }

    func testTrustLostSurvivesARelaunchWithItsKind() {
        let store = RememberedPhones(defaults: defaults)
        store.remember(phone, at: Date(timeIntervalSince1970: 100))
        XCTAssertNil(store.phone(id: "aaa")?.trustLost)

        store.setTrustLost(.inferred, id: "aaa")
        let relaunched = RememberedPhones(defaults: defaults)
        XCTAssertEqual(relaunched.phone(id: "aaa")?.trustLost, .inferred,
                       "an inferred trust loss comes back after a relaunch")

        relaunched.setTrustLost(.told, id: "aaa")
        XCTAssertEqual(RememberedPhones(defaults: defaults).phone(id: "aaa")?.trustLost, .told)

        relaunched.clearTrustLost(id: "aaa")
        XCTAssertNil(RememberedPhones(defaults: defaults).phone(id: "aaa")?.trustLost)

        relaunched.setTrustLost(.told, id: "aaa")
        relaunched.forget(id: "aaa")
        XCTAssertNil(RememberedPhones(defaults: defaults).phone(id: "aaa"),
                     "Forget This Phone removes the record and its trust loss")
    }

    func testRememberingAgainKeepsTheTrustLostKind() {
        let store = RememberedPhones(defaults: defaults)
        store.remember(phone, at: Date(timeIntervalSince1970: 100))
        store.setTrustLost(.told, id: "aaa")
        store.remember(phone, at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(store.phone(id: "aaa")?.trustLost, .told)
    }

    func testAPhoneWithoutAPinIsStillRemembered() {
        // The pin lives in the pin store; losing it must not erase the phone.
        let store = RememberedPhones(defaults: defaults)
        store.remember(phone)
        XCTAssertTrue(store.active?.id == "aaa")
    }

    func testForgetRemovesThePhoneAndTheActiveChoice() {
        let store = RememberedPhones(defaults: defaults)
        store.remember(phone)
        store.forget(id: "aaa")
        XCTAssertTrue(store.all.isEmpty)
        XCTAssertNil(store.active)
    }

    func testProfilesDoNotShareMemory() {
        let other = UserDefaults(suiteName: suite + ".other")!
        defer { other.removePersistentDomain(forName: suite + ".other") }
        RememberedPhones(defaults: defaults).remember(phone)
        XCTAssertTrue(RememberedPhones(defaults: other).all.isEmpty)
    }

    func testAppsCacheRoundTripsPerPhone() {
        let cache = AppsCache(directory: directory)
        let apps = [AppInfo(json: ["pkg": "a.b", "label": "Camera", "activity": "a.b/.Main"])!,
                    AppInfo(json: ["pkg": "c.d", "label": "Maps"])!]
        cache.store(apps, deviceId: "aaa")
        XCTAssertEqual(cache.load(deviceId: "aaa"), apps)
        XCTAssertTrue(cache.load(deviceId: "bbb").isEmpty)
        cache.remove(deviceId: "aaa")
        XCTAssertTrue(cache.load(deviceId: "aaa").isEmpty)
    }
}

final class PairingCodeFormatTests: XCTestCase {
    func testSixDigitsAreGroupedThreeAndThree() {
        XCTAssertEqual(groupedPairingCode("482913"), "482 913")
        XCTAssertEqual(groupedPairingCode("000007"), "000 007")
    }

    func testAnythingElseIsShownAsIs() {
        XCTAssertEqual(groupedPairingCode("4829"), "4829")
        XCTAssertEqual(groupedPairingCode(""), "")
    }
}

final class QRProbePlannerTests: XCTestCase {
    private func phone(_ id: String) -> DiscoveredPhone {
        DiscoveredPhone(serviceName: id, deviceId: id, name: id, model: "", version: "1",
                        endpoint: .service(name: id, type: "_pocketdeck._tcp", domain: "local", interface: nil))
    }

    private let now = Date(timeIntervalSince1970: 1000)

    private func ids(paired: Set<String> = [], active: Set<String> = [], last: [String: Date] = [:],
                     busy: [String: Date] = [:]) -> [String] {
        QRProbePlanner.candidates(phones: [phone("a"), phone("b")], paired: paired, active: active,
                                  lastProbe: last, busyUntil: busy, now: now).map(\.deviceId)
    }

    func testProbesEveryUnpairedPhone() { XCTAssertEqual(ids(), ["a", "b"]) }
    func testSkipsPhonesAlreadyPairedWithThisMac() { XCTAssertEqual(ids(paired: ["a"]), ["b"]) }
    func testSkipsPhonesBeingProbed() { XCTAssertEqual(ids(active: ["b"]), ["a"]) }

    func testProbesEachPhoneAtMostEveryFourSeconds() {
        XCTAssertEqual(ids(last: ["a": now.addingTimeInterval(-3.9)]), ["b"])
        XCTAssertEqual(ids(last: ["a": now.addingTimeInterval(-4)]), ["a", "b"])
    }

    func testLeavesBusyPhonesAloneUntilTheyAreFree() {
        XCTAssertEqual(ids(busy: ["a": now.addingTimeInterval(10)]), ["b"])
        XCTAssertEqual(ids(busy: ["a": now.addingTimeInterval(-1)]), ["a", "b"])
    }
}

final class GridNavigationTests: XCTestCase {
    func testFirstArrowSelectsTheFirstCell() {
        XCTAssertEqual(GridNavigation.move(nil, count: 10, columns: 4, .down), 0)
        XCTAssertNil(GridNavigation.move(nil, count: 0, columns: 4, .down))
    }

    func testMovesWithinTheGridAndStopsAtTheEdges() {
        XCTAssertEqual(GridNavigation.move(0, count: 10, columns: 4, .right), 1)
        XCTAssertEqual(GridNavigation.move(0, count: 10, columns: 4, .left), 0)
        XCTAssertEqual(GridNavigation.move(1, count: 10, columns: 4, .down), 5)
        XCTAssertEqual(GridNavigation.move(5, count: 10, columns: 4, .up), 1)
        XCTAssertEqual(GridNavigation.move(1, count: 10, columns: 4, .up), 1)
        XCTAssertEqual(GridNavigation.move(9, count: 10, columns: 4, .right), 9)
        XCTAssertEqual(GridNavigation.move(7, count: 10, columns: 4, .down), 7)
    }

    func testFilterMatchesLabelsCaseInsensitively() {
        let apps = [AppInfo(json: ["pkg": "a", "label": "Camera"])!, AppInfo(json: ["pkg": "b", "label": "Maps"])!]
        XCTAssertEqual(GridNavigation.filter(apps, query: "cam").map(\.pkg), ["a"])
        XCTAssertEqual(GridNavigation.filter(apps, query: "  ").count, 2)
        XCTAssertTrue(GridNavigation.filter(apps, query: "zzz").isEmpty)
    }
}
