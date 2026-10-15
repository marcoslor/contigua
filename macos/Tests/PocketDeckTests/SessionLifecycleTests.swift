// The phone serves one session, so a connection the Mac stops using must be
// cancelled, not forgotten (audit A01), and pairing waits on the person, not
// on the network. v2: every test peer is a mutual-TLS 1.3 fake phone with its
// own identity (docs/design/e2ee.md §1/§4).

import CryptoKit
import Network
import XCTest
@testable import PocketDeck

final class SessionLifecycleTests: XCTestCase {
    private var macIdentity: (identity: DeviceIdentityV2, privateKey: P256.Signing.PrivateKey)!
    private var phoneIdentity: DeviceIdentityV2!
    private var brain: FakeV2PhoneBrain!
    private var server: FakeServer!

    override func setUp() {
        macIdentity = IdentityGeneratorV2.make(deviceId: "mac-\(UUID().uuidString.prefix(8))")
        phoneIdentity = IdentityGeneratorV2.make(deviceId: "phone-\(UUID().uuidString.prefix(8))", cn: "PocketDeck Phone").identity
        brain = nil
        server = nil
    }

    override func tearDown() {
        server?.stop()
    }

    private func makeSession(port: UInt16, connectTimeout: TimeInterval = Session.defaultConnectTimeout,
                             pairingTimeout: TimeInterval = Session.defaultPairingTimeout,
                             policy: Session.PairingPolicy = .allowed,
                             pinStore: PhonePinStoreV2? = nil,
                             pinnedPhone: PinnedPhoneV2? = nil) -> Session {
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: port), knownDeviceId: nil,
                              clientId: "test-client", identity: macIdentity.identity,
                              pinnedPhone: pinnedPhone, pinStore: pinStore,
                              connectTimeout: connectTimeout, pairingTimeout: pairingTimeout)
        session.pairingPolicy = policy
        return session
    }

    private func makeFake(autoAllow: Bool = false) throws {
        server = try FakeServer(phoneIdentity: phoneIdentity, trustingClientPem: macIdentity.identity.certPem)
        brain = FakeV2PhoneBrain(identity: phoneIdentity, deviceId: "phone-1")
        brain.autoAllow = autoAllow
        server.brain = brain
    }

    private func waitFor(_ condition: @escaping () -> Bool, _ message: @autoclosure () -> String = "condition never held",
                         timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return condition()
    }

    /// The report "The phone stopped waiting": a person reading two screens takes
    /// far longer than one connect attempt. The connect watchdog is 0.4 s, the
    /// code is on screen for 1.6 s (four watchdogs), then the person taps Allow.
    func testAPairingSessionOutlivesTheConnectWatchdogWhileAPersonDecides() throws {
        try makeFake()
        let session = makeSession(port: server.port, connectTimeout: 0.4, pairingTimeout: 30)
        var events: [SessionEvent] = []
        session.onEvent = { events.append($0) }
        session.start()
        XCTAssertTrue(waitFor { events.contains { if case .pairCodeShown = $0 { return true }; return false } },
                      "the pairing code never arrived: \(events)")
        // Both screens derive the same §4 code from the same inputs.
        let shownCode = events.compactMap { event -> String? in
            if case .pairCodeShown(_, let code) = event { return code }
            return nil
        }.first
        guard let code = brain.lastCode else { XCTFail("the phone never derived a code"); return }
        XCTAssertEqual(shownCode, PairingCodeV2.codeHex(code),
                       "the phone's code and the Mac's disagree")

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.6))
        XCTAssertNotEqual(session.state, .failed("pair_timeout"))
        for case .state(.failed(let why), _) in events {
            XCTFail("session failed while the person was deciding: \(why)")
        }

        brain.allow(server.accepted.first!)
        XCTAssertTrue(waitFor { session.state == .ready }, "allow never landed: \(session.state)")
        XCTAssertTrue(events.contains { if case .pairApproved = $0 { return true } else { return false } })
        session.close()
    }

    func testTheConnectWatchdogStillFailsAnAttemptThatNeverReachesTheCode() throws {        try makeFake()
        server.brain = nil
        server.onFrame = { _, _ in }
        let session = makeSession(port: server.port, connectTimeout: 0.4)
        session.start()
        XCTAssertTrue(waitFor { session.state == .failed("timeout") }, "state=\(session.state)")
        session.close()
    }

    func testNoDecisionByThePairingDeadlineFailsAsPairTimeout() throws {
        try makeFake()
        let session = makeSession(port: server.port, connectTimeout: 0.4, pairingTimeout: 1)
        session.start()
        XCTAssertTrue(waitFor { session.state == .failed("pair_timeout") }, "state=\(session.state)")
        session.close()
    }

    func testDenyFromThePhoneIsReportedAsPairDenied() throws {
        try makeFake()
        let session = makeSession(port: server.port)
        session.start()
        XCTAssertTrue(waitFor({ self.brain.lastCode != nil }, "no code derived", timeout: 5))
        // The person denied on the phone: the phone errors and hangs up.
        server.brain = nil
        server.onFrame = { _, _ in }
        let connection = try XCTUnwrap(server.accepted.first)
        connection.sendJSON(["t": "error", "code": "pair_denied"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { connection.close() }
        XCTAssertTrue(waitFor { session.state == .failed("pair_denied") }, "state=\(session.state)")
        session.close()
    }

    func testCancelClosesTheConnectionSoThePhoneCanDismissItsPrompt() throws {
        try makeFake()
        let session = makeSession(port: server.port)
        let closed = expectation(description: "EOF on the phone")
        closed.assertForOverFulfill = false
        server.onClosed = { _ in closed.fulfill() }
        session.start()
        XCTAssertTrue(waitFor({ self.brain.lastCode != nil }, "no code derived", timeout: 5))
        session.close()
        wait(for: [closed], timeout: 5)
    }

    /// A v1 phone answers hello with its challenge frame; v2 treats the peer as
    /// incompatible and never keeps talking (fixed decision: no v1 path).
    func testAV1PhoneIsTreatedAsAVersionMismatch() throws {
        try makeFake()
        server.brain = nil
        server.onFrame = { connection, _ in
            connection.sendJSON(["t": "challenge", "nonce": String(repeating: "a", count: 32), "id": "phone-1"])
        }
        let session = makeSession(port: server.port)
        session.start()
        XCTAssertTrue(waitFor { session.state == .failed("version") }, "state=\(session.state)")
        session.close()
    }

    /// The §4 state machine catches a committer that reveals different
    /// materials than it committed: the Mac refuses with `pair_commit`.
    func testABadCommitEndsThePairingAsPairCommit() throws {
        try makeFake()
        brain.badCommit = true
        let session = makeSession(port: server.port)
        session.start()
        XCTAssertTrue(waitFor { session.state == .failed("pair_commit") }, "state=\(session.state)")
        session.close()
    }

    func testAFailedSessionClosesItsSocket() throws {
        try makeFake()
        let session = makeSession(port: server.port, connectTimeout: 0.4)
        let closed = expectation(description: "EOF after failure")
        server.onClosed = { _ in closed.fulfill() }
        // The phone refuses with an error right away: the session fails, and
        // the abandoned socket must see EOF (it is never left dangling).
        server.brain = nil
        server.onFrame = { connection, _ in
            connection.sendJSON(["t": "error", "code": "protocol", "message": "x"])
        }
        session.start()
        XCTAssertTrue(waitFor { session.state == .failed("protocol") }, "state=\(session.state)")
        wait(for: [closed], timeout: 5)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
        // The session did not reconnect behind the owner's back.
        XCTAssertTrue(server.accepted.isEmpty, "a failed session reconnected: \(server.accepted.count) connections")
        session.close()
    }

    func testClosingASessionClosesItsSocket() throws {
        try makeFake()
        let session = makeSession(port: server.port)
        let closed = expectation(description: "EOF after close")
        server.onClosed = { _ in closed.fulfill() }
        session.start()
        XCTAssertTrue(waitFor { self.server.accepted.count == 1 }, "no connection landed")
        session.close()
        wait(for: [closed], timeout: 5)
    }

    /// Automatic reconnects never pair: with no pin record, the attempt fails
    /// up front and never reaches a pairing prompt on the phone.
    func testAnAutomaticSessionWithoutAPinNeverAsksForPairing() throws {
        try makeFake()
        let session = makeSession(port: server.port, policy: .never)
        session.start()
        XCTAssertTrue(waitFor { session.state == .failed("no-pin") }, "state=\(session.state)")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
        XCTAssertTrue(server.accepted.isEmpty, "the session contacted the phone anyway")
        XCTAssertNil(brain.lastCode)
        session.close()
    }

    /// Pairing established a pin; the automatic reconnect uses it (enforced
    /// TLS against the stored record) and welcome arrives without pairing.
    func testTheAutomaticReconnectUsesThePairingPin() throws {
        try makeFake(autoAllow: true)
        let pins = PhonePinStoreV2()
        let session = makeSession(port: server.port, connectTimeout: 0.6,
                                  policy: .allowed, pinStore: pins)
        session.start()
        XCTAssertTrue(waitFor { session.state == .ready }, "never paired: \(session.state)")
        let record = pins.record(for: "phone-1")
        XCTAssertNotNil(record, "the pin record never landed")
        XCTAssertEqual(record?.phoneFingerprintHex, server.phoneFingerprintHex)
        session.close()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))

        // The reconnect: fresh session, enforced record, no pair.request. The
        // identity mirrors the pin the pairing just set (what the controller
        // saves back into identity.json).
        var pinnedIdentity = macIdentity.identity
        pinnedIdentity.pin = record!.phoneFingerprintHex
        let reconnect = Session(endpoint: .hostPort(host: "127.0.0.1", port: server.port),
                                knownDeviceId: "phone-1", clientId: "test-client",
                                identity: pinnedIdentity,
                                pinnedPhone: record, pinStore: pins)
        reconnect.pairingPolicy = .never
        brain.welcomeOnHello = true
        var gotReady = false
        reconnect.onEvent = { if case .ready = $0 { gotReady = true } }
        reconnect.start()
        XCTAssertTrue(waitFor { gotReady }, "pinned reconnect never went ready: \(reconnect.state)")
        reconnect.close()
    }

    func testBonjourAttemptsCanBePinnedToTheInterfaceTheyWereFoundOn() throws {
        let service = NWEndpoint.service(name: "Pixel", type: "_pocketdeck._tcp", domain: "local", interface: nil)
        let monitor = NWPathMonitor()
        let found = expectation(description: "an interface")
        var interface: NWInterface?
        monitor.pathUpdateHandler = { path in
            if interface == nil, let first = path.availableInterfaces.first {
                interface = first
                found.fulfill()
            }
        }
        monitor.start(queue: DispatchQueue(label: "pathmonitor"))
        wait(for: [found], timeout: 5)
        monitor.cancel()
        let loopback = try XCTUnwrap(interface)
        XCTAssertEqual(Session.tcpParameters(for: .service(service, pinnedTo: loopback)).requiredInterface, loopback)
        XCTAssertNil(Session.tcpParameters(for: .service(service)).requiredInterface)
        XCTAssertNil(Session.tcpParameters(for: .hostPort(host: "127.0.0.1", port: 47000)).requiredInterface)
    }
}
