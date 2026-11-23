// CTRL-17 (#213): the Control Center snapshot is written when one of its values
// changes, not on every one-second tick. The real refresh against a real
// controller and a temporary controls folder; no socket, no timer.

import XCTest
@testable import Contigua

@MainActor
final class ControlsHostTests: XCTestCase {
    private var controller: ConnectionController!
    private var profile: Profile!
    private var directory: URL!
    private let phone = PhoneRef(id: "aaa", name: "Pixel 9", model: "Pixel 9")

    override func setUp() async throws {
        profile = Profile(name: "unit-controls-\(UUID().uuidString.prefix(8).lowercased())")!
        controller = ConnectionController(options: LaunchOptions.parse(["Contigua"]), profile: profile)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("controls-host-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        controller.shutdown()
        if let suite = profile.defaultsSuiteName {
            profile.defaults.removePersistentDomain(forName: suite)
        }
        try? FileManager.default.removeItem(at: profile.supportDirectoryUrl)
        try? FileManager.default.removeItem(at: directory)
    }

    private func stamp() throws -> TimeInterval {
        let url = ControlsPaths.snapshotURL(in: directory)
        return try XCTUnwrap(ControlsSnapshot.read(from: url)).updated
    }

    /// CTRL-17: ticks with nothing changed write nothing; a changed value is
    /// written once and stamped; the ticks after it write nothing again.
    func testTheSnapshotIsWrittenOnlyWhenAValueChanges() throws {
        let host = try XCTUnwrap(ControlsHost(controller: controller, directory: directory))
        host.refresh(force: true)
        XCTAssertEqual(host.writes, 1, "launch writes the snapshot once")
        let launched = try stamp()
        host.refresh()
        host.refresh()
        XCTAssertEqual(host.writes, 1, "a tick with no changed value rewrote the snapshot")
        XCTAssertEqual(try stamp(), launched, "the stamp is the last real change")

        controller.machine = LinkMachine(link: .online(phone))
        host.refresh()
        XCTAssertEqual(host.writes, 2, "the phone coming online is written")
        XCTAssertTrue(try XCTUnwrap(ControlsSnapshot.read(from: ControlsPaths.snapshotURL(in: directory))).connected)
        host.refresh()
        host.refresh()
        XCTAssertEqual(host.writes, 2, "a tick after the change rewrote the snapshot")
    }

    /// CTRL-17: a forced refresh (launch: the file may be missing after a
    /// crash) writes even an identical snapshot.
    func testAForcedRefreshWritesAnIdenticalSnapshot() throws {
        let host = try XCTUnwrap(ControlsHost(controller: controller, directory: directory))
        host.refresh(force: true)
        host.refresh(force: true)
        XCTAssertEqual(host.writes, 2)
    }
}
