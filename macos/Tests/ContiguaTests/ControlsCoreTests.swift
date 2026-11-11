// Control Center snapshot and request shapes (docs/design/controls.md): the
// JSON the app writes, the JSON the extension sends, and the ringer cycle.

import XCTest
@testable import Contigua

final class ControlsCoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("controls-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Snapshot

    func testSnapshotRoundTripKeepsEveryValue() throws {
        var snapshot = ControlsSnapshot()
        snapshot.connected = true
        snapshot.phone = "Nicky"
        snapshot.dnd = "alarms"
        snapshot.ringer = "vibrate"
        snapshot.ringing = true
        snapshot.updated = 1_700_000_000
        let decoded = try XCTUnwrap(snapshot.encoded().flatMap(ControlsSnapshot.decode))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertTrue(decoded.dndOn)
        XCTAssertEqual(decoded.ringerMode, .vibrate)
    }

    func testDisconnectedSnapshotHasNoPhoneOrModes() {
        let snapshot = ControlsSnapshot()
        XCTAssertFalse(snapshot.connected)
        XCTAssertNil(snapshot.phone)
        XCTAssertFalse(snapshot.dndOn)
        XCTAssertNil(snapshot.ringerMode)
    }

    func testDndWireNamesMapToTheToggle() {
        for mode in PhoneDndMode.allCases {
            var snapshot = ControlsSnapshot()
            snapshot.dnd = mode.rawValue
            XCTAssertEqual(snapshot.dndOn, mode.isOn, mode.rawValue)
        }
    }

    func testSnapshotDecodeRefusesOversizedOrForeignData() {
        XCTAssertNil(ControlsSnapshot.decode(Data()))
        XCTAssertNil(ControlsSnapshot.decode(Data(repeating: 0x41, count: ControlsSnapshot.maxBytes + 1)))
        XCTAssertNil(ControlsSnapshot.decode(Data("{\"nope\":true}".utf8)))
    }

    func testSnapshotWriteIsPrivateAndAtomic() throws {
        let url = ControlsPaths.snapshotURL(in: directory)
        var snapshot = ControlsSnapshot()
        snapshot.connected = true
        XCTAssertTrue(snapshot.write(to: url))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertEqual(ControlsSnapshot.read(from: url), snapshot)
        // A rewrite replaces the file, and no temp file is left behind.
        snapshot.ringing = true
        XCTAssertTrue(snapshot.write(to: url))
        XCTAssertEqual(ControlsSnapshot.read(from: url)?.ringing, true)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty, "leftover temp files: \(leftovers)")
    }

    func testPathsLiveWhereExpected() {
        XCTAssertEqual(ControlsPaths.snapshotURL(in: directory).lastPathComponent, "controls.json")
        XCTAssertEqual(ControlsPaths.socketPath(in: directory), directory.appendingPathComponent("controls.sock").path)
        XCTAssertEqual(ControlsPaths.groupID, "group.app.contigua.mac.controls")
    }

    // MARK: Requests

    func testValidRequestsParse() {
        XCTAssertEqual(ControlsRequest.parse(Data(#"{"t":"dnd","on":true}"#.utf8)), .dnd(true))
        XCTAssertEqual(ControlsRequest.parse(Data(#"{"t":"dnd","on":false}"#.utf8)), .dnd(false))
        XCTAssertEqual(ControlsRequest.parse(Data(#"{"t":"ring"}"#.utf8)), .ring)
        XCTAssertEqual(ControlsRequest.parse(Data(#"{"t":"ring.stop"}"#.utf8)), .ringStop)
        XCTAssertEqual(ControlsRequest.parse(Data(#"{"t":"ringer","mode":"silent"}"#.utf8)), .ringer(.silent))
        XCTAssertEqual(ControlsRequest.parse(Data(#"{"t":"open"}"#.utf8)), .open)
    }

    func testBadRequestsAreRefused() {
        let bad = [
            #"{"t":"dnd"}"#,                      // no value
            #"{"t":"dnd","on":"yes"}"#,           // not a bool
            #"{"t":"ringer"}"#,                   // no mode
            #"{"t":"ringer","mode":"loud"}"#,     // not a wire mode
            #"{"t":"nope"}"#,                     // unknown kind
            #"not json"#,
            "[]",
        ]
        for line in bad {
            XCTAssertNil(ControlsRequest.parse(Data(line.utf8)), line)
        }
        XCTAssertNil(ControlsRequest.parse(Data(repeating: 0x20, count: 4097)))
    }

    func testRequestEncodingRoundTrips() throws {
        let requests: [ControlsRequest] = [.dnd(true), .dnd(false), .ring, .ringStop, .ringer(.vibrate), .open]
        for request in requests {
            let data = try XCTUnwrap(request.encoded())
            XCTAssertEqual(ControlsRequest.parse(data), request)
        }
    }

    func testRepliesEncodeTheStableErrorCodes() throws {
        let reply = ControlsReply.notConnected
        let decoded = try XCTUnwrap(reply.encoded().flatMap(ControlsReply.decode))
        XCTAssertEqual(decoded, reply)
        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.error, "not_connected")
        XCTAssertEqual(ControlsReply.noDnd.error, "no_dnd")
        XCTAssertEqual(ControlsReply.noRinger.error, "no_ringer")
        XCTAssertEqual(ControlsReply.dndOn.error, "dnd_on")
        XCTAssertEqual(ControlsReply.badRequest.error, "bad_request")
        XCTAssertTrue(ControlsReply.ok.ok)
    }

    // MARK: Ringer cycle

    func testRingerCyclesNormalVibrateSilent() {
        XCTAssertEqual(PhoneRingerMode.normal.next, .vibrate)
        XCTAssertEqual(PhoneRingerMode.vibrate.next, .silent)
        XCTAssertEqual(PhoneRingerMode.silent.next, .normal)
        XCTAssertEqual(PhoneRingerMode.allCases.map(\.rawValue), ["normal", "vibrate", "silent"])
    }
}
