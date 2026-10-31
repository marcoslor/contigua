// PATH-7/PATH-21: the 1.5 s pong rule is for sessions with two or more paths.
// A one-path session samples a lost pong and stays live, over the real wire.

import CryptoKit
import XCTest
@testable import PocketDeck

final class SessionPongTests: XCTestCase {
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

    private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return condition()
    }

    /// PATH-7: the 1.5 s pong rule applies WHILE a session has two or more
    /// paths. On the only path a lost pong is a ranking sample, not a failure.
    func testOneLostPongOnTheOnlyPathDoesNotReconnect() throws {
        server = try FakeServer(phoneIdentity: phoneIdentity,
                                trustingClientPem: macIdentity.identity.certPem)
        let brain = FakeV2PhoneBrain(identity: phoneIdentity, deviceId: "phone-1")
        brain.autoAllow = true
        server.brain = brain
        server.answerPings = false
        let lock = NSLock()
        var reconnecting = false
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: server.port),
                              knownDeviceId: nil, clientId: "test-client",
                              identity: macIdentity.identity,
                              connectTimeout: 2, pairingTimeout: 30)
        session.pairingPolicy = .allowed
        session.onEvent = { event in
            if case .pathsReconnecting(let on) = event, on {
                lock.lock(); reconnecting = true; lock.unlock()
            }
        }
        session.start()
        XCTAssertTrue(waitFor { session.state == .ready }, "never ready: \(session.state)")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 3.0))
        lock.lock(); let went = reconnecting; lock.unlock()
        XCTAssertFalse(went, "the only path failed on one lost pong")
        XCTAssertEqual(.ready, session.state)
        session.closeAndWait()
    }
}

extension SessionPongTests {
    private static func welcomeJSON(session: String) -> [String: Any] {
        ["t": "welcome", "session": session,
         "device": ["id": "phone-1", "name": "Pixel", "model": "Pixel", "sdk": 36,
                    "screen": ["w": 1080, "h": 2340, "dpi": 450], "locked": true]]
    }

    /// RR-9/PATH-7: "active" is the phone's screen on, any open stream, or a
    /// bulk transfer in the last 2 s. A streamed app window with the screen off
    /// still has to keep the 2 s path ping: the session's failure detection
    /// must not fall to the 15 s idle interval.
    func testAnOpenStreamWithTheScreenOffKeepsTheFastPing() throws {
        server = try FakeServer(phoneIdentity: phoneIdentity,
                                trustingClientPem: macIdentity.identity.certPem)
        let brain = FakeV2PhoneBrain(identity: phoneIdentity, deviceId: "phone-1")
        brain.autoAllow = true
        server.brain = brain
        let lock = NSLock()
        var welcomes = 0
        var pings = 0
        var foundingSession: String?
        var phoneState: FakeServer.Connection?
        server.onFrame = { connection, frame in
            guard frame.type == MessageType.json.rawValue,
                  let message = JSONFrame.decode(payload: frame.payload) else { return }
            if message.t == "hello" {
                if let join = message.string("join") {
                    lock.lock(); let session = foundingSession; lock.unlock()
                    guard join == session else { return }
                    lock.lock(); welcomes += 1; phoneState = connection; lock.unlock()
                    connection.sendJSON(Self.welcomeJSON(session: join))
                } else {
                    let session = PathIds.sessionId()
                    lock.lock(); foundingSession = session; welcomes += 1
                    phoneState = connection; lock.unlock()
                    connection.sendJSON(Self.welcomeJSON(session: session))
                }
            }
        }
        server.onRawFrame = { _, frame in
            guard frame.type == MessageType.json.rawValue,
                  JSONFrame.decode(payload: frame.payload)?.t == "path.ping" else { return }
            lock.lock(); pings += 1; lock.unlock()
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
        var screenOffEvent = false
        let eventLock = NSLock()
        session.onEvent = { event in
            if case .phoneState(_, _, _, _, _, _, _, let screen, _, _) = event,
               screen == .off {
                eventLock.lock(); screenOffEvent = true; eventLock.unlock()
            }
        }
        session.start()
        XCTAssertTrue(waitFor { session.state == .ready }, "never ready: \(session.state)")
        XCTAssertTrue(waitFor {
            lock.lock(); defer { lock.unlock() }
            return welcomes >= 2
        }, "the second path never joined")
        lock.lock()
        let current = phoneState
        lock.unlock()
        // The phone's screen goes off; a streamed app keeps running.
        current?.sendJSON(["t": "state", "screen": "off", "locked": true])
        XCTAssertTrue(waitFor {
            eventLock.lock(); defer { eventLock.unlock() }
            return screenOffEvent
        }, "the Mac never took the phone's screen-off state")
        session.openApp(stream: 1, pkg: "com.example.app", activity: nil,
                        width: 900, height: 600, dpi: 160)
        // Let a ping that was already due (a stale lastPingAt from before the
        // second path joined) land outside the measured window.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 2.5))
        let before = { () -> Int in lock.lock(); defer { lock.unlock() }; return pings }()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 3.2))
        let after = { () -> Int in lock.lock(); defer { lock.unlock() }; return pings }()
        XCTAssertGreaterThan(after - before, 0,
                             "an open stream with the screen off sent no 2 s path.ping")
        session.closeAndWait()
    }
}
