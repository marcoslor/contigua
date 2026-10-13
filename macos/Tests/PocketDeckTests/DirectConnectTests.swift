// Cached-address store + the direct-connect policy (discovery beats the cache;
// the cache fills the discovery gap; a mismatched phone drops the address).

import XCTest
@testable import PocketDeck

final class DirectConnectTests: XCTestCase {
    private let suiteName = "dev.pocketdeck.tests.directconnect"
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func store() -> CachedDeviceStore { CachedDeviceStore(defaults: defaults) }

    // MARK: Store

    func testStoresAndReadsBackOneAddressPerDevice() {
        let cache = store()
        cache.store(CachedAddress(host: "192.168.1.42", port: 47811), deviceId: "aaa")
        cache.store(CachedAddress(host: "127.0.0.1", port: 47000), deviceId: "bbb")
        XCTAssertEqual(cache.address(forDeviceId: "aaa"), CachedAddress(host: "192.168.1.42", port: 47811))
        XCTAssertEqual(cache.address(forDeviceId: "bbb"), CachedAddress(host: "127.0.0.1", port: 47000))
        XCTAssertEqual(cache.deviceIds, ["aaa", "bbb"])
        XCTAssertNil(cache.address(forDeviceId: "missing"))
    }

    func testLatestAddressOverwritesTheDevice() {
        let cache = store()
        cache.store(CachedAddress(host: "10.0.0.2", port: 1), deviceId: "aaa")
        cache.store(CachedAddress(host: "10.0.0.9", port: 2), deviceId: "aaa")
        XCTAssertEqual(cache.devices.count, 1)
        XCTAssertEqual(cache.address(forDeviceId: "aaa")?.host, "10.0.0.9")
        XCTAssertEqual(cache.address(forDeviceId: "aaa")?.port, 2)
    }

    func testRejectsNonIPv4HostsAndEmptyIds() {
        let cache = store()
        cache.store(CachedAddress(host: "fe80::1%en0", port: 47000), deviceId: "aaa")
        cache.store(CachedAddress(host: "phone.local", port: 47000), deviceId: "aaa")
        cache.store(CachedAddress(host: "1.2.3.256", port: 47000), deviceId: "aaa")
        cache.store(CachedAddress(host: "1.2.3.04", port: 47000), deviceId: "aaa")
        cache.store(CachedAddress(host: "10.0.0.1", port: 0), deviceId: "aaa")
        cache.store(CachedAddress(host: "10.0.0.1", port: 47000), deviceId: "")
        XCTAssertTrue(cache.deviceIds.isEmpty)
    }

    func testEncodeParseRoundTrip() {
        let address = CachedAddress(host: "192.168.0.17", port: 65535)
        XCTAssertEqual(CachedDeviceStore.parse(CachedDeviceStore.encode(address)), address)
        XCTAssertNil(CachedDeviceStore.parse("192.168.0.17"))
        XCTAssertNil(CachedDeviceStore.parse("192.168.0.17:"))
        XCTAssertNil(CachedDeviceStore.parse(":47000"))
        XCTAssertNil(CachedDeviceStore.parse("host.local:47000"))
        XCTAssertNil(CachedDeviceStore.parse("192.168.0.17:0"))
        XCTAssertNil(CachedDeviceStore.parse("192.168.0.17:99999"))
    }

    func testIPv4Validation() {
        XCTAssertTrue(CachedDeviceStore.isIPv4("0.0.0.0"))
        XCTAssertTrue(CachedDeviceStore.isIPv4("255.255.255.255"))
        XCTAssertFalse(CachedDeviceStore.isIPv4("256.0.0.1"))
        XCTAssertFalse(CachedDeviceStore.isIPv4("1.2.3"))
        XCTAssertFalse(CachedDeviceStore.isIPv4("1.2.3.4.5"))
        XCTAssertFalse(CachedDeviceStore.isIPv4("::1"))
        XCTAssertFalse(CachedDeviceStore.isIPv4("1.2.3.-4"))
    }

    func testStoresNameAndForgetClearsBoth() {
        let cache = store()
        cache.store(CachedAddress(host: "10.0.0.2", port: 47000), deviceId: "aaa")
        cache.store(name: "FakePhone", deviceId: "aaa")
        XCTAssertEqual(cache.name(forDeviceId: "aaa"), "FakePhone")
        cache.forget(deviceId: "aaa")
        XCTAssertNil(cache.address(forDeviceId: "aaa"))
        XCTAssertNil(cache.name(forDeviceId: "aaa"))
        XCTAssertTrue(cache.deviceIds.isEmpty)
    }

    func testRemoveAllClearsEverything() {
        let cache = store()
        cache.store(CachedAddress(host: "10.0.0.2", port: 47000), deviceId: "aaa")
        cache.store(CachedAddress(host: "10.0.0.3", port: 47001), deviceId: "bbb")
        cache.removeAll()
        XCTAssertTrue(cache.deviceIds.isEmpty)
    }

    func testMismatchPathDropsTheCandidate() {
        let cache = store()
        cache.store(CachedAddress(host: "127.0.0.1", port: 47000), deviceId: "aaa")
        let policy = DirectConnectPolicy()
        var decision = policy.decide(discoveredPaired: [], cached: cache.devices, activeDeviceId: nil,
                                     activeReady: false, elapsedSinceLaunch: 10)
        XCTAssertEqual(decision, .useCached(CachedDevice(deviceId: "aaa",
                                                         address: CachedAddress(host: "127.0.0.1", port: 47000))))
        // The phone behind the address answered with another id.
        cache.forget(deviceId: "aaa")
        decision = policy.decide(discoveredPaired: [], cached: cache.devices, activeDeviceId: nil,
                                 activeReady: false, elapsedSinceLaunch: 10)
        XCTAssertEqual(decision, .none)
    }

    // MARK: Policy

    private let cached = [CachedDevice(deviceId: "aaa", address: CachedAddress(host: "10.0.0.5", port: 47000))]

    func testDiscoveryOverridesTheCache() {
        let decision = DirectConnectPolicy().decide(discoveredPaired: ["aaa"], cached: cached,
                                                    activeDeviceId: nil, activeReady: false,
                                                    elapsedSinceLaunch: 0)
        XCTAssertEqual(decision, .useDiscovery(deviceId: "aaa"))
    }

    func testWaitsOutTheDiscoveryGraceWithNoService() {
        let policy = DirectConnectPolicy()
        XCTAssertEqual(policy.decide(discoveredPaired: [], cached: cached, activeDeviceId: nil,
                                     activeReady: false, elapsedSinceLaunch: 0), .none)
        XCTAssertEqual(policy.decide(discoveredPaired: [], cached: cached, activeDeviceId: nil,
                                     activeReady: false, elapsedSinceLaunch: 2.9), .none)
        XCTAssertEqual(policy.decide(discoveredPaired: [], cached: cached, activeDeviceId: nil,
                                     activeReady: false, elapsedSinceLaunch: 3), .useCached(cached[0]))
    }

    func testNoCacheNoCandidate() {
        XCTAssertEqual(DirectConnectPolicy().decide(discoveredPaired: [], cached: [], activeDeviceId: nil,
                                                    activeReady: false, elapsedSinceLaunch: 30), .none)
    }

    func testReadySessionIsNeverReplaced() {
        XCTAssertEqual(DirectConnectPolicy().decide(discoveredPaired: ["bbb"], cached: cached,
                                                    activeDeviceId: "aaa", activeReady: true,
                                                    elapsedSinceLaunch: 30), .none)
        XCTAssertEqual(DirectConnectPolicy().decide(discoveredPaired: [], cached: cached,
                                                    activeDeviceId: "somebody-else", activeReady: true,
                                                    elapsedSinceLaunch: 30), .none)
    }

    func testRetryingSessionIsNotReplacedByTheLaunchWait() {
        XCTAssertEqual(DirectConnectPolicy().decide(discoveredPaired: [], cached: cached,
                                                    activeDeviceId: "aaa", activeReady: false,
                                                    elapsedSinceLaunch: 30), .none)
    }

    func testFailureFallsBackToTheCachedAddress() {
        let policy = DirectConnectPolicy()
        // The discovery session to aaa failed although mDNS is gone.
        XCTAssertEqual(policy.failureDecision(deviceId: "aaa", cached: cached, discoveredPaired: []),
                       .useCached(cached[0]))
        // Still visible in discovery results: the just-used address is tried.
        XCTAssertEqual(policy.failureDecision(deviceId: "aaa", cached: cached, discoveredPaired: ["aaa"]),
                       .useCached(cached[0]))
    }

    func testFailureWithoutACachePrefersDiscovery() {
        let policy = DirectConnectPolicy()
        XCTAssertEqual(policy.failureDecision(deviceId: "aaa", cached: [], discoveredPaired: ["bbb"]),
                       .useDiscovery(deviceId: "bbb"))
        XCTAssertEqual(policy.failureDecision(deviceId: "bbb", cached: [], discoveredPaired: ["bbb"]), .none)
        XCTAssertEqual(policy.failureDecision(deviceId: nil, cached: [], discoveredPaired: []), .none)
    }

    func testLastPairedDeviceComesFirst() {
        let cache = store()
        cache.store(CachedAddress(host: "10.0.0.1", port: 1), deviceId: "aaa")
        cache.store(CachedAddress(host: "10.0.0.2", port: 2), deviceId: "bbb")
        let keys = PairKeyStore(defaults: defaults, keychain: Keychain(service: suiteName))
        keys.lastDeviceId = "bbb"
        XCTAssertEqual(cache.deviceIds, ["aaa", "bbb"])
        // AppModel orders by lastDeviceId; the store itself has no opinion.
        XCTAssertEqual(cache.address(forDeviceId: "bbb")?.host, "10.0.0.2")
    }
}
