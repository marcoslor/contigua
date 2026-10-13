// Spotlight for phone apps: item contents, throttled re-indexing, domain
// removal on forget, and the continuation request.

import CoreSpotlight
import XCTest
@testable import PocketDeck

private final class SpyIndex: SearchIndexing {
    var indexedCalls: [[CSSearchableItem]] = []
    var deletedDomains: [[String]] = []

    func indexSearchableItems(_ items: [CSSearchableItem],
                              completionHandler: (@Sendable (Error?) -> Void)?) {
        indexedCalls.append(items)
        completionHandler?(nil)
    }

    func deleteSearchableItems(withDomainIdentifiers domainIdentifiers: [String],
                               completionHandler: (@Sendable (Error?) -> Void)?) {
        deletedDomains.append(domainIdentifiers)
        completionHandler?(nil)
    }
}

final class SpotlightTests: XCTestCase {

    private func app(_ pkg: String, _ label: String, activity: String? = nil) -> AppInfo {
        var json: [String: Any] = ["pkg": pkg, "label": label]
        if let activity { json["activity"] = activity }
        return AppInfo(json: json)!
    }

    private let apps = [AppInfo(json: ["pkg": "com.android.settings", "label": "Settings",
                                       "activity": "com.android.settings/.Settings"])!,
                        AppInfo(json: ["pkg": "com.spotify.music", "label": "Spotify"])!]

    // MARK: Builder

    func testItemIdentifiersAndDomain() {
        let items = SpotlightIndexer.items(apps: apps, deviceId: "a1b2c3", phoneName: "FakePhone",
                                           iconData: { _ in nil })
        XCTAssertEqual(items.map(\.uniqueIdentifier), ["a1b2c3/com.android.settings", "a1b2c3/com.spotify.music"])
        XCTAssertEqual(items.map(\.domainIdentifier), ["a1b2c3", "a1b2c3"])
    }

    func testItemTitleDescriptionAndThumbnail() {
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        let items = SpotlightIndexer.items(apps: apps, deviceId: "a1b2c3", phoneName: "FakePhone",
                                           iconData: { pkg in pkg == "com.spotify.music" ? png : nil })
        XCTAssertEqual(items[0].attributeSet.title, "Settings")
        XCTAssertEqual(items[1].attributeSet.title, "Spotify")
        XCTAssertEqual(items[0].attributeSet.contentDescription, "Android app on FakePhone")
        XCTAssertNil(items[0].attributeSet.thumbnailData)
        XCTAssertEqual(items[1].attributeSet.thumbnailData, png)
    }

    func testSignatureChangesWithLabelOrPhoneName() {
        let base = SpotlightIndexer.signature(apps: apps, phoneName: "FakePhone")
        XCTAssertEqual(base, SpotlightIndexer.signature(apps: apps, phoneName: "FakePhone"))
        XCTAssertNotEqual(base, SpotlightIndexer.signature(apps: apps, phoneName: "Other phone"))
        var changed = apps
        changed[1] = AppInfo(json: ["pkg": "com.spotify.music", "label": "Spotify Music"])!
        XCTAssertNotEqual(base, SpotlightIndexer.signature(apps: changed, phoneName: "FakePhone"))
    }

    func testParseIdentifier() {
        XCTAssertEqual(SpotlightIndexer.parse(identifier: "abc/com.android.settings"),
                       SpotlightOpenRequest(deviceId: "abc", pkg: "com.android.settings"))
        XCTAssertNil(SpotlightIndexer.parse(identifier: "abc"))
        XCTAssertNil(SpotlightIndexer.parse(identifier: "/pkg"))
        XCTAssertNil(SpotlightIndexer.parse(identifier: "abc/"))
        XCTAssertNil(SpotlightIndexer.parse(identifier: ""))
    }

    func testContinuationRequestFromUserActivity() {
        let activity = NSUserActivity(activityType: CSSearchableItemActionType)
        activity.userInfo = [CSSearchableItemActivityIdentifier: "a1b2c3/com.android.settings"]
        XCTAssertEqual(SpotlightIndexer.request(from: activity),
                       SpotlightOpenRequest(deviceId: "a1b2c3", pkg: "com.android.settings"))

        let foreign = NSUserActivity(activityType: "dev.pocketdeck.other")
        foreign.userInfo = [CSSearchableItemActivityIdentifier: "a1b2c3/com.android.settings"]
        XCTAssertNil(SpotlightIndexer.request(from: foreign))
    }

    // MARK: Throttle

    func testIndexesOncePerAppList() {
        let spy = SpyIndex()
        let index = SpotlightIndex(index: spy)
        index.index(apps: apps, deviceId: "a1b2c3", phoneName: "FakePhone", iconData: { _ in nil })
        XCTAssertEqual(spy.indexedCalls.count, 1)
        XCTAssertEqual(spy.indexedCalls[0].count, 2)

        // A reconnect re-sends the same list: nothing to do.
        index.index(apps: apps, deviceId: "a1b2c3", phoneName: "FakePhone", iconData: { _ in nil })
        XCTAssertEqual(spy.indexedCalls.count, 1)
    }

    func testReindexesWhenTheListChanges() {
        let spy = SpyIndex()
        let index = SpotlightIndex(index: spy)
        index.index(apps: apps, deviceId: "a1b2c3", phoneName: "FakePhone", iconData: { _ in nil })
        var changed = apps
        changed.append(AppInfo(json: ["pkg": "com.new.app", "label": "New"])!)
        index.index(apps: changed, deviceId: "a1b2c3", phoneName: "FakePhone", iconData: { _ in nil })
        XCTAssertEqual(spy.indexedCalls.count, 2)
        XCTAssertEqual(spy.indexedCalls[1].count, 3)
    }

    func testTracksDevicesSeparately() {
        let spy = SpyIndex()
        let index = SpotlightIndex(index: spy)
        index.index(apps: apps, deviceId: "aaa", phoneName: "One", iconData: { _ in nil })
        index.index(apps: apps, deviceId: "bbb", phoneName: "Two", iconData: { _ in nil })
        XCTAssertEqual(spy.indexedCalls.count, 2)
        XCTAssertEqual(spy.indexedCalls[0][0].domainIdentifier, "aaa")
        XCTAssertEqual(spy.indexedCalls[1][0].domainIdentifier, "bbb")
    }

    func testIgnoresAnEmptyDeviceId() {
        let spy = SpyIndex()
        let index = SpotlightIndex(index: spy)
        index.index(apps: apps, deviceId: "", phoneName: "FakePhone", iconData: { _ in nil })
        XCTAssertTrue(spy.indexedCalls.isEmpty)
    }

    func testForgetRemovesTheDomain() {
        let spy = SpyIndex()
        let index = SpotlightIndex(index: spy)
        index.index(apps: apps, deviceId: "a1b2c3", phoneName: "FakePhone", iconData: { _ in nil })
        index.remove(deviceId: "a1b2c3")
        XCTAssertEqual(spy.deletedDomains, [["a1b2c3"]])
        // Forget-then-reconnect indexes again instead of trusting the stale cache.
        index.index(apps: apps, deviceId: "a1b2c3", phoneName: "FakePhone", iconData: { _ in nil })
        XCTAssertEqual(spy.indexedCalls.count, 2)
    }

    func testForgetRemovesOnlyThePrefixedDomainOfItsProfile() {
        let spy = SpyIndex()
        let index = SpotlightIndex(index: spy, domainPrefix: "e2e.")
        index.index(apps: apps, deviceId: "a1b2c3", phoneName: "FakePhone", iconData: { _ in nil })
        index.remove(deviceId: "a1b2c3")
        XCTAssertEqual(spy.deletedDomains, [["e2e.a1b2c3"]])
    }
}
