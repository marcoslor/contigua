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
