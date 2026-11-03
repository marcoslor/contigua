// PATH-22/E-5: a session below its path target re-dials the provider it lost,
// live or orphaned. Two providers; one path dies, or a planned switch drains
// the old path; the Mac dials a join and the session carries on with two paths.

import CryptoKit
import XCTest
@testable import PocketDeck

final class SessionRebalanceTests: XCTestCase {
    private var macIdentity: (identity: DeviceIdentityV2, privateKey: P256.Signing.PrivateKey)!
    private var phoneIdentity: DeviceIdentityV2!
    private var server: FakeServer!

    override func setUp() {
        macIdentity = IdentityGeneratorV2.make(deviceId: "mac-\(UUID().uuidString.prefix(8))")
        phoneIdentity = IdentityGeneratorV2.make(deviceId: "phone-\(UUID().uuidString.prefix(8))",
                                                 cn: "PocketDeck Phone").identity
        server = nil
    }

    override func tearDown() {
        server?.stop()
    }

    private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return condition()
    }

    private func makeSession(port: UInt16) -> Session {
        let record = PinnedPhoneV2(deviceId: "phone-1",
                                   phoneFingerprintHex: server.phoneFingerprintHex,
                                   certPem: phoneIdentity.certPem)
        let endpoint = Session.Endpoint.hostPort(host: "127.0.0.1", port: port)
        let session = Session(endpoint: endpoint, endpoints: [endpoint, endpoint],
                              knownDeviceId: "phone-1", clientId: "test-client",
                              identity: macIdentity.identity, pinnedPhone: record,
                              connectTimeout: 4)
        session.pairingPolicy = .never
        return session
    }

    private static func welcomeJSON(session: String) -> [String: Any] {
        ["t": "welcome", "session": session,
         "device": ["id": "phone-1", "name": "Pixel", "model": "Pixel", "sdk": 36,
                    "screen": ["w": 1080, "h": 2340, "dpi": 450], "locked": true]]
    }

    /// E-5, case 1: two providers, both paths up; one dies and the Mac re-dials
    /// the provider that is gone while the other path stays live. Before the
    /// fix an attached path's attempt was never removed, so `pathCount +
    /// attempts.count` counted it twice and no re-dial ever happened.
    func testADeadPathIsRedialedWhileTheOtherStaysLive() throws {
        server = try FakeServer(phoneIdentity: phoneIdentity, trustingClientPem: macIdentity.identity.certPem)
        let lock = NSLock()
        var foundingSession: String?
        var plain = 0
        var joinConnections: [FakeServer.Connection] = []
        var welcomes = 0
        server.onFrame = { connection, frame in
            guard frame.type == MessageType.json.rawValue,
                  let message = JSONFrame.decode(payload: frame.payload),
                  message.t == "hello" else { return }
            if let join = message.string("join") {
                lock.lock(); let session = foundingSession; lock.unlock()
                guard join == session else { return }
                lock.lock(); joinConnections.append(connection); welcomes += 1; lock.unlock()
                connection.sendJSON(Self.welcomeJSON(session: join))
                return
            }
            let session = PathIds.sessionId()
            lock.lock(); plain += 1; foundingSession = session; welcomes += 1; lock.unlock()
            connection.sendJSON(Self.welcomeJSON(session: session))
        }
        let session = makeSession(port: server.port)
        var reconnecting = false
        session.onEvent = { event in
            if case .pathsReconnecting(true) = event { reconnecting = true }
        }
        session.start()
        XCTAssertTrue(waitFor { session.state == .ready }, "never ready: \(session.state)")
        XCTAssertTrue(waitFor {
            lock.lock(); defer { lock.unlock() }
            return welcomes >= 2
        }, "the second provider never joined")
        // Let the Mac attach the joined path before killing a socket.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        lock.lock()
        let victim = joinConnections.last
        let joinsBefore = joinConnections.count
        lock.unlock()
        XCTAssertNotNil(victim)
        victim?.close()

        XCTAssertTrue(waitFor {
            lock.lock(); defer { lock.unlock() }
            return joinConnections.count > joinsBefore
        }, "the Mac never re-dialed the lost provider (plain \(plain), welcomes \(welcomes))")
        lock.lock()
        let plains = plain
        let joins = joinConnections.count
        lock.unlock()
        XCTAssertEqual(1, plains, "a second session started instead of a re-dial")
        XCTAssertGreaterThanOrEqual(joins, 2)
        XCTAssertFalse(reconnecting, "the live session said reconnecting with a path up")
        XCTAssertEqual(.ready, session.state)
        session.closeAndWait()
    }

    /// E-5, case 2: a planned margin switch drains the old path; the Mac then
    /// re-dials that provider, so the session goes back to two paths. The
    /// founder answers slowly (150 ms), the joined path fast, so the ranking
    /// elects the founder first and then challenges it with the faster path.
    func testAPlannedSwitchRedialsTheDrainedPath() throws {
        server = try FakeServer(phoneIdentity: phoneIdentity, trustingClientPem: macIdentity.identity.certPem)
        server.answerPings = false
        let lock = NSLock()
        var foundingSession: String?
        var plain = 0
        var joins: [FakeServer.Connection] = []
        var welcomes = 0
        var markers = 0
        var enables = 0
        var founderPath: String?
        var joinedPath: String?
        let start = Date()
        // The founder is the slow path; the join is withheld until the founder
        // has two pongs (the ranking's own election), then answers fast.
        server.onFrame = { connection, frame in
            guard frame.type == MessageType.json.rawValue,
                  let message = JSONFrame.decode(payload: frame.payload) else { return }
            if message.t == "notify.enable" {
                // NOTIFY-1: the ready-time ask only; a planned switch is not
                // a reconnect and sends nothing.
                lock.lock(); enables += 1; lock.unlock()
                return
            }
            if message.t == "hello" {
                if let join = message.string("join") {
                    lock.lock(); let session = foundingSession; lock.unlock()
                    guard join == session else { return }
                    lock.lock(); joinedPath = message.string("path"); joins.append(connection)
                    welcomes += 1; lock.unlock()
                    connection.sendJSON(Self.welcomeJSON(session: join))
                } else {
                    let session = PathIds.sessionId()
                    lock.lock(); founderPath = message.string("path")
                    plain += 1; foundingSession = session; welcomes += 1; lock.unlock()
                    connection.sendJSON(Self.welcomeJSON(session: session))
                }
                return
            }
            if message.t == "path.switch" {
                // The Mac's own marker: the phone's marker is the last frame
                // it sends on the old path.
                guard let target = message.string("path") else { return }
                lock.lock(); markers += 1; lock.unlock()
                let echo = Frame(type: MessageType.json.rawValue, stream: 0,
                                 payload: JSONFrame.payload([
                                     "t": "path.switch", "path": target, "seq": 2,
                                 ]))
                if let wrapped = try? PathCodec.encodeReliable(seq: 1, inner: echo).encoded,
                   let frame = Frame(encoded: wrapped) {
                    connection.send(frame)
                }
                return
            }
            guard message.t == "path.ping", let path = message.string("path"),
                  let ts = message.int("ts") else { return }
            lock.lock()
            let isFounder = path == founderPath
            let joinedAt = joinedPath == path ? start : nil
            lock.unlock()
            var delay: TimeInterval = 0
            if isFounder {
                delay = 0.15
            } else if let joinedAt {
                // Withhold the first two rounds so the founder is elected;
                // after the join the first ping comes from the second round.
                delay = Date().timeIntervalSince(joinedAt) < 4.5 ? 30 : 0
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                connection.sendJSON(["t": "path.pong", "path": path, "ts": ts])
            }
        }
        let session = makeSession(port: server.port)
        session.start()
        XCTAssertTrue(waitFor { session.state == .ready }, "never ready: \(session.state)")
        // The per-phone switch is on: the ready-time ask goes out once.
        session.enableNotifications(true)
        XCTAssertTrue(waitFor {
            lock.lock(); defer { lock.unlock() }
            return enables == 1
        }, "the ready-time notify.enable never went out")
        XCTAssertTrue(waitFor {
            lock.lock(); defer { lock.unlock() }
            return welcomes >= 2
        }, "the second provider never joined")
        XCTAssertTrue(waitFor(timeout: 30) {
            lock.lock(); defer { lock.unlock() }
            return markers >= 1
        }, "no planned margin switch happened")
        // Drain + re-dial: the drained provider comes back as a join.
        XCTAssertTrue(waitFor(timeout: 20) {
            lock.lock(); defer { lock.unlock() }
            return joins.count >= 2
        }, "the drained provider was never re-dialed (welcomes \(welcomes))")
        lock.lock()
        let plains = plain
        let joinCount = joins.count
        let optIns = enables
        lock.unlock()
        XCTAssertEqual(1, plains, "a second session started after the switch")
        XCTAssertGreaterThanOrEqual(joinCount, 2)
        XCTAssertEqual(1, optIns, "a planned switch repeated the notify opt-in")
        XCTAssertEqual(.ready, session.state, "the session ended during the switch")
        session.closeAndWait()
    }
}
