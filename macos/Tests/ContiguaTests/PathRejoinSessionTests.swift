// The orphan's rejoin dials (docs/design/paths.md §6, E-11c): while a session
// is in its 30 s grace a failed rejoin is followed by the next dial at once,
// and each rejoin gives up after 2.0 s (the probe's own timeout, not the
// session's general one), so a phone that comes back inside the grace meets a
// dial within about a second. Outside the grace the reconnect backoff is
// unchanged (§7.4).

import CryptoKit
import XCTest
@testable import Contigua

final class PathRejoinSessionTests: XCTestCase {
    private var macIdentity: (identity: DeviceIdentityV2, privateKey: P256.Signing.PrivateKey)!
    private var phoneIdentity: DeviceIdentityV2!
    private var server: FakeServer!

    override func setUp() {
        macIdentity = IdentityGeneratorV2.make(deviceId: "mac-\(UUID().uuidString.prefix(8))")
        phoneIdentity = IdentityGeneratorV2.make(deviceId: "phone-\(UUID().uuidString.prefix(8))",
                                                 cn: "Contigua Phone").identity
        server = nil
    }

    override func tearDown() {
        server?.stop()
    }

    private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return condition()
    }

    private static func welcomeJSON(session: String) -> [String: Any] {
        ["t": "welcome", "session": session,
         "device": ["id": "phone-1", "name": "Pixel", "model": "Pixel", "sdk": 36,
                    "screen": ["w": 1080, "h": 2340, "dpi": 450], "locked": true]]
    }

    /// Runs a one-path session to `ready`, records the uptime of every join
    /// hello, and hands each join connection to `onJoin` (close it = a fast
    /// failure, say nothing = the dial's own timeout). `joinTimes` reads the
    /// recorded dials.
    private func startAndOrphan(onJoin: @escaping (FakeServer.Connection) -> Void)
        throws -> (Session, () -> [TimeInterval]) {
        server = try FakeServer(phoneIdentity: phoneIdentity, trustingClientPem: macIdentity.identity.certPem)
        let lock = NSLock()
        var joinHellos: [TimeInterval] = []
        var founder: FakeServer.Connection?
        server.onFrame = { connection, frame in
            guard frame.type == MessageType.json.rawValue,
                  let message = JSONFrame.decode(payload: frame.payload),
                  message.t == "hello" else { return }
            if message.string("join") != nil {
                lock.lock(); joinHellos.append(ProcessInfo.processInfo.systemUptime); lock.unlock()
                onJoin(connection)
                return
            }
            let session = PathIds.sessionId()
            lock.lock(); founder = connection; lock.unlock()
            connection.sendJSON(Self.welcomeJSON(session: session))
        }
        let record = PinnedPhoneV2(deviceId: "phone-1",
                                   phoneFingerprintHex: server.phoneFingerprintHex,
                                   certPem: phoneIdentity.certPem)
        let endpoint = Session.Endpoint.hostPort(host: "127.0.0.1", port: server.port)
        let session = Session(endpoint: endpoint, knownDeviceId: "phone-1",
                              clientId: "test-client", identity: macIdentity.identity,
                              pinnedPhone: record, connectTimeout: 6)
        session.pairingPolicy = .never
        session.start()
        XCTAssertTrue(waitFor { session.state == .ready }, "never ready: \(session.state)")
        lock.lock(); let founderConnection = founder; lock.unlock()
        founderConnection?.close()
        let times: () -> [TimeInterval] = {
            lock.lock(); defer { lock.unlock() }
            return joinHellos
        }
        return (session, times)
    }

    /// E-11c: while orphaned a refused rejoin is dialed again a second after
    /// its round began, every time: the reconnect backoff no longer grows
    /// (1, 2, 4, 8 s), and a phone whose server is down is not dialed on
    /// every 0.25 s tick either.
    func testARefusedRejoinIsRedialedASecondLaterEveryTime() throws {
        let (session, joinTimes) = try startAndOrphan { connection in
            connection.close()
        }
        defer { session.closeAndWait() }
        XCTAssertTrue(waitFor(timeout: 8) { joinTimes().count >= 4 },
                      "the refused rejoin was not redialed every second")
        let times = joinTimes()
        guard times.count >= 4 else {
            return XCTFail("only \(times.count) rejoin dials")
        }
        for i in 1..<4 {
            let gap = times[i] - times[i - 1]
            XCTAssertGreaterThanOrEqual(gap, 0.9, "rejoin \(i) came \(gap)s after the last: faster than once a second")
            XCTAssertLessThanOrEqual(gap, 1.6, "rejoin \(i) waited \(gap)s (E-11c: about a second, never a growing backoff)")
        }
    }

    /// E-11c: an orphaned rejoin's connect timeout is 2.0 s, not the session's
    /// general one (6 s here). Today the second dial comes after 6 s + the 1 s
    /// backoff step.
    func testAnOrphanedRejoinsConnectTimeoutIsTwoSeconds() throws {
        let (session, joinTimes) = try startAndOrphan { _ in
            // The phone is unreachable through this path: the dial must give
            // up on its own.
        }
        defer { session.closeAndWait() }
        XCTAssertTrue(waitFor(timeout: 10) { joinTimes().count >= 2 },
                      "the timed-out rejoin was never redialed")
        let times = joinTimes()
        guard times.count >= 2 else {
            return XCTFail("only \(times.count) rejoin dials")
        }
        let gap = times[1] - times[0]
        XCTAssertLessThanOrEqual(gap, 3.0,
                                 "an orphaned rejoin waited \(gap)s before the next dial (E-11c: 2.0 s timeout)")
    }

    // MARK: A pairing session's own pin (ISS-95, PATH-51/PATH-52)

    /// ISS-95: a session that pairs has, from `pair.ok`, the pin both ends
    /// verified. Its path then dies inside the grace: the rejoin must dial
    /// pinned and carry `hello{join}` so the phone attaches it to the same
    /// session. Before the fix the session stayed in pairing mode for life, its
    /// rejoin dial could not join, and the schedule stalled in flight until the
    /// 30 s grace ended.
    func testAPairingSessionRejoinsWithThePinPairingEstablished() throws {
        server = try FakeServer(phoneIdentity: phoneIdentity, trustingClientPem: macIdentity.identity.certPem)
        let brain = FakeV2PhoneBrain(identity: phoneIdentity, deviceId: "phone-1")
        brain.autoAllow = true
        server.brain = brain
        let lock = NSLock()
        var plainHellos = 0
        var joins: [String] = []
        var founder: FakeServer.Connection?
        server.onFrame = { connection, frame in
            guard frame.type == MessageType.json.rawValue,
                  let message = JSONFrame.decode(payload: frame.payload),
                  message.t == "hello" else { return }
            if let join = message.string("join") {
                lock.lock(); joins.append(join); let founderSession = founder?.sessionId; lock.unlock()
                if join == founderSession {
                    connection.sendJSON(Self.welcomeJSON(session: join))
                }
                return
            }
            // The plain hello starts the pairing prompt; the welcome follows
            // the brain's pair.ok on Allow, so it is not answered here.
            lock.lock(); plainHellos += 1; founder = connection; lock.unlock()
        }
        let endpoint = Session.Endpoint.hostPort(host: "127.0.0.1", port: server.port)
        let session = Session(endpoint: endpoint, knownDeviceId: nil,
                              clientId: "test-client", identity: macIdentity.identity,
                              connectTimeout: 2, pairingTimeout: 30)
        session.pairingPolicy = .allowed
        session.start()
        XCTAssertTrue(waitFor { session.state == .ready }, "never ready: \(session.state)")
        XCTAssertTrue(brain.sawPairRequest, "the pairing flow never ran")
        lock.lock()
        let founderConnection = founder
        lock.unlock()
        guard let founderConnection else { return XCTFail("no founding connection") }

        founderConnection.close()
        XCTAssertTrue(waitFor(timeout: 8) {
            lock.lock(); defer { lock.unlock() }
            return joins.contains(founderConnection.sessionId)
        }, "the pairing session's rejoin never reached the phone as a pinned join")
        XCTAssertTrue(waitFor { session.state == .ready }, "the session did not stay live: \(session.state)")
        lock.lock()
        let plains = plainHellos
        lock.unlock()
        XCTAssertEqual(1, plains, "the rejoin started a new session (plain hellos \(plains))")
        session.closeAndWait()
    }

    /// ISS-95: a session that never saw the phone's `pair.ok` has no verified
    /// pin, so it must never send `hello{join}` (PATH-11: an unpinned peer gets
    /// `busy`). Its refused rejoin still ends, and the ending must be reported:
    /// the schedule dials again about a second later rather than staying in
    /// flight. Before the fix the first dial was refused, the attempt vanished
    /// silently and no second dial was made.
    func testASessionWithoutAVerifiedPinNeverSendsTheJoinAndKeepsRedialing() throws {
        server = try FakeServer(phoneIdentity: phoneIdentity, trustingClientPem: macIdentity.identity.certPem)
        let lock = NSLock()
        var founder: FakeServer.Connection?
        var joinHellos = 0
        var acceptsAfterClose = 0
        var closed = false
        server.onRawFrame = { _, frame in
            guard frame.type == MessageType.json.rawValue,
                  let message = JSONFrame.decode(payload: frame.payload),
                  message.t == "hello", message.string("join") != nil else { return }
            lock.lock(); joinHellos += 1; lock.unlock()
        }
        server.onFrame = { connection, frame in
            guard frame.type == MessageType.json.rawValue,
                  let message = JSONFrame.decode(payload: frame.payload),
                  message.t == "hello", message.string("join") == nil else { return }
            // A phone that welcomes without pairing: this Mac has seen no
            // pair.ok, so its pin is not verified and it may not join.
            lock.lock(); founder = connection; lock.unlock()
            connection.sendJSON(Self.welcomeJSON(session: connection.sessionId))
        }
        server.onAccepted = { _ in
            lock.lock()
            if closed { acceptsAfterClose += 1 }
            lock.unlock()
        }
        let endpoint = Session.Endpoint.hostPort(host: "127.0.0.1", port: server.port)
        let session = Session(endpoint: endpoint, knownDeviceId: nil,
                              clientId: "test-client", identity: macIdentity.identity,
                              connectTimeout: 2, pairingTimeout: 30)
        session.pairingPolicy = .allowed
        session.start()
        XCTAssertTrue(waitFor { session.state == .ready }, "never ready: \(session.state)")
        lock.lock()
        let founderConnection = founder
        closed = true
        lock.unlock()
        guard let founderConnection else { return XCTFail("no founding connection") }

        founderConnection.close()
        XCTAssertTrue(waitFor(timeout: 6) {
            lock.lock(); defer { lock.unlock() }
            return acceptsAfterClose >= 2
        }, "the refused rejoin left the schedule in flight (dials after close: \(acceptsAfterClose))")
        lock.lock()
        let joins = joinHellos
        lock.unlock()
        XCTAssertEqual(0, joins, "a session with no verified pin sent hello{join}")
        session.closeAndWait()
    }

    /// ISS-95: the pin adopted from pairing is verified, not assumed. A phone
    /// that answers the rejoin with a different certificate is refused, so no
    /// `hello{join}` ever reaches it; the ending is reported and the schedule
    /// keeps dialing instead of stalling.
    func testARejoinIsRefusedWhenThePhonePresentsADifferentCertificate() throws {
        server = try FakeServer(phoneIdentity: phoneIdentity, trustingClientPem: macIdentity.identity.certPem)
        let brain = FakeV2PhoneBrain(identity: phoneIdentity, deviceId: "phone-1")
        brain.autoAllow = true
        server.brain = brain
        let lock = NSLock()
        var founder: FakeServer.Connection?
        var joins = 0
        var acceptsAfterClose = 0
        var closed = false
        server.onRawFrame = { _, frame in
            guard frame.type == MessageType.json.rawValue,
                  let message = JSONFrame.decode(payload: frame.payload),
                  message.t == "hello", message.string("join") != nil else { return }
            lock.lock(); joins += 1; lock.unlock()
        }
        server.onFrame = { connection, frame in
            guard frame.type == MessageType.json.rawValue,
                  let message = JSONFrame.decode(payload: frame.payload),
                  message.t == "hello", message.string("join") == nil else { return }
            lock.lock(); founder = connection; lock.unlock()
        }
        server.onAccepted = { _ in
            lock.lock()
            if closed { acceptsAfterClose += 1 }
            lock.unlock()
        }
        let endpoint = Session.Endpoint.hostPort(host: "127.0.0.1", port: server.port)
        let session = Session(endpoint: endpoint, knownDeviceId: nil,
                              clientId: "test-client", identity: macIdentity.identity,
                              connectTimeout: 2, pairingTimeout: 30)
        session.pairingPolicy = .allowed
        session.start()
        XCTAssertTrue(waitFor { session.state == .ready }, "never ready: \(session.state)")
        lock.lock()
        let founderConnection = founder
        lock.unlock()
        guard let founderConnection else { return XCTFail("no founding connection") }

        // The phone's identity changes under the Mac's pin (forgotten and
        // re-paired elsewhere): the same address now answers as another phone.
        server.swapPhoneIdentity(IdentityGeneratorV2.make(
            deviceId: "phone-1", cn: "Contigua Phone").identity)
        lock.lock(); closed = true; lock.unlock()
        founderConnection.close()
        XCTAssertTrue(waitFor(timeout: 6) {
            lock.lock(); defer { lock.unlock() }
            return acceptsAfterClose >= 2
        }, "a refused rejoin left the schedule in flight (dials after close: \(acceptsAfterClose))")
        lock.lock()
        let joinsSeen = joins
        lock.unlock()
        XCTAssertEqual(0, joinsSeen, "a different certificate was allowed to join")
        session.closeAndWait()
    }

    /// ISS-95: before the founding welcome there is no session to join. A
    /// pairing connection that dies at its hello must send no `join`, and its
    /// start must fail (the attempt's ending is reported to PathStart).
    func testAPairingSessionThatDiesBeforeWelcomeNeverJoins() throws {
        server = try FakeServer(phoneIdentity: phoneIdentity, trustingClientPem: macIdentity.identity.certPem)
        let lock = NSLock()
        var joins = 0
        server.onRawFrame = { _, frame in
            guard frame.type == MessageType.json.rawValue,
                  let message = JSONFrame.decode(payload: frame.payload),
                  message.t == "hello", message.string("join") != nil else { return }
            lock.lock(); joins += 1; lock.unlock()
        }
        server.onFrame = { connection, frame in
            guard frame.type == MessageType.json.rawValue,
                  let message = JSONFrame.decode(payload: frame.payload),
                  message.t == "hello", message.string("join") == nil else { return }
            connection.close()
        }
        let endpoint = Session.Endpoint.hostPort(host: "127.0.0.1", port: server.port)
        let session = Session(endpoint: endpoint, knownDeviceId: nil,
                              clientId: "test-client", identity: macIdentity.identity,
                              connectTimeout: 2, pairingTimeout: 30)
        session.pairingPolicy = .allowed
        session.start()
        XCTAssertTrue(waitFor(timeout: 8) {
            if case .failed = session.state { return true }
            return false
        }, "the start never failed: \(session.state)")
        lock.lock()
        let joinsSeen = joins
        lock.unlock()
        XCTAssertEqual(0, joinsSeen, "a session that never welcomed sent hello{join}")
        session.closeAndWait()
    }
}
