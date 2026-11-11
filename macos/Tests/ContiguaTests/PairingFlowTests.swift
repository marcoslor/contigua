// The pairing sheet against a phone that shows its code and then waits for a
// person: nothing on the Mac may time out while the sheet is up, and Cancel
// must hang up so the phone can dismiss its prompt. v2 peer = TLS fake phone.

import AppKit
import XCTest
@testable import Contigua

@MainActor
final class PairingFlowTests: XCTestCase {
    private var server: FakeServer!
    private var brain: FakeV2PhoneBrain!
    private var controller: ConnectionController!
    private var profile: Profile!

    override func setUp() async throws {
        // The window set's menu pass reads NSApp; a filtered run of this class
        // is the first thing that creates a window, so create the app first.
        _ = NSApplication.shared
        profile = Profile(name: "unit-pairing-\(UUID().uuidString.prefix(8).lowercased())")!
        controller = ConnectionController(options: LaunchOptions.parse(["Contigua"]), profile: profile)
        // One attempt may take 0.4 s; the person gets 30 s.
        controller.connectTimeout = 0.4
        controller.pairingTimeout = 30
        server = try FakeServer(trustingClientPem: controller.identity.certPem)
        brain = FakeV2PhoneBrain(identity: server.phoneIdentity, deviceId: "phone-1")
        server.brain = brain
    }

    override func tearDown() async throws {
        controller.shutdown()
        server.stop()
        if let suite = profile.defaultsSuiteName { profile.defaults.removePersistentDomain(forName: suite) }
        try? FileManager.default.removeItem(at: profile.supportDirectoryUrl)
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        return condition()
    }

    private func spin(for seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private var comparing: Bool {
        guard let code = brain.lastCode else { return false }
        if case .pairing(_, .comparing(code: let shown)) = controller.link, shown == PairingCodeV2.codeHex(code) {
            return true
        }
        return false
    }

    /// The report: the Mac showed the sheet and, almost at once, "The phone stopped
    /// waiting". Here the code is up for four attempt-watchdogs; the sheet must hold.
    func testTheSheetStaysUpWhileAPersonCompares() throws {
        controller.connectManually(host: "127.0.0.1", port: server.port)
        XCTAssertTrue(spin { comparing }, "never reached the code: \(controller.link)")
        XCTAssertEqual(controller.sheet, .code)

        spin(for: 1.6)
        XCTAssertTrue(comparing, "link moved on while the person was deciding: \(controller.link)")
        XCTAssertEqual(controller.sheet, .code)

        brain.allow(server.accepted.first!)
        XCTAssertTrue(spin { controller.link.isOnline }, "not online after Allow: \(controller.link)")
        XCTAssertTrue(controller.pairingSucceeded)
    }

    func testCancelHangsUpOnThePhone() throws {
        let closed = expectation(description: "the phone sees EOF")
        closed.assertForOverFulfill = false
        server.onClosed = { _ in closed.fulfill() }
        controller.connectManually(host: "127.0.0.1", port: server.port)
        XCTAssertTrue(spin { comparing })
        controller.sheet = nil
        controller.sheetDismissed()
        wait(for: [closed], timeout: 5)
        XCTAssertEqual(controller.link, .idle)
    }

    func testPairAgainOnAnAbsentPhoneTargetsItInTheAddSheet() throws {
        // PAIR-33/34: a trust-lost phone that is not in range opens the one
        // add-phone sheet with that phone as its target.
        let absent = PhoneRef(id: "absent-1", name: "Pixel 8", model: "G9S9B")
        controller.remembered.remember(absent)
        XCTAssertTrue(controller.discovered.isEmpty)
        controller.pairAgain(for: controller.remembered.phone(id: "absent-1")!)
        XCTAssertEqual(controller.sheet, .addPhone)
        XCTAssertEqual(controller.addPhoneTarget?.id, "absent-1")
        controller.sheet = nil
        controller.sheetDismissed()
        XCTAssertNil(controller.addPhoneTarget, "the target ends with the sheet")
    }

    func testDeniedAndTimedOutReachTheSheet() throws {
        controller.connectManually(host: "127.0.0.1", port: server.port)
        XCTAssertTrue(spin { comparing })
        let connection = try XCTUnwrap(server.accepted.first)
        server.brain = nil
        server.onFrame = { _, _ in }
        connection.sendJSON(["t": "error", "code": "pair_timeout"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { connection.close() }
        XCTAssertTrue(spin {
            if case .pairing(_, .timedOut) = controller.link { return true }
            return false
        }, "\(controller.link)")
    }
}
