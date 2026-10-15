// "Continue on Mac" (docs/ROADMAP.md #9): the command only does anything with
// a live connection, the phone's answer puts the window up (started fresh or
// moved), and `nothing_to_continue` removes the never-opened window and shows
// the notice.

import Network
import XCTest
@testable import PocketDeck

@MainActor
final class HandoffFlowTests: XCTestCase {
    private var server: FakeServer!
    private var controller: ConnectionController!
    private var profile: Profile!
    private var received = ""

    override func setUp() async throws {
        profile = Profile(name: "unit-handoff-\(UUID().uuidString.prefix(8).lowercased())")!
        server = try FakeServer()
        var challenged = false
        server.onData = { [server, weak self] connection, data in
            self?.received = (self?.received ?? "") + String(decoding: data, as: UTF8.self)
            guard let self, !challenged, self.received.contains("\"hello\"") else { return }
            challenged = true
            server?.send(connection, JSONFrame.encode(["t": "challenge",
                                                       "nonce": String(repeating: "a", count: 32),
                                                       "id": "phone-1"]))
        }
        controller = ConnectionController(options: LaunchOptions.parse(["PocketDeck"]), profile: profile)
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

    private func phone(_ json: [String: Any]) {
        guard let connection = try? XCTUnwrap(server.accepted.first) else { return }
        server.send(connection, JSONFrame.encode(json))
    }

    /// connectManually -> the session pairs (the app is a debug build on the
    /// real phone, so Allow is automatic) -> `welcome` -> ready.
    private func goOnline() {
        received = ""
        controller.connectManually(host: "127.0.0.1", port: server.port)
        XCTAssertTrue(spin { received.contains("pair.request") }, "never asked to pair: \(controller.link)")
        phone(["t": "pair.ok", "key": String(repeating: "ab", count: 32)])
        phone(["t": "welcome", "device": [
            "id": "phone-1", "name": "Pixel", "model": "Pixel", "sdk": 36,
            "screen": ["w": 1080, "h": 2340, "dpi": 450], "locked": true]])
        XCTAssertTrue(spin { controller.link.isOnline }, "not online: \(controller.link)")
    }

    private var handoffStream: UInt32? {
        controller.windows.openStreams.first
    }

    private func waitStream() -> UInt32? {
        var stream: UInt32?
        spin(until: {
            stream = handoffStream
            return stream != nil
        })
        return stream
    }

    // ------------------------------------------------------------------

    /// The command enables/disables with the connection (both menu items read
    /// `link.isOnline`): offline it opens nothing, online it talks to the phone,
    /// and the window closes like any app window.
    func testTheCommandDoesNothingOfflineAndTalksToThePhoneOnline() throws {
        controller.continueOnMac()
        XCTAssertTrue(handoffStream == nil, "offline Continue opened a window")

        goOnline()
        controller.continueOnMac()
        let stream = try XCTUnwrap(waitStream(), "no handoff window online")
        XCTAssertTrue(spin { received.contains("task.continue") }, "task.continue never reached the phone")
        controller.windows.controller(for: stream)?.window?.performClose(nil)
        XCTAssertTrue(spin { handoffStream == nil })
        XCTAssertTrue(spin { received.contains("window.close") }, "window.close never reached the phone")
    }

    /// `started: "fresh"`: the phone relaunched the package (the move was
    /// refused); the window adopts the app the phone reports (`window.title`).
    func testAFreshStartGetsTheTitleFromThePhone() throws {
        goOnline()
        controller.continueOnMac()
        let stream = try XCTUnwrap(waitStream())
        phone(["t": "window.opened", "stream": Int(stream), "displayId": 41,
               "w": 1792, "h": 1200, "started": "fresh"])
        phone(["t": "window.title", "stream": Int(stream), "label": "Settings", "pkg": "com.android.settings"])
        XCTAssertTrue(spin {
            (controller.windows.controller(for: stream) as? HandoffWindowController)?.pkg == "com.android.settings"
        }, "the handoff window never adopted the package")
        XCTAssertEqual((controller.windows.controller(for: stream) as? HandoffWindowController)?.subject, "Settings")
    }

    /// The phone has nothing continuable (its screen shows the home screen,
    /// SystemUI or its own PocketDeck): the never-opened window is removed and
    /// the short notice is what the person sees.
    func testNothingToContinueRemovesTheWindowAndShowsTheNotice() throws {
        goOnline()
        controller.continueOnMac()
        let stream = try XCTUnwrap(waitStream())
        phone(["t": "error", "code": "nothing_to_continue", "stream": Int(stream), "message": "x"])
        XCTAssertTrue(spin { handoffStream == nil }, "the refused window stayed open")
        XCTAssertEqual(controller.banner?.text, "Nothing to continue.",
                       "no notice: \(String(describing: controller.banner))")
    }
}
