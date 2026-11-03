// PATH-6/10: an orphan holds the person's reliable frames for the path that
// rejoins, instead of writing them bare to the dead founder or failing a drop.
// (P1 review R-4.)

import CryptoKit
import XCTest
@testable import PocketDeck

final class SessionOrphanTests: XCTestCase {
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

    /// D-3: while orphaned the Mac re-dials its provider with `hello{join}` on
    /// the reconnect backoff; the same session id comes back and no new
    /// session starts.
    func testAnOrphanRedialsAJoinAndTheSameSessionComesBack() throws {
        server = try FakeServer(phoneIdentity: phoneIdentity, trustingClientPem: macIdentity.identity.certPem)
        let lock = NSLock()
        var plainHellos = 0
        var joinHellos = 0
        var foundingSession: String?
        var founder: FakeServer.Connection?
        server.onFrame = { connection, frame in
            guard frame.type == MessageType.json.rawValue,
                  let message = JSONFrame.decode(payload: frame.payload),
                  message.t == "hello" else { return }
            if let join = message.string("join") {
                lock.lock(); joinHellos += 1; let session = foundingSession; lock.unlock()
                guard join == session else { return }
                connection.sendJSON(Self.welcomeJSON(session: join))
                return
            }
            let session = PathIds.sessionId()
            lock.lock(); plainHellos += 1; foundingSession = session; founder = connection; lock.unlock()
            connection.sendJSON(Self.welcomeJSON(session: session))
        }
        let record = PinnedPhoneV2(deviceId: "phone-1",
                                   phoneFingerprintHex: server.phoneFingerprintHex,
                                   certPem: phoneIdentity.certPem)
        let endpoint = Session.Endpoint.hostPort(host: "127.0.0.1", port: server.port)
        let session = Session(endpoint: endpoint, knownDeviceId: "phone-1",
                              clientId: "test-client", identity: macIdentity.identity,
                              pinnedPhone: record, connectTimeout: 2)
        session.pairingPolicy = .never
        let reconnecting = NSLock()
        var wasReconnecting = false
        var isReconnecting = false
        session.onEvent = { event in
            if case .pathsReconnecting(let on) = event {
                reconnecting.lock()
                wasReconnecting = wasReconnecting || on
                isReconnecting = on
                reconnecting.unlock()
            }
        }
        session.start()
        XCTAssertTrue(waitFor { session.state == .ready }, "never ready: \(session.state)")

        lock.lock(); let founderConnection = founder; lock.unlock()
        founderConnection?.close()
        XCTAssertTrue(waitFor {
            reconnecting.lock(); defer { reconnecting.unlock() }
            return wasReconnecting
        }, "the session never went orphaned")

        let reconnected = waitFor(timeout: 8) {
            lock.lock(); defer { lock.unlock() }
            return joinHellos >= 1
        }
        XCTAssertTrue(reconnected, "the orphan never re-dialed a join (plain \(plainHellos))")
        XCTAssertTrue(waitFor {
            reconnecting.lock(); defer { reconnecting.unlock() }
            return !isReconnecting
        }, "the windows never cleared \"reconnecting\"")
        lock.lock()
        let plaints = plainHellos
        let joins = joinHellos
        let sessionId = foundingSession
        lock.unlock()
        XCTAssertEqual(1, plaints, "the rejoin started a new session (plain hellos)")
        XCTAssertGreaterThanOrEqual(joins, 1)
        XCTAssertNotNil(sessionId)
        XCTAssertEqual(.ready, session.state)
        session.closeAndWait()
    }

    /// RR-12: a rejoin refused with `no_session` (the phone's server restarted
    /// or its grace ended first) ends the orphan at once, so the controller
    /// starts exactly one new session instead of dialing a dead id for 30 s.
    func testARejoinRefusedWithNoSessionEndsTheOrphanAtOnce() throws {
        server = try FakeServer(phoneIdentity: phoneIdentity, trustingClientPem: macIdentity.identity.certPem)
        let lock = NSLock()
        var founder: FakeServer.Connection?
        var foundingSession: String?
        var joinHellos = 0
        server.onFrame = { connection, frame in
            guard frame.type == MessageType.json.rawValue,
                  let message = JSONFrame.decode(payload: frame.payload),
                  message.t == "hello" else { return }
            if let join = message.string("join") {
                lock.lock(); joinHellos += 1; let count = joinHellos; lock.unlock()
                // The second provider joins the live session; the orphan's
                // re-dial is refused: the phone's server restarted.
                if count == 1 {
                    connection.sendJSON(Self.welcomeJSON(session: join))
                } else {
                    connection.sendJSON(["t": "error", "code": "no_session"])
                }
                return
            }
            let session = PathIds.sessionId()
            lock.lock(); foundingSession = session; founder = connection; lock.unlock()
            connection.sendJSON(Self.welcomeJSON(session: session))
        }
        let record = PinnedPhoneV2(deviceId: "phone-1",
                                   phoneFingerprintHex: server.phoneFingerprintHex,
                                   certPem: phoneIdentity.certPem)
        let endpoint = Session.Endpoint.hostPort(host: "127.0.0.1", port: server.port)
        let session = Session(endpoint: endpoint, endpoints: [endpoint, endpoint],
                              knownDeviceId: "phone-1", clientId: "test-client",
                              identity: macIdentity.identity, pinnedPhone: record,
                              connectTimeout: 4)
        session.pairingPolicy = .never
        session.start()
        XCTAssertTrue(waitFor { session.state == .ready }, "never ready: \(session.state)")
        XCTAssertTrue(waitFor {
            lock.lock(); defer { lock.unlock() }
            return foundingSession != nil
        })
        lock.lock(); let founderConnection = founder; lock.unlock()
        founderConnection?.close()
        let failed = waitFor(timeout: 6) {
            if case .failed(let reason) = session.state { return reason == "no_session" }
            return false
        }
        XCTAssertTrue(failed, "the refused rejoin did not end the orphan: \(session.state)")
        lock.lock(); let joins = joinHellos; lock.unlock()
        XCTAssertGreaterThanOrEqual(joins, 1)
        session.closeAndWait()
    }

    /// RRR-9: a rejoin refused `busy` means the phone's session is ending, not
    /// that another Mac is connected. It must fail as `no_session`, so the
    /// person reads "No session", not the wrong "Another Mac is connected".
    func testARejoinRefusedBusyIsReportedAsNoSession() throws {
        server = try FakeServer(phoneIdentity: phoneIdentity, trustingClientPem: macIdentity.identity.certPem)
        let lock = NSLock()
        var founder: FakeServer.Connection?
        var foundingSession: String?
        var joinHellos = 0
        server.onFrame = { connection, frame in
            guard frame.type == MessageType.json.rawValue,
                  let message = JSONFrame.decode(payload: frame.payload),
                  message.t == "hello" else { return }
            if let join = message.string("join") {
                lock.lock(); joinHellos += 1; let count = joinHellos; lock.unlock()
                if count == 1 {
                    connection.sendJSON(Self.welcomeJSON(session: join))
                } else {
                    connection.sendJSON(["t": "error", "code": "busy"])
                }
                return
            }
            let session = PathIds.sessionId()
            lock.lock(); foundingSession = session; founder = connection; lock.unlock()
            connection.sendJSON(Self.welcomeJSON(session: session))
        }
        let record = PinnedPhoneV2(deviceId: "phone-1",
                                   phoneFingerprintHex: server.phoneFingerprintHex,
                                   certPem: phoneIdentity.certPem)
        let endpoint = Session.Endpoint.hostPort(host: "127.0.0.1", port: server.port)
        let session = Session(endpoint: endpoint, endpoints: [endpoint, endpoint],
                              knownDeviceId: "phone-1", clientId: "test-client",
                              identity: macIdentity.identity, pinnedPhone: record,
                              connectTimeout: 4)
        session.pairingPolicy = .never
        session.start()
        XCTAssertTrue(waitFor { session.state == .ready }, "never ready: \(session.state)")
        XCTAssertTrue(waitFor {
            lock.lock(); defer { lock.unlock() }
            return foundingSession != nil
        })
        lock.lock(); let founderConnection = founder; lock.unlock()
        founderConnection?.close()
        let failed = waitFor(timeout: 6) {
            if case .failed(let reason) = session.state { return reason == "no_session" }
            return false
        }
        XCTAssertTrue(failed, "a busy rejoin did not end the orphan as no_session: \(session.state)")
        session.closeAndWait()
    }

    /// The founder welcomes; the held attempt joins; the founder's socket then
    /// dies (the only path is gone). A key and a drop chunk sent while orphaned
    /// must be held and replayed on the joining path, and the drop must not be
    /// reported failed (FileDrop turns `sent(false)` into "lost the connection").
    func testAnOrphanHoldsAKeyAndADropForTheJoiningPath() throws {
        server = try FakeServer(phoneIdentity: phoneIdentity, trustingClientPem: macIdentity.identity.certPem)
        let lock = NSLock()
        var founder: FakeServer.Connection?
        var foundingSession: String?
        var joinConnection: FakeServer.Connection?
        var joinPath: String?
        var keysOnJoin = 0
        var dropBytesOnJoin = 0
        var dropLength = 0
        server!.onFrame = { connection, frame in
            switch frame.messageType {
            case .json:
                guard let message = JSONFrame.decode(payload: frame.payload) else { return }
                if message.t == "hello" {
                    if message.string("join") != nil {
                        lock.lock()
                        joinConnection = connection
                        joinPath = message.string("path")
                        lock.unlock()
                        // Held until the test has sent the orphaned frames.
                        return
                    }
                    let session = PathIds.sessionId()
                    lock.lock()
                    founder = connection
                    foundingSession = session
                    lock.unlock()
                    connection.sendJSON(Self.welcomeJSON(session: session))
                    return
                }
            case .key:
                lock.lock(); keysOnJoin += 1; lock.unlock()
            case .dropData:
                lock.lock(); dropBytesOnJoin += frame.payload.count; dropLength += 1; lock.unlock()
            default:
                break
            }
        }
        let record = PinnedPhoneV2(deviceId: "phone-1",
                                   phoneFingerprintHex: server.phoneFingerprintHex,
                                   certPem: phoneIdentity.certPem)
        let endpoint = Session.Endpoint.hostPort(host: "127.0.0.1", port: server.port)
        let session = Session(endpoint: endpoint, endpoints: [endpoint, endpoint],
                              knownDeviceId: "phone-1", clientId: "test-client",
                              identity: macIdentity.identity, pinnedPhone: record,
                              connectTimeout: 8)
        session.pairingPolicy = .never
        var reconnecting = false
        var failed = false
        session.onEvent = { event in
            if case .pathsReconnecting(true) = event { reconnecting = true }
            if case .state(.failed, _) = event { failed = true }
        }
        session.start()
        XCTAssertTrue(waitFor { session.state == .ready }, "never ready: \(session.state)")

        // The second provider's join hello is held by the phone: the path is not
        // attached yet. Kill the founder's socket, the session's only path.
        XCTAssertTrue(waitFor {
            lock.lock(); defer { lock.unlock() }
            return joinConnection != nil
        }, "the held attempt never sent its join")
        lock.lock(); let founderConnection = founder; lock.unlock()
        founderConnection?.close()
        XCTAssertTrue(waitFor { reconnecting }, "the session never went orphaned")

        // The person types and a drop chunk is produced while no path is up.
        session.key(KeyEvent(action: 0, keycode: 29), stream: 1)
        let chunk = [UInt8](repeating: 0xAB, count: 256 << 10)
        var completion: Bool?
        session.sendDropData(id: 7, bytes: chunk, sent: { ok in completion = ok })
        XCTAssertEqual(true, completion, "the drop chunk was refused while orphaned (FileDrop fails the drop)")

        // The route comes back: the same session, one more path.
        lock.lock(); let joining = joinConnection; lock.unlock()
        guard let joining, let foundingSession else {
            return XCTFail("no held join to attach")
        }
        joining.sendJSON(Self.welcomeJSON(session: foundingSession))

        XCTAssertTrue(waitFor {
            lock.lock(); defer { lock.unlock() }
            return keysOnJoin >= 1 && dropBytesOnJoin == chunk.count
        }, "the orphaned frames never reached the rejoined path (keys \(keysOnJoin), drop bytes \(dropBytesOnJoin), frames \(dropLength))")
        lock.lock(); let path = joinPath; lock.unlock()
        XCTAssertNotNil(path)
        XCTAssertFalse(failed, "the session failed while the only path was gone")
        XCTAssertEqual(.ready, session.state)
        session.closeAndWait()
    }

    /// NOTIFY-1/PATH-6 (ISS-5): a same-session rejoin after an outage is the
    /// reconnect the ready branch never sees. The Mac repeats its notify
    /// opt-in once the rejoined path is current, so the phone answers with its
    /// active set; a session that never lost every path sends nothing.
    func testARejoinAfterAnOutageRepeatsTheNotifyOptIn() throws {
        server = try FakeServer(phoneIdentity: phoneIdentity, trustingClientPem: macIdentity.identity.certPem)
        let lock = NSLock()
        var foundingSession: String?
        var founder: FakeServer.Connection?
        var joinConnection: FakeServer.Connection?
        var enables = 0
        var rejoinEnables = 0
        var rejoined = false
        server.onFrame = { connection, frame in
            guard frame.type == MessageType.json.rawValue,
                  let message = JSONFrame.decode(payload: frame.payload) else { return }
            if message.t == "notify.enable" {
                lock.lock()
                enables += 1
                if rejoined { rejoinEnables += 1 }
                lock.unlock()
                return
            }
            guard message.t == "hello" else { return }
            if let join = message.string("join") {
                lock.lock(); let session = foundingSession; lock.unlock()
                guard join == session else { return }
                lock.lock(); joinConnection = connection; rejoined = true; lock.unlock()
                connection.sendJSON(Self.welcomeJSON(session: join))
                return
            }
            let session = PathIds.sessionId()
            lock.lock(); foundingSession = session; founder = connection; lock.unlock()
            connection.sendJSON(Self.welcomeJSON(session: session))
        }
        let record = PinnedPhoneV2(deviceId: "phone-1",
                                   phoneFingerprintHex: server.phoneFingerprintHex,
                                   certPem: phoneIdentity.certPem)
        let endpoint = Session.Endpoint.hostPort(host: "127.0.0.1", port: server.port)
        let session = Session(endpoint: endpoint, knownDeviceId: "phone-1",
                              clientId: "test-client", identity: macIdentity.identity,
                              pinnedPhone: record, connectTimeout: 2)
        session.pairingPolicy = .never
        var reconnecting = false
        session.onEvent = { event in
            if case .pathsReconnecting(true) = event {
                lock.lock(); reconnecting = true; lock.unlock()
            }
        }
        session.start()
        XCTAssertTrue(waitFor { session.state == .ready }, "never ready: \(session.state)")
        // The controller's ready branch asks once, like a fresh welcome.
        session.enableNotifications(true)
        XCTAssertTrue(waitFor {
            lock.lock(); defer { lock.unlock() }
            return enables == 1
        }, "the ready-time notify.enable never went out")
        lock.lock(); let founderConnection = founder; lock.unlock()
        founderConnection?.close()
        XCTAssertTrue(waitFor {
            lock.lock(); defer { lock.unlock() }
            return reconnecting
        }, "the session never went orphaned")
        XCTAssertTrue(waitFor(timeout: 8) {
            lock.lock(); defer { lock.unlock() }
            return joinConnection != nil
        }, "the orphan never re-dialed a join")
        XCTAssertTrue(waitFor {
            lock.lock(); defer { lock.unlock() }
            return rejoinEnables == 1
        }, "the rejoin never repeated the notify opt-in")
        lock.lock()
        let total = enables
        let afterRejoin = rejoinEnables
        lock.unlock()
        XCTAssertEqual(1, afterRejoin, "one repeat for one rejoin")
        XCTAssertEqual(2, total, "the ready-time ask plus the rejoin's")
        XCTAssertEqual(.ready, session.state)
        session.closeAndWait()
    }
}
