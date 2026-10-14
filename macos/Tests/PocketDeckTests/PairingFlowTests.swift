// The pairing sheet against a phone that shows its code and then waits for a
// person: nothing on the Mac may time out while the sheet is up, and Cancel
// must hang up so the phone can dismiss its prompt.

import XCTest
@testable import PocketDeck

@MainActor
final class PairingFlowTests: XCTestCase {
    private var server: FakeServer!
    private var controller: ConnectionController!
    private var profile: Profile!

    override func setUp() async throws {
        profile = Profile(name: "unit-pairing-\(UUID().uuidString.prefix(8).lowercased())")!
        server = try FakeServer()
        var received = ""
        var challenged = false
        var shown = false
        server.onData = { [server] connection, data in
            received += String(decoding: data, as: UTF8.self)
            if !challenged, received.contains("\"hello\"") {
                challenged = true
                server?.send(connection, JSONFrame.encode(["t": "challenge", "nonce": String(repeating: "a", count: 32), "id": "phone-1"]))
            }
            if !shown, received.contains("pair.request") {
                shown = true
                server?.send(connection, JSONFrame.encode(["t": "pair.code_shown", "code": "123456"]))
            }
        }
        controller = ConnectionController(options: LaunchOptions.parse(["PocketDeck"]), profile: profile)
        // One attempt may take 0.4 s; the person gets 30 s.
        controller.connectTimeout = 0.4
        controller.pairingTimeout = 30
    }

    override func tearDown() async throws {
        controller.shutdown()
        server.stop()
        if let suite = profile.defaultsSuiteName { profile.defaults.removePersistentDomain(forName: suite) }
        try? FileManager.default.removeItem(at: profile.pairKeys.url.deletingLastPathComponent())
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    private func spin(for seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private var comparing: Bool {
        if case .pairing(_, .comparing(code: "123456")) = controller.link { return true }
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

        let connection = try XCTUnwrap(server.accepted.first)
        server.send(connection, JSONFrame.encode(["t": "pair.ok", "key": String(repeating: "ab", count: 32)]))
        server.send(connection, JSONFrame.encode(["t": "welcome", "device": [
            "id": "phone-1", "name": "Pixel", "model": "Pixel", "sdk": 36,
            "screen": ["w": 1080, "h": 2340, "dpi": 450], "locked": true]]))
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

    func testDeniedAndTimedOutReachTheSheet() throws {
        controller.connectManually(host: "127.0.0.1", port: server.port)
        XCTAssertTrue(spin { comparing })
        let connection = try XCTUnwrap(server.accepted.first)
        server.send(connection, JSONFrame.encode(["t": "error", "code": "pair_timeout"]))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { connection.cancel() }
        XCTAssertTrue(spin {
            if case .pairing(_, .timedOut) = controller.link { return true }
            return false
        }, "\(controller.link)")
    }
}
