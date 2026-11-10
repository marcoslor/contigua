// The foreground read's flow (docs/PROTOCOL.md "Foreground app", PANEL-26):
// nothing while the card is closed, one `task.front` when it opens, the reply
// names the app, a stale reply is ignored, and closing stops the requests.

import AppKit
import XCTest
@testable import PocketDeck

@MainActor
final class FrontAppFlowTests: XCTestCase {
    private var server: FakeServer!
    private var brain: FakeV2PhoneBrain!
    private var controller: ConnectionController!
    private var profile: Profile!
    private var received: [JSONMessage] = []

    override func setUp() async throws {
        _ = NSApplication.shared
        profile = Profile(name: "unit-front-\(UUID().uuidString.prefix(8).lowercased())")!
        controller = ConnectionController(options: LaunchOptions.parse(["PocketDeck"]), profile: profile)
        controller.connectTimeout = 0.4
        controller.pairingTimeout = 30
        server = try FakeServer(trustingClientPem: controller.identity.certPem)
        brain = FakeV2PhoneBrain(identity: server.phoneIdentity, deviceId: "phone-1")
        brain.autoAllow = true
        server.brain = brain
        server.onFrame = { [weak self] _, frame in
            guard frame.messageType == .json,
                  let message = JSONFrame.decode(payload: frame.payload) else { return }
            self?.received.append(message)
        }
    }

    override func tearDown() async throws {
        controller.shutdown()
        server.stop()
        if let suite = profile.defaultsSuiteName { profile.defaults.removePersistentDomain(forName: suite) }
        try? FileManager.default.removeItem(at: profile.pairKeysFileUrl.deletingLastPathComponent())
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        return condition()
    }

    private func phone(_ json: [String: Any]) {
        guard let connection = try? XCTUnwrap(server.accepted.first) else { return }
        connection.sendJSON(json)
    }

    private func goOnline() {
        received = []
        controller.connectManually(host: "127.0.0.1", port: server.port)
        XCTAssertTrue(spin { self.brain.sawPairRequest }, "never asked to pair: \(controller.link)")
        XCTAssertTrue(spin { controller.link.isOnline }, "not online: \(controller.link)")
        XCTAssertTrue(spin { received.contains { $0.t == "hello" } }, "hello never reached the phone")
    }

    /// PANEL-26: the panel's foreground read is a pull: nothing is
    /// asked while the card is closed, one request goes out when it opens, the
    /// reply names the app, an older reply cannot overwrite the newer one, and
    /// closing the card stops the requests.
    func testTheForegroundReadRunsOnlyWhileTheCardIsOpen() throws {
        goOnline()
        // Closed: no request.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
        XCTAssertFalse(received.contains { $0.t == "task.front" },
                       "task.front was asked with no card open")

        controller.beginPanelFrontWatch()
        XCTAssertTrue(spin { self.received.contains { $0.t == "task.front" } },
                      "the open card never asked task.front")
        let first = try XCTUnwrap(received.last { $0.t == "task.front" })
        let firstSeq = try XCTUnwrap(first.int("seq"))
        phone(["t": "task.front", "seq": firstSeq, "pkg": "com.example.maps"])
        XCTAssertTrue(spin { controller.frontAppRow?.pkg == "com.example.maps" },
                      "the row did not follow the reply: \(controller.frontApp)")
        XCTAssertEqual(controller.frontAppRow?.title, "Open Current App on Mac",
                       "the unknown package must keep the fallback words")
        XCTAssertTrue(controller.frontMenuEnabled)

        // The two-second timer asks again; a reply to the first request is
        // stale and must not replace the newer answer.
        XCTAssertTrue(spin(until: {
            self.received.filter { $0.t == "task.front" }.count >= 2
        }, timeout: 3), "the open card stopped asking")
        let second = try XCTUnwrap(received.last { $0.t == "task.front" })
        let secondSeq = try XCTUnwrap(second.int("seq"))
        XCTAssertNotEqual(firstSeq, secondSeq)
        phone(["t": "task.front", "seq": firstSeq, "pkg": "com.example.stale"])
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
        XCTAssertEqual(controller.frontApp.pkg, "com.example.maps",
                       "the stale reply moved the row, or the row blinked out while asking: \(controller.frontApp)")

        phone(["t": "task.front", "seq": secondSeq, "pkg": nil])
        XCTAssertTrue(spin { controller.frontAppNone }, "pkg null did not become None")
        XCTAssertNil(controller.frontAppRow, "None must hide the row")
        XCTAssertFalse(controller.frontMenuEnabled,
                       "a fresh None disables the Phone menu's handoff item")

        controller.endPanelFrontWatch()
        let asked = received.filter { $0.t == "task.front" }.count
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 2.5))
        XCTAssertEqual(received.filter { $0.t == "task.front" }.count, asked,
                       "the closed card kept asking for the foreground")
    }

    /// The phone cannot read its task list (`not_available`): no row, and the
    /// Phone menu keeps its old one-shot fallback rather than claiming None.
    func testAForegroundReadOnAPhoneWithoutTaskAccessShowsNoRow() throws {
        goOnline()
        controller.beginPanelFrontWatch()
        defer { controller.endPanelFrontWatch() }
        XCTAssertTrue(spin { self.received.contains { $0.t == "task.front" } })
        let request = try XCTUnwrap(received.last { $0.t == "task.front" })
        let seq = try XCTUnwrap(request.int("seq"))
        phone(["t": "error", "code": "not_available", "stream": 0, "message": "x"])
        XCTAssertTrue(spin { controller.frontAppRepliedAt != nil })
        XCTAssertEqual(controller.frontApp.state, .idle)
        XCTAssertNil(controller.frontAppRow)
        XCTAssertTrue(controller.frontMenuEnabled,
                      "an old phone's menu item keeps the fallback behaviour")
        XCTAssertNotEqual(controller.frontApp.state, .asking(seq: seq))
    }
}
