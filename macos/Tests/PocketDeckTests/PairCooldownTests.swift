// R2: the real phone's session-level errors carry `stream: 0`
// (Session.kt `sendError`), so the Mac must read a `pair_cooldown` as the
// phone's post-deny window, not let the close read as a TLS failure.

import XCTest
@testable import PocketDeck

@MainActor
final class PairCooldownTests: XCTestCase {
    private var server: FakeServer!
    private var brain: FakeV2PhoneBrain!
    private var controller: ConnectionController!
    private var profile: Profile!

    override func setUp() async throws {
        profile = Profile(name: "unit-cooldown-\(UUID().uuidString.prefix(8).lowercased())")!
        controller = ConnectionController(options: LaunchOptions.parse(["PocketDeck"]), profile: profile)
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

    /// The phone refuses `pair.request` with `pair_cooldown` on stream 0: the
    /// sheet says "Wait a moment, then try again." and counts the 30 s window;
    /// the session ends with the phone's code, never as a TLS failure.
    func testAStreamZeroCooldownReachesTheSheetAsTheCooldown() throws {
        brain.error = "pair_cooldown"
        controller.connectManually(host: "127.0.0.1", port: server.port)
        XCTAssertTrue(spin {
            if case .pairing(_, .coolingDown) = controller.link { return true }
            return false
        }, "the cooldown never reached the sheet: \(controller.link)")
        guard case .pairing(let phone, .coolingDown(let until)) = controller.link else {
            return XCTFail("not cooling down: \(controller.link)")
        }
        XCTAssertEqual(phone.name, "127.0.0.1")
        XCTAssertEqual(controller.sheet, .code)
        // 30 s from the refusal: the upper bound, because this Mac never saw
        // the deny that opened the phone's window.
        XCTAssertEqual(until.timeIntervalSinceNow, 30, accuracy: 3)
        XCTAssertFalse(Pairing.canTryAgain(until: until, at: Date()),
                       "Try again must wait for the window")
        XCTAssertEqual(Link.pairing(phone, .coolingDown(until: until)).banner?.text,
                       "Wait a moment, then try again.")
        XCTAssertEqual(Link.pairing(phone, .coolingDown(until: until)).banner?.countdownUntil, until)
    }

    /// A denial the Mac sees itself is `denied(until:)`, not the cooldown: the
    /// sheet's sentence is the denial's, and it counts from that moment.
    func testAStreamZeroDenialIsTheDenial() throws {
        brain.error = "pair_denied"
        controller.connectManually(host: "127.0.0.1", port: server.port)
        XCTAssertTrue(spin {
            if case .pairing(_, .denied) = controller.link { return true }
            return false
        }, "the denial never reached the sheet: \(controller.link)")
        guard case .pairing(let phone, .denied(let until)) = controller.link else {
            return XCTFail("not denied: \(controller.link)")
        }
        XCTAssertEqual(until.timeIntervalSinceNow, 30, accuracy: 3)
        XCTAssertEqual(Link.pairing(phone, .denied(until: until)).banner?.text,
                       "Pairing was denied on the phone.")
    }
}
