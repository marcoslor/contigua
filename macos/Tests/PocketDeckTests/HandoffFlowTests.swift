// "Move Phone App to Mac" (docs/ROADMAP.md #9): the command only does anything with
// a live connection, the phone's answer puts the window up (started fresh or
// moved), and `nothing_to_continue` removes the never-opened window and shows
// the notice. v2 peer = TLS fake phone with a scripted §4 pairing.

import AppKit
import XCTest
@testable import PocketDeck

@MainActor
final class HandoffFlowTests: XCTestCase {
    private var server: FakeServer!
    private var brain: FakeV2PhoneBrain!
    private var controller: ConnectionController!
    private var profile: Profile!
    private var received: [JSONMessage] = []

    override func setUp() async throws {
        // The window set's menu pass reads NSApp; a filtered run of this class
        // is the first thing that creates a window, so create the app first.
        _ = NSApplication.shared
        profile = Profile(name: "unit-handoff-\(UUID().uuidString.prefix(8).lowercased())")!
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

    /// connectManually -> the session pairs (the fake phone's Allow is on) ->
    /// `welcome` -> ready.
    private func goOnline() {
        received = []
        controller.connectManually(host: "127.0.0.1", port: server.port)
        XCTAssertTrue(spin { self.brain.sawPairRequest }, "never asked to pair: \(controller.link)")
        XCTAssertTrue(spin { controller.link.isOnline }, "not online: \(controller.link)")
        XCTAssertTrue(spin { received.contains { $0.t == "hello" } }, "hello never reached the phone")
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
        XCTAssertTrue(handoffStream == nil, "offline Move to Mac opened a window")

        goOnline()
        controller.continueOnMac()
        let stream = try XCTUnwrap(waitStream(), "no handoff window online")
        XCTAssertTrue(spin { received.contains { $0.t == "task.continue" } }, "task.continue never reached the phone")
        controller.windows.controller(for: stream)?.window?.performClose(nil)
        XCTAssertTrue(spin { handoffStream == nil })
        XCTAssertTrue(spin { received.contains { $0.t == "window.close" } }, "window.close never reached the phone")
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
        XCTAssertEqual(controller.frontApp.pkg, nil,
                       "the stale reply moved the row: \(controller.frontApp)")

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

    /// The phone has nothing continuable (its screen shows the home screen,
    /// SystemUI or its own PocketDeck): the never-opened window is removed and
    /// the short notice is what the person sees.
    func testNothingToContinueRemovesTheWindowAndShowsTheNotice() throws {
        goOnline()
        controller.continueOnMac()
        let stream = try XCTUnwrap(waitStream())
        phone(["t": "error", "code": "nothing_to_continue", "stream": Int(stream), "message": "x"])
        XCTAssertTrue(spin { handoffStream == nil }, "the refused window stayed open")
        XCTAssertEqual(controller.banner?.text,
                       "Nothing to move. Your phone is showing its home screen or PocketDeck.",
                       "no notice: \(String(describing: controller.banner))")
    }
}
