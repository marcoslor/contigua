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

    /// Arms [server] to answer with a protocol error and to fulfil [closed] for
    /// **this session's own connection only**: `onClosed` fires for every channel
    /// the fake accepted, and a stray connect that lands on a recycled port (a
    /// dial from anywhere else) must never over-fulfil the expectation — XCTest
    /// aborts the whole run on that (signal 6, 2 of 2 full runs on 10-29).
    private func armFailedSession(_ server: FakeServer, closed: XCTestExpectation) {
        // The own connection is the one that speaks: a stray fails TLS and never
        // sends a frame. `onFrame` runs before any close of that channel.
        let own = SessionLockedBox<Int?>(value: nil)
        server.brain = nil
        server.onFrame = { connection, _ in
            if own.get() == nil { own.set(connection.id) }
            connection.sendJSON(["t": "error", "code": "protocol", "message": "x"])
        }
        server.onClosed = { connection in
            guard connection.id == own.get() else { return }
            closed.fulfill()
        }
    }

    func testAFailedSessionClosesItsSocket() throws {
        try makeFake()
        let session = makeSession(port: server.port, connectTimeout: 0.4)
        let closed = expectation(description: "EOF after failure")
        // The phone refuses with an error right away: the session fails, and
        // the abandoned socket must see EOF (it is never left dangling). Only
        // that socket counts: a stray on this port stays silent, not fatal.
        armFailedSession(server, closed: closed)
        session.start()
        XCTAssertTrue(waitFor { session.state == .failed("protocol") }, "state=\(session.state)")
        wait(for: [closed], timeout: 5)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
        // The session did not reconnect behind the owner's back.
        XCTAssertTrue(server.accepted.isEmpty, "a failed session reconnected: \(server.accepted.count) connections")
        session.close()
    }

    /// A stray TCP connection that reaches this test's port — a dial to a
    /// recycled ephemeral port from anywhere else — must not abort the whole
    /// run: `onClosed` fires for it, and an over-fulfilled expectation kills
    /// xctest (signal 6, seen 2 of 2 full runs on 10-29). This reproduces it
    /// with a connect the test makes itself.
    func testAStrayConnectionCannotAbortTheRun() throws {
        try makeFake()
        let session = makeSession(port: server.port, connectTimeout: 0.4)
        let closed = expectation(description: "EOF after failure")
        armFailedSession(server, closed: closed)
        // The stray arrives first and fails its TLS handshake, so it is the first
        // channel to close: it must be ignored, and the session's own EOF is the
        // only thing that fulfils.
        let stray = NWConnection(host: "127.0.0.1",
                                 port: NWEndpoint.Port(rawValue: server.port)!, using: .tcp)
        stray.stateUpdateHandler = { state in
            if case .ready = state {
                stray.send(content: Data([0x00]), completion: .contentProcessed { _ in })
            }
        }
        stray.start(queue: .global())
        XCTAssertTrue(waitFor { self.server.accepted.contains { $0.id == 0 } }, "the stray never landed")
        stray.cancel()

        session.start()
        XCTAssertTrue(waitFor { session.state == .failed("protocol") }, "state=\(session.state)")
        wait(for: [closed], timeout: 5)
        // The session did not reconnect: its own channel is the only one left and
        // it is gone; nothing is served on the slot.
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

    /// Arch H4: every UI close runs on the main actor. `close()` must flip the
    /// state synchronously (the window renders from it) and hand the blocking
    /// teardown — channel close and graceful shutdown — to the session queue,
    /// so a wedged TLS channel cannot freeze the app.
    func testCloseMarksClosedSynchronouslyAndDrainsOffTheCaller() throws {
        try makeFake(autoAllow: true)
        let session = makeSession(port: server.port)
        let closed = expectation(description: "EOF after close")
        closed.assertForOverFulfill = false
        server.onClosed = { _ in closed.fulfill() }
        session.start()
        XCTAssertTrue(waitFor { session.state == .ready }, "never became ready: \(session.state)")
        let started = Date()
        session.close()
        XCTAssertEqual(session.state, .closed)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "close() blocked the caller")
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
        brain.scannedSecret = nil
        brain.welcomeOnHello = true
        var gotReady = false
        reconnect.onEvent = { if case .ready = $0 { gotReady = true } }
        reconnect.start()
        XCTAssertTrue(waitFor { gotReady }, "pinned reconnect never went ready: \(reconnect.state)")
        reconnect.close()
    }

    /// R2: the Mac's QR probe carries a one-time secret; a phone that scanned
    /// proves it with pair.qr, and the probe session pairs + pins it.
    func testQRProbePinsThePhoneThroughThePairQrProof() throws {
        try makeFake()
        let secret = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        brain.scannedSecret = secret
        brain.scannedMacFpHex = PairingQRPayload.selfFingerprintHex(identity: macIdentity.identity)
        brain.autoAllow = true
        let pins = PhonePinStoreV2()
        let probe = makeSession(port: server.port, policy: .probe, pinStore: pins)
        probe.useQRSecret(secret)
        var qrSigned = false
        var pinnedAtSignal = false
        probe.onEvent = {
            if case .qrPaired = $0 {
                qrSigned = true
                // The controller closes the probe on this event: the pin must be stored by then.
                pinnedAtSignal = pins.record(for: "phone-1") != nil
            }
        }
        probe.start()
        XCTAssertTrue(waitFor { probe.state == .ready }, "QR probe never paired: \(probe.state)")
        XCTAssertTrue(qrSigned, "the QR handshake never reached the controller")
        XCTAssertTrue(pinnedAtSignal, "qrPaired fired before the pin was stored")
        XCTAssertEqual(pins.record(for: "phone-1")?.phoneFingerprintHex, server.phoneFingerprintHex)
        probe.close()
    }

    /// A wrong HMAC (the probe's secret is not what the phone scanned) is
    /// refused; no pin is stored.
    func testAWrongQRSecretIsRefused() throws {
        try makeFake()
        let realSecret = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        brain.scannedSecret = realSecret
        brain.scannedMacFpHex = PairingQRPayload.selfFingerprintHex(identity: macIdentity.identity)
        let pins = PhonePinStoreV2()
        let probe = makeSession(port: server.port, policy: .probe, pinStore: pins)
        probe.useQRSecret(Data(repeating: 0x77, count: 16)) // the attacker's guess
        probe.start()
        XCTAssertTrue(waitFor { probe.state == .failed("pair_qr") }, "state=\(probe.state)")
        XCTAssertNil(pins.record(for: "phone-1"))
        probe.close()
    }

    /// Without a scanned QR the probe sits silent and the connect watchdog
    /// ends it (the sheet's probes must not junk up the phone with prompts).
    func testAProbeWithoutAScanNeverPairs() throws {
        try makeFake()
        let probe = makeSession(port: server.port, connectTimeout: 0.4, policy: .probe)
        probe.start()
        XCTAssertTrue(waitFor { probe.state == .failed("timeout") }, "state=\(probe.state)")
        XCTAssertNil(brain.lastCode)
        probe.close()
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

    func testExporterPrefixIsLoggedByDevAndE2EBundlesButNotRelease() {
        XCTAssertTrue(Session.logsExporterHash(variant: "dev"))
        XCTAssertTrue(Session.logsExporterHash(variant: "e2e"))
        XCTAssertTrue(Session.logsExporterHash(variant: nil), "a bare swift-build binary is a dev build")
        XCTAssertFalse(Session.logsExporterHash(variant: "release"))
    }
}
