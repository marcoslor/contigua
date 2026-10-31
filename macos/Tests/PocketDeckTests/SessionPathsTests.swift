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

    /// RR-2/E-2, the reviewer's scratch case: a session attached to the window
    /// manager before `start()` sends while it is dialing; a stream window that
    /// closes during "reconnecting" sends `window.close`. That send must not
    /// spend a seq: the first seq on the wire after the welcome is 1, or the
    /// phone sits on a seq-1 hole for the whole session (its reorder window
    /// holds every frame, then raises a protocol error).
    func testAFrameSentBeforeTheWelcomeSpendsNoSeq() throws {
        server = try FakeServer(phoneIdentity: phoneIdentity, trustingClientPem: macIdentity.identity.certPem)
        let brain = FakeV2PhoneBrain(identity: phoneIdentity, deviceId: "phone-1")
        brain.autoAllow = true
        server.brain = brain
        let lock = NSLock()
        var seqs: [UInt64] = []
        var keySeqs: [UInt64] = []
        server.onRawFrame = { _, frame in
            guard frame.type == PathCodec.reliableType,
                  let reliable = try? PathCodec.decodeReliable(frame) else { return }
            lock.lock(); seqs.append(reliable.seq); lock.unlock()
            if reliable.inner.type == MessageType.key.rawValue {
                lock.lock(); keySeqs.append(reliable.seq); lock.unlock()
            }
        }
        let session = makeSession(port: server.port)
        session.closeWindow(stream: 1)
        session.start()
        XCTAssertTrue(waitFor { session.state == .ready }, "never ready: \(session.state)")
        session.key(KeyEvent(action: 0, keycode: 29), stream: 2)
        XCTAssertTrue(waitFor {
            lock.lock(); defer { lock.unlock() }
            return !keySeqs.isEmpty
        }, "the key never reached the phone")
        lock.lock()
        let all = seqs
        let keys = keySeqs
        lock.unlock()
        XCTAssertEqual([1], keys, "the key after the welcome is the first seq (all seqs \(all))")
        XCTAssertEqual(all.count, Int(all.last ?? 0), "the seqs on the wire start at 1 with no hole")
        session.close()
    }

    /// Boot 6: the phone pings as soon as it welcomes, before the Mac has
    /// answered anything else. The ping must get a pong whether it shares the
    /// welcome's write (one TLS read) or follows it (two).
    func testTheFirstPingInTheSameWriteAsWelcomeIsAnswered() throws {
        try assertFirstPingAnswered(combined: true)
    }

    func testTheFirstPingAfterWelcomeInItsOwnWriteIsAnswered() throws {
        try assertFirstPingAnswered(combined: false)
    }

    /// The phone's ticker pings a path the moment it is attached, and a join
    /// is attached on the acceptor thread: its ping can be on the wire before
    /// the join's welcome is written. The Mac must answer it for the path it
    /// is attaching, not drop it as an unknown pre-welcome frame.
    func testAPingForAJoiningPathBeforeItsWelcomeIsAnswered() throws {
        server = try FakeServer(phoneIdentity: phoneIdentity, trustingClientPem: macIdentity.identity.certPem)
        let lock = NSLock()
        var pongs: [String] = []
        var foundedSession: String?
        var joinPath: String?
        server.onRawFrame = { _, frame in
            guard frame.type == MessageType.json.rawValue,
                  let message = JSONFrame.decode(payload: frame.payload),
                  message.t == "path.pong", let path = message.string("path") else { return }
            lock.lock(); pongs.append(path); lock.unlock()
        }
        server.onFrame = { connection, frame in
            guard frame.type == MessageType.json.rawValue,
                  let message = JSONFrame.decode(payload: frame.payload),
                  message.t == "hello", let path = message.string("path") else { return }
            if message.string("join") != nil {
                lock.lock(); let session = foundedSession; lock.unlock()
                guard let session else { return }
                lock.lock(); joinPath = path; lock.unlock()
                // The phone's ticker can name the joined path just before the
                // join's welcome leaves: both frames are in order, the ping
                // first.
                connection.sendJSON(["t": "path.ping", "path": path, "ts": 1])
                connection.sendJSON(Self.welcomeJSON(session: session))
            } else {
                let session = PathIds.sessionId()
                lock.lock(); foundedSession = session; lock.unlock()
                connection.sendJSON(Self.welcomeJSON(session: session))
            }
        }
        let record = PinnedPhoneV2(deviceId: "phone-1",
                                   phoneFingerprintHex: server.phoneFingerprintHex,
                                   certPem: phoneIdentity.certPem)
        let endpoint = Session.Endpoint.hostPort(host: "127.0.0.1", port: server.port)
        let session = Session(endpoint: endpoint, endpoints: [endpoint, endpoint],
                              knownDeviceId: "phone-1", clientId: "test-client",
                              identity: macIdentity.identity, pinnedPhone: record)
        session.pairingPolicy = .never
        session.start()
        XCTAssertTrue(waitFor { session.state == .ready }, "never ready: \(session.state)")
        let answered = waitFor {
            lock.lock(); defer { lock.unlock() }
            return joinPath.map(pongs.contains) ?? false
        }
        lock.lock(); let path = joinPath; lock.unlock()
        XCTAssertTrue(answered, "no path.pong for the joining path \(path ?? "?") (pongs: \(pongs))")
        session.closeAndWait()
    }

    private static func welcomeJSON(session: String) -> [String: Any] {
        ["t": "welcome", "session": session,
         "device": ["id": "phone-1", "name": "Pixel", "model": "Pixel", "sdk": 36,
                    "screen": ["w": 1080, "h": 2340, "dpi": 450], "locked": true]]
    }

    private func assertFirstPingAnswered(combined: Bool) throws {
        server = try FakeServer(phoneIdentity: phoneIdentity, trustingClientPem: macIdentity.identity.certPem)
        let lock = NSLock()
        var pongs: [String] = []
        var welcomedPath: String?
        server.onRawFrame = { _, frame in
            guard frame.type == MessageType.json.rawValue,
                  let message = JSONFrame.decode(payload: frame.payload),
                  message.t == "path.pong", let path = message.string("path") else { return }
            lock.lock(); pongs.append(path); lock.unlock()
        }
        server.onFrame = { connection, frame in
            guard frame.type == MessageType.json.rawValue,
                  let message = JSONFrame.decode(payload: frame.payload),
                  message.t == "hello", let path = message.string("path") else { return }
            lock.lock(); welcomedPath = path; lock.unlock()
            let welcome = Frame(type: MessageType.json.rawValue, stream: 0, payload: JSONFrame.payload([
                "t": "welcome", "session": PathIds.sessionId(),
                "device": ["id": "phone-1", "name": "Pixel", "model": "Pixel", "sdk": 36,
                           "screen": ["w": 1080, "h": 2340, "dpi": 450], "locked": true],
            ]))
            let ping = Frame(type: MessageType.json.rawValue, stream: 0, payload: JSONFrame.payload([
                "t": "path.ping", "path": path, "ts": 1,
            ]))
            if combined {
                let bytes = welcome.encoded + ping.encoded
                var buffer = connection.channel.allocator.buffer(capacity: bytes.count)
                buffer.writeBytes(bytes)
                connection.channel.writeAndFlush(buffer, promise: nil)
            } else {
                connection.send(welcome)
                connection.send(ping)
            }
        }
        let session = makeSession(port: server.port)
        session.start()
        XCTAssertTrue(waitFor { session.state == .ready }, "never ready: \(session.state)")
        lock.lock(); let path = welcomedPath; lock.unlock()
        let answered = waitFor {
            lock.lock(); defer { lock.unlock() }
            return path.map(pongs.contains) ?? false
        }
        XCTAssertTrue(answered, "no path.pong for \(path ?? "?") (pongs: \(pongs))")
        session.close()
    }
}
