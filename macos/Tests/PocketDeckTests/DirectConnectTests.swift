// Cached-address store + the direct-connect policy (discovery beats the cache;
// the cache fills the discovery gap; a mismatched phone drops the address).

import Network
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

    func testMismatchDropsOnlyThatDevicesAddress() {
        let cache = store()
        cache.store(CachedAddress(host: "127.0.0.1", port: 47000), deviceId: "aaa")
        cache.store(CachedAddress(host: "127.0.0.2", port: 47001), deviceId: "bbb")
        // The phone behind the address answered with another id.
        cache.forget(deviceId: "aaa")
        XCTAssertNil(cache.address(forDeviceId: "aaa"))
        XCTAssertEqual(cache.address(forDeviceId: "bbb")?.port, 47001)
    }

    func testScopedAddressesResolveToTheirIPv4Literal() {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("192.168.1.20%en0"), port: 47000)
        XCTAssertEqual(endpoint.resolvedIPv4Address, CachedAddress(host: "192.168.1.20", port: 47000))
    }

    // MARK: Endpoint planner

    private let address = CachedAddress(host: "10.0.0.5", port: 47000)

    func testDiscoveryIsTheFirstChoice() {
        XCTAssertEqual(EndpointPlanner().choose(discovered: true, cached: address, lastAttemptWasService: false,
                                                lastAttemptFailed: false, sinceLaunch: 0), .service)
    }

    func testFailedServiceAttemptFallsBackToTheCachedAddress() {
        XCTAssertEqual(EndpointPlanner().choose(discovered: true, cached: address, lastAttemptWasService: true,
                                                lastAttemptFailed: true, sinceLaunch: 30), .cached(address))
        // Nothing remembered: keep using the service.
        XCTAssertEqual(EndpointPlanner().choose(discovered: true, cached: nil, lastAttemptWasService: true,
                                                lastAttemptFailed: true, sinceLaunch: 30), .service)
    }

    func testWaitsOutTheDiscoveryGraceBeforeTheCachedAddress() {
        let planner = EndpointPlanner()
        XCTAssertEqual(planner.choose(discovered: false, cached: address, lastAttemptWasService: false,
                                      lastAttemptFailed: false, sinceLaunch: 0), .wait(1.5))
        XCTAssertEqual(planner.choose(discovered: false, cached: address, lastAttemptWasService: false,
                                      lastAttemptFailed: false, sinceLaunch: 1.0), .wait(0.5))
        XCTAssertEqual(planner.choose(discovered: false, cached: address, lastAttemptWasService: false,
                                      lastAttemptFailed: false, sinceLaunch: 1.5), .cached(address))
    }

    func testNothingToConnectTo() {
        XCTAssertEqual(EndpointPlanner().choose(discovered: false, cached: nil, lastAttemptWasService: false,
                                                lastAttemptFailed: false, sinceLaunch: 30), .none)
    }

    func testLastPairedDeviceComesFirst() {
        let cache = store()
        cache.store(CachedAddress(host: "10.0.0.1", port: 1), deviceId: "aaa")
        cache.store(CachedAddress(host: "10.0.0.2", port: 2), deviceId: "bbb")
        let keys = PairKeyStore(defaults: defaults, keychain: Keychain(service: suiteName))
        keys.lastDeviceId = "bbb"
        XCTAssertEqual(cache.deviceIds, ["aaa", "bbb"])
        // The store itself has no opinion about order.
        XCTAssertEqual(cache.address(forDeviceId: "bbb")?.host, "10.0.0.2")
    }
}
