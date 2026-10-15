// Tests for the v2 identity store (docs/design/e2ee.md §3): identity.json
// round trip + permissions, point-fingerprint math, pair-key wipe migration,
// and the pin-mismatch tracker's one-per-minute rule. Pure unit tests; the
// real profiles' storage is never touched.

import CryptoKit
import XCTest
@testable import PocketDeck

final class IdentityV2Tests: XCTestCase {
    private var dir: URL!
    private var file: IdentityFileV2!
    private var keys: PairKeyFile!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocketdeck-idv2-\(UUID().uuidString)", isDirectory: true)
        file = IdentityFileV2(url: dir.appendingPathComponent("identity.json"))
        keys = PairKeyFile(url: dir.appendingPathComponent("pairkeys.json"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue
    }

    private func sampleIdentity() -> DeviceIdentityV2 {
        DeviceIdentityV2(
            deviceId: "mac-device-1",
            certPem: "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----",
            keyP8: "-----BEGIN PRIVATE KEY-----\nBBBB\n-----END PRIVATE KEY-----",
            pin: "83af62b58cbd0f7d55a3058d95f5ee7957ff01ba52d4b7a83b7780939a1b2c3d0"
        )
    }

    // MARK: JSON shape + round trip

    func testJsonHasExactlyTheDocumentedShape() throws {
        let identity = DeviceIdentityV2(deviceId: "id1", certPem: "CERT", keyP8: "KEY", pin: "PIN")
        let data = try JSONEncoder().encode(identity)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(Set(json.keys), DeviceIdentityV2.keys)
        XCTAssertEqual(json["pinVersion"] as! Int, 2)
        let decoded = try JSONDecoder().decode(DeviceIdentityV2.self, from: data)
        XCTAssertEqual(decoded, identity)
        XCTAssertEqual(decoded.pinVersion, 2)
    }

    func testSaveLoadRoundTripOnDisk() throws {
        let identity = sampleIdentity()
        XCTAssertTrue(file.save(identity))
        XCTAssertEqual(try mode(file.url), 0o600)
        XCTAssertEqual(try mode(dir), 0o700)
        let reopened = IdentityFileV2(url: file.url)
        XCTAssertEqual(reopened.load(), identity)
    }

    func testMissingFileLoadsNilAndClearIsIdempotent() {
        XCTAssertNil(file.load())
        XCTAssertTrue(file.save(sampleIdentity()))
        file.clear()
        XCTAssertNil(file.load())
        file.clear() // no throw if already gone
        XCTAssertNil(file.load())
    }

    // MARK: The pin math

    func testPointFingerprintIsSha256OfTheX963Point() {
        let key = P256.Signing.PrivateKey()
        let hex = PointFingerprint.hex(ofKey: key.publicKey)
        // x963Representation IS 04||X||Y (65 bytes).
        XCTAssertEqual(key.publicKey.x963Representation.count, 65)
        XCTAssertEqual(key.publicKey.x963Representation.first, 0x04)
        let expected = Data(SHA256.hash(data: key.publicKey.x963Representation))
        XCTAssertEqual(hex, expected.hexString)
        XCTAssertTrue(PointFingerprint.isWellFormed(pin: hex))
    }

    func testPinFormatChecks() {
        XCTAssertTrue(PointFingerprint.isWellFormed(pin: String(repeating: "a", count: 64)))
        XCTAssertFalse(PointFingerprint.isWellFormed(pin: String(repeating: "a", count: 63)))
        XCTAssertFalse(PointFingerprint.isWellFormed(pin: String(repeating: "A", count: 64)))
        XCTAssertFalse(PointFingerprint.isWellFormed(pin: String(repeating: "g", count: 64)))
    }

    // MARK: Migration

    func testWipePairKeysDeletesTheFileAndIsIdempotent() {
        keys.store(Data([1, 2, 3]), account: "phone-a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keys.url.path))
        XCTAssertTrue(IdentityMigrationV2.wipePairKeys(keys))
        XCTAssertFalse(FileManager.default.fileExists(atPath: keys.url.path))
        XCTAssertFalse(IdentityMigrationV2.wipePairKeys(keys)) // already gone
    }

    // MARK: Re-pair rate limiting

    func testRePairSheetOpensAtMostOncePerMinutePerDevice() {
        let tracker = PinMismatchTracker()
        let now = Date()
        XCTAssertTrue(tracker.allowAutoOpen(deviceId: "phone-a", now: now))
        XCTAssertFalse(tracker.allowAutoOpen(deviceId: "phone-a", now: now.addingTimeInterval(30)))
        XCTAssertTrue(tracker.allowAutoOpen(deviceId: "phone-b", now: now.addingTimeInterval(5)))
        XCTAssertTrue(tracker.allowAutoOpen(deviceId: "phone-a", now: now.addingTimeInterval(61)))
    }
}
