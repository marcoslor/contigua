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
}
