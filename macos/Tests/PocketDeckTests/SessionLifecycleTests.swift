// The phone serves one session, so a connection the Mac stops using must be
// cancelled, not forgotten (audit A01), and Bonjour connections must avoid
// bridge and tunnel interfaces (A03).

import Network
import XCTest
@testable import PocketDeck

final class SessionLifecycleTests: XCTestCase {
    private func makeSession(port: UInt16, connectTimeout: TimeInterval = Session.defaultConnectTimeout,
                             pairingTimeout: TimeInterval = Session.defaultPairingTimeout) -> Session {
        // A pairing stores its key: every session gets its own store so one test's key
        // never makes another authenticate instead of pair.
        let name = "dev.pocketdeck.tests.session.\(UUID().uuidString)"
        let keys = PairKeyStore(defaults: UserDefaults(suiteName: name)!, keychain: Keychain(service: name))
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: name)
            while Keychain(service: name).accounts().first.map({ Keychain(service: name).delete(account: $0); return true }) == true {}
        }
        return Session(endpoint: .hostPort(host: "127.0.0.1", port: port), knownDeviceId: nil,
                       clientId: "test-client", keyStore: keys,
                       connectTimeout: connectTimeout, pairingTimeout: pairingTimeout)
    }

    /// A phone that answers hello with a challenge and pair.request with `codeShown`,
    /// then says nothing until the test speaks for it.
    private func pairingPhone(_ server: FakeServer, codeShown: [String: Any] = ["t": "pair.code_shown", "code": "123456"]) {
        var received = ""
        var challenged = false
        var shown = false
        server.onData = { connection, data in
            received += String(decoding: data, as: UTF8.self)
            if !challenged, received.contains("\"hello\"") {
                challenged = true
                server.send(connection, JSONFrame.encode(["t": "challenge", "nonce": String(repeating: "a", count: 32), "id": "phone-1"]))
            }
            if !shown, received.contains("pair.request") {
                shown = true
                server.send(connection, JSONFrame.encode(codeShown))
            }
        }
    }

    private func welcomeFrame() -> [UInt8] {
        JSONFrame.encode(["t": "welcome", "device": ["id": "phone-1", "name": "Pixel", "model": "Pixel", "sdk": 36,
                                                      "screen": ["w": 1080, "h": 2340, "dpi": 450], "locked": true]])
    }

    /// The report "The phone stopped waiting": a person reading two screens takes far
    /// longer than one connect attempt may. The connect watchdog is 0.4 s here, the
    /// code is on screen for 1.6 s (four watchdogs), then the person taps Allow.
    func testAPairingSessionOutlivesTheConnectWatchdogWhileAPersonDecides() throws {
        let server = try FakeServer()
        defer { server.stop() }
        pairingPhone(server)
        let session = makeSession(port: server.port, connectTimeout: 0.4, pairingTimeout: 30)
        var events: [SessionEvent] = []
        let shown = expectation(description: "code shown")
        shown.assertForOverFulfill = false
        let ready = expectation(description: "paired")
        ready.assertForOverFulfill = false
        session.onEvent = { event in
            events.append(event)
            if case .pairCodeShown(_, let code) = event { XCTAssertEqual(code, "123456"); shown.fulfill() }
            if case .ready = event { ready.fulfill() }
        }
        session.start()
        wait(for: [shown], timeout: 5)

        let quiet = expectation(description: "still waiting after four watchdogs")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { quiet.fulfill() }
        wait(for: [quiet], timeout: 5)
        XCTAssertNotEqual(session.state, .failed("timeout"))
        for case .state(.failed(let why), _) in events { XCTFail("session failed while waiting: \(why)") }

        let connection = try XCTUnwrap(server.accepted.first)
        server.send(connection, JSONFrame.encode(["t": "pair.ok", "key": String(repeating: "ab", count: 32)]))
        server.send(connection, welcomeFrame())
        wait(for: [ready], timeout: 5)
        XCTAssertTrue(events.contains { if case .pairApproved = $0 { return true } else { return false } })
        session.close()
    }

    func testTheConnectWatchdogStillFailsAnAttemptThatNeverReachesTheCode() throws {
        let server = try FakeServer()
        defer { server.stop() }
        server.onData = { _, _ in }
        let session = makeSession(port: server.port, connectTimeout: 0.4)
        let failed = expectation(description: "timeout")
        failed.assertForOverFulfill = false
        session.onEvent = { event in
            if case .state(.failed("timeout"), _) = event { failed.fulfill() }
        }
        session.start()
        wait(for: [failed], timeout: 5)
        session.close()
    }

    func testNoDecisionByThePairingDeadlineFailsAsPairTimeout() throws {
        let server = try FakeServer()
        defer { server.stop() }
        pairingPhone(server)
        let session = makeSession(port: server.port, connectTimeout: 0.4, pairingTimeout: 1)
        let failed = expectation(description: "pair_timeout")
        failed.assertForOverFulfill = false
        session.onEvent = { event in
            if case .state(.failed("pair_timeout"), _) = event { failed.fulfill() }
        }
        session.start()
        wait(for: [failed], timeout: 5)
        session.close()
    }

    func testDenyFromThePhoneIsReportedAsPairDenied() throws {
        let server = try FakeServer()
        defer { server.stop() }
        pairingPhone(server)
        let session = makeSession(port: server.port)
        let shown = expectation(description: "code shown")
        shown.assertForOverFulfill = false
        let failed = expectation(description: "denied")
        failed.assertForOverFulfill = false
        session.onEvent = { event in
            if case .pairCodeShown = event { shown.fulfill() }
            if case .state(.failed("pair_denied"), _) = event { failed.fulfill() }
        }
        session.start()
        wait(for: [shown], timeout: 5)
        let connection = try XCTUnwrap(server.accepted.first)
        server.send(connection, JSONFrame.encode(["t": "error", "code": "pair_denied"]))
        // The phone closes right after its error frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { connection.cancel() }
        wait(for: [failed], timeout: 5)
        session.close()
    }

    func testCancelClosesTheConnectionSoThePhoneCanDismissItsPrompt() throws {
        let server = try FakeServer()
        defer { server.stop() }
        pairingPhone(server)
        let session = makeSession(port: server.port)
        let shown = expectation(description: "code shown")
        shown.assertForOverFulfill = false
        let closed = expectation(description: "EOF on the phone")
        closed.assertForOverFulfill = false
        server.onClosed = { _ in closed.fulfill() }
        session.onEvent = { event in if case .pairCodeShown = event { shown.fulfill() } }
        session.start()
        wait(for: [shown], timeout: 5)
        session.close()
        wait(for: [closed], timeout: 5)
    }

    func testACodeShownWithoutACodeMeansAnOlderPhone() throws {
        let server = try FakeServer()
        defer { server.stop() }
        pairingPhone(server, codeShown: ["t": "pair.code_shown"])
        let session = makeSession(port: server.port)
        let failed = expectation(description: "version")
        failed.assertForOverFulfill = false
        session.onEvent = { event in
            if case .state(.failed("version"), _) = event { failed.fulfill() }
        }
        session.start()
        wait(for: [failed], timeout: 5)
        session.close()
    }

    func testAFailedSessionClosesItsSocket() throws {
        let server = try FakeServer()
        defer { server.stop() }
        let hello = expectation(description: "hello received")
        hello.assertForOverFulfill = false
        let closed = expectation(description: "the abandoned connection sees EOF")
        server.onData = { connection, _ in
            hello.fulfill()
            // Garbage where a frame length belongs: the Mac fails the session.
            server.send(connection, [0xFF, 0xFF, 0xFF, 0xFF])
        }
        server.onClosed = { _ in closed.fulfill() }

        let session = makeSession(port: server.port)
        let failed = expectation(description: "session failed")
        failed.assertForOverFulfill = false
        session.onEvent = { event in
            if case .state(.failed, _) = event { failed.fulfill() }
        }
        session.start()
        wait(for: [hello, failed, closed], timeout: 5)
        XCTAssertEqual(server.accepted.count, 1)
        // The session did not reconnect behind the owner's back.
        let quiet = expectation(description: "no second connection")
        quiet.isInverted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if server.accepted.count > 1 { quiet.fulfill() } }
        wait(for: [quiet], timeout: 3)
        session.close()
    }

    func testClosingASessionClosesItsSocket() throws {
        let server = try FakeServer()
        defer { server.stop() }
        let hello = expectation(description: "hello")
        hello.assertForOverFulfill = false
        let closed = expectation(description: "EOF after close")
        server.onData = { _, _ in hello.fulfill() }
        server.onClosed = { _ in closed.fulfill() }
        let session = makeSession(port: server.port)
        session.start()
        wait(for: [hello], timeout: 5)
        session.close()
        wait(for: [closed], timeout: 5)
    }

    func testAnAutomaticSessionWithoutAKeyNeverAsksForPairing() throws {
        let server = try FakeServer()
        defer { server.stop() }
        var received = Data()
        let challenge = JSONFrame.encode(["t": "challenge", "nonce": String(repeating: "a", count: 32), "id": "phone-1"])
        server.onData = { connection, data in
            received.append(data)
            if received.count == data.count { server.send(connection, challenge) }
        }
        let session = makeSession(port: server.port)
        session.pairingPolicy = .never
        let failed = expectation(description: "failed without a key")
        failed.assertForOverFulfill = false
        var reason: String?
        session.onEvent = { event in
            if case .state(.failed(let why), _) = event { reason = why; failed.fulfill() }
        }
        session.start()
        wait(for: [failed], timeout: 5)
        XCTAssertEqual(reason, "auth_failed")
        XCTAssertFalse(String(decoding: received, as: UTF8.self).contains("pair.request"))
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
