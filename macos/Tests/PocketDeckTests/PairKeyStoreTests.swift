// Pair keys live in a 0600 JSON file per profile; nothing here touches the Keychain.

import XCTest
@testable import PocketDeck

extension PairKeyFile {
    /// A key file in its own temporary folder, so tests never share keys.
    static func scratch() -> PairKeyFile {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocketdeck-keys-\(UUID().uuidString)", isDirectory: true)
        return PairKeyFile(url: dir.appendingPathComponent("pairkeys.json"))
    }
}

final class PairKeyStoreTests: XCTestCase {
    private var file: PairKeyFile!
    private var suite: String!
    private var store: PairKeyStore!

    override func setUp() {
        file = .scratch()
        suite = "dev.pocketdeck.tests.keys.\(UUID().uuidString)"
        store = PairKeyStore(defaults: UserDefaults(suiteName: suite)!, keys: file)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue
    }

    func testSaveAndLoad() {
        let key = Data((0..<32).map { UInt8($0) })
        store.store(key: key, deviceId: "aaa")
        XCTAssertEqual(store.key(forDeviceId: "aaa"), key)
        XCTAssertEqual(store.lastDeviceId, "aaa")
        // A fresh store over the same file sees the key: it is on disk, not cached.
        let reopened = PairKeyStore(defaults: UserDefaults(suiteName: suite)!, keys: PairKeyFile(url: file.url))
        XCTAssertEqual(reopened.key(forDeviceId: "aaa"), key)
        XCTAssertNil(reopened.key(forDeviceId: "bbb"))
    }

    func testDeleteOneAndAll() {
        store.store(key: Data([1]), deviceId: "aaa")
        store.store(key: Data([2]), deviceId: "bbb")
        XCTAssertEqual(store.accounts(), ["aaa", "bbb"])
        store.forget(deviceId: "bbb")
        XCTAssertNil(store.key(forDeviceId: "bbb"))
        XCTAssertNil(store.lastDeviceId)
        XCTAssertEqual(store.key(forDeviceId: "aaa"), Data([1]))
        store.deleteAll()
        XCTAssertEqual(store.accounts(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testFileIs0600AndFolderIs0700() throws {
        store.store(key: Data([1]), deviceId: "aaa")
        XCTAssertEqual(try mode(file.url), 0o600)
        XCTAssertEqual(try mode(file.url.deletingLastPathComponent()), 0o700)
        store.store(key: Data([2]), deviceId: "bbb")
        XCTAssertEqual(try mode(file.url), 0o600)
    }

    func testCandidateKeyFallsBackToTheOnlyKey() {
        store.store(key: Data([7]), deviceId: "aaa")
        store.lastDeviceId = nil
        XCTAssertEqual(store.candidateKey(knownDeviceId: nil)?.deviceId, "aaa")
    }

    func testProfilesDoNotShareKeys() {
        let one = Profile(name: "unit-keys-one")!.pairKeys
        let two = Profile(name: "unit-keys-two")!.pairKeys
        XCTAssertNotEqual(one.url, two.url)
        XCTAssertNotEqual(one.url, Profile.default.pairKeys.url)
        let a = PairKeyFile(url: file.url.deletingLastPathComponent().appendingPathComponent("a/pairkeys.json"))
        let b = PairKeyFile(url: file.url.deletingLastPathComponent().appendingPathComponent("b/pairkeys.json"))
        a.store(Data([1]), account: "aaa")
        XCTAssertNil(b.load(account: "aaa"))
        XCTAssertEqual(b.accounts(), [])
    }
}
