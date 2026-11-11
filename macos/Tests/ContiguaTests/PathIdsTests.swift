// Session and path ids (PATH-3/19) and the protocol version pin (PATH-1/2).

import XCTest
@testable import Contigua

final class PathIdsTests: XCTestCase {
    func testSessionIdsAre128RandomBitsAs32LowercaseHex() {
        var seen = Set<String>()
        for _ in 0..<512 {
            let id = PathIds.sessionId()
            XCTAssertEqual(id.count, 32)
            XCTAssertTrue(id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            XCTAssertTrue(seen.insert(id).inserted, "a session id was reused")
        }
    }

    func testPathIdsAreEightHexAndUniqueInTheLiveSet() {
        var live = Set<String>()
        for _ in 0..<1000 {
            let id = PathIds.pathId(among: live)
            XCTAssertEqual(id.count, 8)
            XCTAssertTrue(id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            XCTAssertTrue(live.insert(id).inserted)
        }
    }

    func testPathIdAvoidsAnAlreadyLiveId() {
        // A generator that always answers the same 4 bytes must still make progress.
        struct Fixed: RandomNumberGenerator {
            var calls = 0
            mutating func next() -> UInt64 { calls += 1; return 0xdeadbeef &+ UInt64(calls) }
        }
        var generator = Fixed()
        var live: Set<String> = ["deadbeef"]
        var produced = Set<String>()
        for _ in 0..<8 {
            let id = PathIds.pathId(among: live, using: &generator)
            produced.insert(id)
            live.insert(id)
        }
        XCTAssertFalse(produced.contains("deadbeef"))
        XCTAssertEqual(live.count, 9)
    }

    func testSessionIdsAreNotDerivedFromAPeerId() {
        // Randomness across sessions, not a hash of an input: two fresh ids differ.
        XCTAssertNotEqual(PathIds.sessionId(), PathIds.sessionId())
    }
}

final class VersionTests: XCTestCase {
    func testProtocolVersionIsFour() {
        XCTAssertEqual(PathVersion.current, 4)
    }

    func testEveryOtherVersionIsRefused() {
        XCTAssertFalse(PathVersion.refused(4))
        XCTAssertTrue(PathVersion.refused(3))
        XCTAssertTrue(PathVersion.refused(5))
        XCTAssertTrue(PathVersion.refused(nil), "a v3 phone sends no v")
    }

    func testTheMacNamesWhichAppToUpdate() {
        XCTAssertEqual(PathVersion.macSentence(peer: 4), "Update Contigua on your phone.")
        XCTAssertEqual(PathVersion.macSentence(peer: 3), "Update Contigua on your phone.")
        XCTAssertEqual(PathVersion.macSentence(peer: nil), "Update Contigua on your phone.")
        XCTAssertEqual(PathVersion.macSentence(peer: 5), "Update Contigua on this Mac.")
    }

    func testThePhoneNamesWhichAppToUpdateFromTheHellosV() {
        XCTAssertEqual(PathVersion.phoneSentence(mac: 3), "Update Contigua on this Mac.")
        XCTAssertEqual(PathVersion.phoneSentence(mac: nil), "Update Contigua on this Mac.")
        XCTAssertEqual(PathVersion.phoneSentence(mac: 5), "Update Contigua on your phone.")
    }

    func testTheRefusalCarriesTheRefusingSidesOwnVersion() {
        let frame = PathVersion.refusal(own: 4)
        XCTAssertEqual(frame.type, MessageType.json.rawValue)
        let message = JSONFrame.decode(payload: frame.payload)!
        XCTAssertEqual(message.t, "error")
        XCTAssertEqual(message.string("code"), "version")
        XCTAssertEqual(message.int("v"), 4)
    }

    func testARefusedPeerIsNeverRetriedAsAOneConnectionSession() {
        // No reduced mode exists: the only decision a version makes is refuse.
        for v in [nil, 1, 2, 3, 5, 6] as [Int?] {
            XCTAssertTrue(PathVersion.refused(v))
        }
        XCTAssertTrue(NoFallback.isRefusedAsAVersionMismatch(code: "version"))
    }
}
