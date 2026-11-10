// WIN-38: `error no_stream` is never a launcher notice. What the person sees
// depends on the window: nothing when no window exists (the ordinary case — a
// late message for a stream the Mac closed), the opening cover's refusal while
// it is still opening, or the window closing the way a phone-side
// `window.closed` closes it (WIN-12). `launch_failed` keeps its notice.

import XCTest
@testable import PocketDeck

@MainActor
final class NoStreamTests: XCTestCase {
    private var server: FakeServer!
    private var brain: FakeV2PhoneBrain!
    private var controller: ConnectionController!
    private var profile: Profile!
    private var received: [JSONMessage] = []

    override func setUp() async throws {
        profile = Profile(name: "unit-nostream-\(UUID().uuidString.prefix(8).lowercased())")!
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
        try? FileManager.default.removeItem(at: profile.supportDirectoryUrl)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
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
    }

    private var banner: String? { controller.banner?.text }

    // ------------------------------------------------------------------

    /// No window for the stream (closed, or never opened): the answer is
    /// logged and nothing appears in the launcher.
    func testNoStreamWithNoWindowShowsNothing() {
        goOnline()
        phone(["t": "error", "code": "no_stream", "stream": 9])
        spin(0.3)
        XCTAssertNil(banner, "the launcher said \"\(banner ?? "")\"")
        XCTAssertTrue(controller.windows.openStreams.isEmpty)
    }

    /// The window still waits for its first frame: the cover says the open
    /// failed and offers Close alone, exactly as any other refusal (WIN-11).
    func testNoStreamWhileOpeningRefusesTheCover() throws {
        goOnline()
        let window = controller.windows.openOrRaise(pkg: "com.android.settings")
        XCTAssertTrue(window.isOpening, "the window should still be opening")
        phone(["t": "error", "code": "no_stream", "stream": Int(window.stream)])
        XCTAssertTrue(spin { window.opening.state == .failed(reason: nil) },
                      "cover state \(window.opening.state)")
        XCTAssertNil(banner, "the launcher said \"\(banner ?? "")\"")
        XCTAssertEqual(controller.windows.openStreams, [window.stream], "the refused cover stays")
    }

    /// A live window's stream is gone from the phone: the window closes the
    /// way the phone's own `window.closed` closes it, and no close is echoed
    /// back to a phone that has already forgotten the stream.
    func testNoStreamOnALiveWindowClosesItWithoutACloseBack() throws {
        goOnline()
        let window = controller.windows.openOrRaise(pkg: "com.android.settings")
        window.noteFirstFrame()
        XCTAssertFalse(window.isOpening)
        phone(["t": "error", "code": "no_stream", "stream": Int(window.stream)])
        XCTAssertTrue(spin { controller.windows.openStreams.isEmpty }, "the lost window stayed open")
        XCTAssertNil(banner, "the launcher said \"\(banner ?? "")\"")
        spin(0.2)
        XCTAssertFalse(received.contains { $0.t == "window.close" },
                       "a window.close went back to a phone that lost the stream")
    }
}
