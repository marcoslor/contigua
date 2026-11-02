// The orphan's rejoin dials (docs/design/paths.md §6, E-11c): while a session
// is in its 30 s grace a failed rejoin is followed by the next dial at once,
// and each rejoin gives up after 2.0 s (the probe's own timeout, not the
// session's general one), so a phone that comes back inside the grace meets a
// dial within about a second. Outside the grace the reconnect backoff is
// unchanged (§7.4).

import CryptoKit
import XCTest
@testable import PocketDeck

final class PathRejoinSessionTests: XCTestCase {
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
}
