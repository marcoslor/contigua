// The phone serves one session, so a connection the Mac stops using must be
// cancelled, not forgotten (audit A01), and Bonjour connections must avoid
// bridge and tunnel interfaces (A03).

import Network
import XCTest
@testable import PocketDeck

/// A TCP listener on loopback that records what its connections see.
private final class FakeServer {
    let listener: NWListener
    private let queue = DispatchQueue(label: "fakeserver")
    private(set) var accepted: [NWConnection] = []
    var onData: ((NWConnection, Data) -> Void)?
    var onClosed: ((NWConnection) -> Void)?
    private let ready = DispatchSemaphore(value: 0)

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.accepted.append(connection)
            connection.start(queue: self.queue)
            self.read(connection)
        }
        listener.stateUpdateHandler = { [ready] state in if case .ready = state { ready.signal() } }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    private func read(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.onData?(connection, data) }
            if complete || error != nil { self.onClosed?(connection); return }
            self.read(connection)
        }
    }

    func send(_ connection: NWConnection, _ bytes: [UInt8]) {
        connection.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    func stop() {
        listener.cancel()
        for connection in accepted { connection.cancel() }
    }
}

final class SessionLifecycleTests: XCTestCase {
    private func makeSession(port: UInt16) -> Session {
        let keys = PairKeyStore(defaults: UserDefaults(suiteName: "dev.pocketdeck.tests.session")!,
                                keychain: Keychain(service: "dev.pocketdeck.tests.session"))
        return Session(endpoint: .hostPort(host: "127.0.0.1", port: port), knownDeviceId: nil,
                       clientId: "test-client", keyStore: keys)
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
