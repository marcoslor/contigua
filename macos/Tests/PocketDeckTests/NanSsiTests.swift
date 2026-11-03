#if POCKETDECK_DIRECT
import Foundation
import XCTest
@testable import PocketDeckDirectCore

/// The Mac's half of the key and the service-specific info, byte for byte
/// against P3's phone code (docs/design/direct-link.md §5, §6, transport
/// DIRECT-9/DIRECT-10).
final class NanSsiTests: XCTestCase {
    private let key = (0..<32).map { UInt8($0) }
    private let otherKey = (1...32).map { UInt8($0) }
    private let hexA = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    private let hexB = "1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100"

    // MARK: the written formula, P3's vectors

    func testTheWrittenFormulaHasThePhonesFixedVectors() {
        XCTAssertEqual(NanSsi.hex(key: key, window: 0), "79f9fb0dab2fb6bb")
        XCTAssertEqual(NanSsi.hex(key: key, window: 1), "c3d0b584e839dec9")
        XCTAssertEqual(NanSsi.hex(key: key, window: 17), "83dede3e40c31eee")
        XCTAssertEqual(NanSsi.hex(key: otherKey, window: 3),
                       NanSsi.hex(key: otherKey, window: 3))
        XCTAssertNotEqual(NanSsi.hex(key: key, window: 3),
                          NanSsi.hex(key: otherKey, window: 3))
    }

    func testTheWindowTurnsEveryTenMinutes() {
        XCTAssertEqual(NanSsi.windowSeconds, 600)
        XCTAssertEqual(NanSsi.window(epochSeconds: 0), 0)
        XCTAssertEqual(NanSsi.window(epochSeconds: 599), 0)
        XCTAssertEqual(NanSsi.window(epochSeconds: 600), 1)
        XCTAssertEqual(NanSsi.window(epochSeconds: 1199), 1)
        XCTAssertEqual(NanSsi.window(epochSeconds: 1200), 2)
    }

    func testAnSsiIsEightBytes() {
        XCTAssertEqual(NanSsi.bytes(key: key, window: 1).bytes.count, 8)
        XCTAssertEqual(NanSsi.hex(key: key, window: 1).count, 16)
    }

    // MARK: the passphrase and the fingerprint

    func testThePassphraseIsTheBase64OfTheRawBytes() throws {
        let bytes = try XCTUnwrap(DirectKey.parse(hexA))
        XCTAssertEqual(DirectKey.passphrase(bytes),
                       "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")
        XCTAssertEqual(DirectKey.passphrase(bytes).count, 44)
        let second = try XCTUnwrap(DirectKey.parse(hexB))
        XCTAssertEqual(DirectKey.passphrase(second).count, 44)
        XCTAssertEqual(DirectKey.passphrase(bytes), DirectKey.passphrase(key))
    }

    func testTheFingerprintIsTheFirstEightHexOfSha256() throws {
        XCTAssertEqual(DirectKey.fingerprint(key), "630dcd29")
        XCTAssertEqual(DirectKey.fingerprint(otherKey), "ae216c2e")
        XCTAssertEqual(DirectKey.fingerprint(key).count, 8)
        XCTAssertFalse(DirectKey.fingerprint(key).contains(hexA.prefix(8)))
        let bytes = try XCTUnwrap(DirectKey.parse(hexA))
        XCTAssertEqual(DirectKey.hex(bytes), hexA)
    }

    func testAKeyIsExactlySixtyFourHexCharacters() {
        XCTAssertEqual(DirectKey.parse(hexA)?.count, 32)
        XCTAssertEqual(DirectKey.parse(hexA.uppercased())?.count, 32)
        XCTAssertNil(DirectKey.parse(nil))
        XCTAssertNil(DirectKey.parse(""))
        XCTAssertNil(DirectKey.parse(String(hexA.dropLast())))
        XCTAssertNil(DirectKey.parse(hexA + "00"))
        XCTAssertNil(DirectKey.parse("z" + String(hexA.dropFirst())))
        XCTAssertNil(DirectKey.parse("not-a-key"))
        XCTAssertEqual(DirectKey.parse(hexA).map(DirectKey.hex), hexA)
    }

    // MARK: §6's window

    func testTheAcceptedSetIsTheCurrentWindowAndItsTwoNeighbours() {
        let now: Int64 = 1_700_000_000
        let window = NanSsi.window(epochSeconds: now)
        let accepted = NanSsi.accepted(key: key, epochSeconds: now)
        XCTAssertEqual(accepted.count, 3)
        XCTAssertEqual(accepted, [NanSsi.bytes(key: key, window: window - 1),
                                  NanSsi.bytes(key: key, window: window),
                                  NanSsi.bytes(key: key, window: window + 1)])
        XCTAssertTrue(NanSsi.accepts(NanSsi.bytes(key: key, window: window),
                                     key: key, epochSeconds: now))
        XCTAssertTrue(NanSsi.accepts(NanSsi.bytes(key: key, window: window - 1),
                                     key: key, epochSeconds: now))
        XCTAssertTrue(NanSsi.accepts(NanSsi.bytes(key: key, window: window + 1),
                                     key: key, epochSeconds: now))
        XCTAssertFalse(NanSsi.accepts(NanSsi.bytes(key: key, window: window + 2),
                                      key: key, epochSeconds: now))
        XCTAssertFalse(NanSsi.accepts(NanSsi.bytes(key: key, window: window - 2),
                                      key: key, epochSeconds: now))
        XCTAssertFalse(NanSsi.accepts(NanSsi.bytes(key: otherKey, window: window),
                                      key: key, epochSeconds: now))
        XCTAssertFalse(NanSsi.accepts(NanSsi([]), key: key, epochSeconds: now))
    }

    func testTheMachineIgnoresAStaleDiscovery() throws {
        let now: Int64 = 1_700_000_000
        let window = NanSsi.window(epochSeconds: now)
        let attempt = NanAttempt(service: "_pocketdeck-nan._tcp",
                                 windows: NanSsi.accepted(key: key, epochSeconds: now),
                                 passphrase: DirectKey.passphrase(key))
        let subscribing = NanSessionState.subscribing(attempt)
        let stale = NanSessionEvent.discovered(
            NanDiscovery(token: 4, ssi: NanSsi.bytes(key: key, window: window + 2)))
        XCTAssertEqual(NanSessionMachine.step(subscribing, stale, interface: "nan0").0,
                       subscribing)
        XCTAssertEqual(NanSessionMachine.step(subscribing, stale, interface: "nan0").1, [])

        let current = NanSessionEvent.discovered(
            NanDiscovery(token: 5, ssi: NanSsi.bytes(key: key, window: window)))
        let step = NanSessionMachine.step(subscribing, current, interface: "nan0")
        guard case .discovered(_, let token) = step.0 else {
            return XCTFail("a current-window discovery must start the NDP")
        }
        XCTAssertEqual(token, 5)
        XCTAssertEqual(step.1, [.startDataSession(token: 5,
                                                  passphrase: attempt.passphrase)])
    }
}
#endif
