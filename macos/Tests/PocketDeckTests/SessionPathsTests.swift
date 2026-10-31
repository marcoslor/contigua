// PATH-1/3/4/9: the Mac's own hello, the welcome's session and the path layer
// over a real (fake) TLS phone. The pure machines and the codec have their own
// suites; this one proves the session wires them together.

import CryptoKit
import XCTest
@testable import PocketDeck

final class SessionPathsTests: XCTestCase {
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

    private func makeSession(port: UInt16) -> Session {
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: port), knownDeviceId: nil,
                              clientId: "test-client", identity: macIdentity.identity,
                              connectTimeout: 2, pairingTimeout: 30)
        session.pairingPolicy = .allowed
        return session
    }

    func testTheHelloCarriesProtocolFourAndAPathId() throws {
        server = try FakeServer(phoneIdentity: phoneIdentity, trustingClientPem: macIdentity.identity.certPem)
        let brain = FakeV2PhoneBrain(identity: phoneIdentity, deviceId: "phone-1")
        brain.autoAllow = true
        server.brain = brain
        let hellos = NSMutableArray()
        let lock = NSLock()
        server.onRawFrame = { _, frame in
            guard frame.type == MessageType.json.rawValue,
                  let message = JSONFrame.decode(payload: frame.payload), message.t == "hello" else { return }
            lock.lock(); hellos.add(message.raw); lock.unlock()
        }
        let session = makeSession(port: server.port)
        session.start()
        XCTAssertTrue(waitFor { session.state == .ready }, "never ready: \(session.state)")
        lock.lock()
        let hello = try XCTUnwrap(hellos.firstObject as? [String: Any])
        lock.unlock()
        XCTAssertEqual((hello["v"] as? NSNumber)?.intValue, 4)
        let path = try XCTUnwrap(hello["path"] as? String)
        XCTAssertEqual(8, path.count)
        XCTAssertTrue(path.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertNil(hello["join"])
        session.close()
    }

    func testAVersionRefusalStopsTheSessionWithTheSentence() throws {
        server = try FakeServer(phoneIdentity: phoneIdentity, trustingClientPem: macIdentity.identity.certPem)
        let lock = NSLock()
        var refused = false
        server.onFrame = { connection, frame in
            guard frame.type == MessageType.json.rawValue,
                  let message = JSONFrame.decode(payload: frame.payload), message.t == "hello" else { return }
            lock.lock(); refused = true; lock.unlock()
            // A v3 phone: it sends no `v` of its own.
            connection.sendJSON(["t": "error", "code": "version"])
        }
        let session = makeSession(port: server.port)
        var sentences: [String] = []
        session.onEvent = { event in
            if case .versionRefused(let sentence) = event { sentences.append(sentence) }
        }
        session.start()
        XCTAssertTrue(waitFor { if case .failed(let reason) = session.state { return reason == "version" }
                                return false })
        XCTAssertEqual(["Update PocketDeck on your phone."], sentences)
        lock.lock(); let sawHello = refused; lock.unlock()
        XCTAssertTrue(sawHello)
        session.close()
    }

    func testAfterWelcomeTheMacWrapsReliableFrames() throws {
        server = try FakeServer(phoneIdentity: phoneIdentity, trustingClientPem: macIdentity.identity.certPem)
        let brain = FakeV2PhoneBrain(identity: phoneIdentity, deviceId: "phone-1")
        brain.autoAllow = true
        server.brain = brain
        let lock = NSLock()
        var reliableSeqs: [UInt64] = []
        server.onRawFrame = { _, frame in
            guard frame.type == PathCodec.reliableType,
                  let reliable = try? PathCodec.decodeReliable(frame) else { return }
            lock.lock(); reliableSeqs.append(reliable.seq); lock.unlock()
        }
        let session = makeSession(port: server.port)
        session.start()
        XCTAssertTrue(waitFor { session.state == .ready })
        session.requestApps()
        XCTAssertTrue(waitFor {
            lock.lock(); defer { lock.unlock() }
            return !reliableSeqs.isEmpty
        })
        lock.lock()
        let seqs = reliableSeqs
        lock.unlock()
        XCTAssertEqual(1, seqs.first)
        XCTAssertEqual(Array(1...UInt64(seqs.count)), seqs)
        session.close()
    }
}
