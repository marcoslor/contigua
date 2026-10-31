// Spotlight for phone apps: item contents, throttled re-indexing, domain
// removal on forget, and the continuation request.

import CoreSpotlight
import XCTest
@testable import PocketDeck

private final class SpyIndex: SearchIndexing {
    /// Set to make the index call come back as refused.
    var failure: Error?
    var indexedCalls: [[CSSearchableItem]] = []
    var deletedDomains: [[String]] = []
    var deletedIdentifiers: [[String]] = []
    /// Every call in order, so a test can tell a delete-then-add from an add alone.
    var calls: [String] = []

    func indexSearchableItems(_ items: [CSSearchableItem],
                              completionHandler: (@Sendable (Error?) -> Void)?) {
        indexedCalls.append(items)
        calls.append("index")
        completionHandler?(failure)
    }

    func deleteSearchableItems(withDomainIdentifiers domainIdentifiers: [String],
                               completionHandler: (@Sendable (Error?) -> Void)?) {
        deletedDomains.append(domainIdentifiers)
        calls.append("delete")
        completionHandler?(nil)
    }

    func deleteSearchableItems(withIdentifiers identifiers: [String],
                               completionHandler: (@Sendable (Error?) -> Void)?) {
        deletedIdentifiers.append(identifiers)
        calls.append("delete-item")
        completionHandler?(nil)
    }
}

@MainActor
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
        XCTAssertEqual(items[0].attributeSet.title, "Settings (FakePhone)")
        XCTAssertEqual(items[1].attributeSet.title, "Spotify (FakePhone)")
        XCTAssertEqual(items[0].attributeSet.contentDescription, "Android app on FakePhone")
        XCTAssertNil(items[0].attributeSet.thumbnailData)
        XCTAssertEqual(items[1].attributeSet.thumbnailData, png)
    }

    func testTitleNamesTheAppThenThePhone() {
        let items = SpotlightIndexer.items(apps: apps, deviceId: "a1b2c3", phoneName: "Test Phone",
                                           iconData: { _ in nil })
        XCTAssertEqual(items[1].attributeSet.title, "Spotify (Test Phone)")
        XCTAssertEqual(items[1].attributeSet.displayName, "Spotify (Test Phone)")
    }

    func testKeywordsHoldLabelPackagePhoneAndAndroid() {
        let items = SpotlightIndexer.items(apps: apps, deviceId: "a1b2c3", phoneName: "Test Phone",
                                           iconData: { _ in nil })
        XCTAssertEqual(items[1].attributeSet.keywords,
                       ["Spotify", "com.spotify.music", "Test Phone", "Android"])
    }

    func testRenamingThePhoneReplacesItsItemsWithTheNewTitles() {
        let spy = SpyIndex()
        let index = SpotlightIndex(index: spy)
        index.index(apps: apps, deviceId: "a1b2c3", phoneName: "FakePhone", iconData: { _ in nil })
        index.index(apps: apps, deviceId: "a1b2c3", phoneName: "Test Phone", iconData: { _ in nil })
        XCTAssertEqual(spy.calls, ["index", "delete", "index"])
        XCTAssertEqual(spy.deletedDomains, [["a1b2c3"]])
        XCTAssertEqual(spy.indexedCalls[1].map { $0.attributeSet.title },
                       ["Settings (Test Phone)", "Spotify (Test Phone)"])
        XCTAssertEqual(spy.indexedCalls[1].map(\.uniqueIdentifier),
                       ["a1b2c3/com.android.settings", "a1b2c3/com.spotify.music"])
    }

    func testFirstIndexOfAPhoneDeletesNothing() {
        let spy = SpyIndex()
        let index = SpotlightIndex(index: spy)
        index.index(apps: apps, deviceId: "a1b2c3", phoneName: "FakePhone", iconData: { _ in nil })
        XCTAssertEqual(spy.calls, ["index"])
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

    /// An app with a shortcut bundle is listed once, by the real bundle: its
    /// CoreSpotlight item is not indexed, is removed when the shim appears, and
    /// comes back only when the shim goes away (DOCK-9).
    func testAShimmedAppIsNotIndexedTwice() {
        let spy = SpyIndex()
        let index = SpotlightIndex(index: spy)
        let pkg = apps[1].pkg
        index.index(apps: apps, deviceId: "a1b2c3", phoneName: "FakePhone",
                    excluding: [pkg], iconData: { _ in nil })
        XCTAssertEqual(spy.indexedCalls[0].count, apps.count - 1)
        XCTAssertFalse(spy.indexedCalls[0].contains { $0.uniqueIdentifier.hasSuffix("/\(pkg)") })

        // The same list and the same shims: nothing to re-send.
        index.index(apps: apps, deviceId: "a1b2c3", phoneName: "FakePhone",
                    excluding: [pkg], iconData: { _ in nil })
        XCTAssertEqual(spy.indexedCalls.count, 1)

        // A shim appeared for that app while the list did not change: one item goes.
        index.remove(deviceId: "a1b2c3", pkg: pkg)
        XCTAssertEqual(spy.deletedIdentifiers, [["a1b2c3/\(pkg)"]])

        // The shim went away: the whole phone is indexed again, this app included.
        index.index(apps: apps, deviceId: "a1b2c3", phoneName: "FakePhone", iconData: { _ in nil })
        XCTAssertEqual(spy.indexedCalls.count, 2)
        XCTAssertEqual(spy.indexedCalls[1].count, apps.count)
        XCTAssertTrue(spy.deletedDomains.contains(["a1b2c3"]))
    }

    func testForgetRemovesOnlyThePrefixedDomainOfItsProfile() {
        let spy = SpyIndex()
        let index = SpotlightIndex(index: spy, domainPrefix: "e2e.")
        index.index(apps: apps, deviceId: "a1b2c3", phoneName: "FakePhone", iconData: { _ in nil })
        index.remove(deviceId: "a1b2c3")
        XCTAssertEqual(spy.deletedDomains, [["e2e.a1b2c3"]])
    }

    // MARK: Index health

    private let verification = SpotlightVerification(deviceId: "a1b2c3", phoneName: "FakePhone",
                                                     expectedCount: 2)

    func testTheQueryBackAsksForThePhonesKeyword() {
        XCTAssertEqual(SpotlightIndexer.keywordQuery(phoneName: "Test Phone"),
                       "kMDItemKeywords == \"Test Phone\"")
        // A phone name is the phone's own string: a quote in it must not break
        // the query, and the name never reaches a log line.
        XCTAssertEqual(SpotlightIndexer.keywordQuery(phoneName: "He said \"hi\""),
                       "kMDItemKeywords == \"He said \\\"hi\\\"\"")
    }

    func testAVerifiedIndexIsAnnouncedWithTheCounts() async {
        let spy = SpyIndex()
        let asked = expectation(description: "the app asked its index back")
        let index = SpotlightIndex(index: spy, itemCount: { query, prefix, timeout in
            XCTAssertEqual(query, SpotlightIndexer.keywordQuery(phoneName: "FakePhone"))
            XCTAssertEqual(prefix, "a1b2c3/")
            XCTAssertEqual(timeout, 30)
            asked.fulfill()
            return 2
        })
        index.index(apps: apps, deviceId: "a1b2c3", phoneName: "FakePhone", iconData: { _ in nil })
        await fulfillment(of: [asked], timeout: 5)
        await waitFor { index.state == .verified(found: 2) }
        XCTAssertEqual(index.state, .verified(found: 2))
    }

    func testAnEmptyIndexIsTheFailureOncePerLaunch() async {
        let spy = SpyIndex()
        let asked = expectation(description: "the app asked its index back")
        let index = SpotlightIndex(index: spy, itemCount: { _, _, _ in
            asked.fulfill()
            return 0
        })
        index.index(apps: apps, deviceId: "a1b2c3", phoneName: "FakePhone", iconData: { _ in nil })
        await fulfillment(of: [asked], timeout: 5)
        await waitFor { index.state == .unavailable(announced: true) }
        XCTAssertEqual(index.state, .unavailable(announced: true))
    }

    func testARefusedIndexCallAsksNothingAndIsUnavailable() async {
        let spy = SpyIndex()
        spy.failure = NSError(domain: "CSIndexErrorDomain", code: -1003)
        let asked = expectation(description: "no query back")
        asked.isInverted = true
        let index = SpotlightIndex(index: spy, itemCount: { _, _, _ in
            asked.fulfill()
            return 1
        })
        index.index(apps: apps, deviceId: "a1b2c3", phoneName: "FakePhone", iconData: { _ in nil })
        await waitFor { index.state == .unavailable(announced: true) }
        await fulfillment(of: [asked], timeout: 1)
        XCTAssertEqual(index.state, .unavailable(announced: true))
    }

    private func waitFor(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<2000 {
            if condition() { return }
            await Task.yield()
        }
    }
}

/// The index lifecycle as a table: every state takes every event, so a fix here
/// cannot leave a combination unhandled (the bug this replaced was two flags
/// that could disagree).
final class SpotlightIndexStateTests: XCTestCase {

    private let pending = SpotlightVerification(deviceId: "dev", phoneName: "Phone", expectedCount: 2)
    private var verifying: SpotlightIndexState { .verifying(pending) }

    private var settledStates: [SpotlightIndexState] {
        [.idle, .verified(found: 2), .unavailable(announced: true)]
    }

    func testSubmittingAsksTheIndexBackFromEveryState() {
        for state in [SpotlightIndexState.idle, verifying, .verified(found: 2), .unavailable(announced: true)] {
            let (next, effects) = state.applying(.submitted(pending))
            XCTAssertEqual(next, verifying, "submitted from \(state)")
            XCTAssertEqual(effects, [.verify(pending)], "submitted from \(state)")
        }
    }

    func testSubmittingNothingAsksNothing() {
        var empty = pending
        empty.expectedCount = 0
        let (next, effects) = SpotlightIndexState.idle.applying(.submitted(empty))
        XCTAssertEqual(next, .idle)
        XCTAssertEqual(effects, [.quiet])
    }

    func testRefusalSpeaksOncePerLaunch() {
        let (first, firstEffects) = SpotlightIndexState.idle.applying(.refused)
        XCTAssertEqual(first, .unavailable(announced: true))
        XCTAssertEqual(firstEffects, [.announceUnavailable])
        let (again, againEffects) = first.applying(.refused)
        XCTAssertEqual(again, .unavailable(announced: true))
        XCTAssertEqual(againEffects, [.quiet])
    }

    func testAnswerWithItemsVerifies() {
        let (next, effects) = verifying.applying(.queried(pending, found: 2))
        XCTAssertEqual(next, .verified(found: 2))
        XCTAssertEqual(effects, [.announceVerified(pending, foundCount: 2)])
    }

    func testAnEmptyAnswerIsTheFailure() {
        let (next, effects) = verifying.applying(.queried(pending, found: 0))
        XCTAssertEqual(next, .unavailable(announced: true))
        XCTAssertEqual(effects, [.announceUnavailable])
    }

    func testAnAnswerForAnotherListProvesNothing() {
        var otherPhone = pending
        otherPhone.phoneName = "Other"
        let (next, effects) = verifying.applying(.queried(otherPhone, found: 2))
        XCTAssertEqual(next, verifying)
        XCTAssertEqual(effects, [.quiet])

        var otherBatch = pending
        otherBatch.expectedCount = 3
        let (again, againEffects) = verifying.applying(.queried(otherBatch, found: 2))
        XCTAssertEqual(again, verifying)
        XCTAssertEqual(againEffects, [.quiet])
    }

    func testAnAnswerWithNothingPendingIsIgnored() {
        for state in settledStates {
            let (next, effects) = state.applying(.queried(pending, found: 2))
            XCTAssertEqual(next, state, "queried in \(state)")
            XCTAssertEqual(effects, [.quiet], "queried in \(state)")
        }
    }
}
