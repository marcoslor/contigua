// PATH-2/PATH-15: sends may come from the UI (main), the video queue or a
// background producer while the session is still connecting. Nothing off the
// session queue may read the session's own attempt state (P1 review R-7).
//
// Run under Thread Sanitizer:
//   swift test --sanitize=thread --filter SessionConcurrencyTests

import CryptoKit
import XCTest
@testable import Contigua

final class SessionConcurrencyTests: XCTestCase {
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

    /// Two threads hammer input and JSON while the session dials, installs the
    /// channel, sends its hello and takes the welcome: the whole window where
    /// `attempts` used to be read off the session queue.
    func testSendsFromTwoThreadsWhileConnectingAreSafe() throws {
        server = try FakeServer(phoneIdentity: phoneIdentity, trustingClientPem: macIdentity.identity.certPem)
        let lock = NSLock()
        var welcomed = 0
        server.onFrame = { connection, frame in
            guard frame.type == MessageType.json.rawValue,
                  let message = JSONFrame.decode(payload: frame.payload),
                  message.t == "hello" else { return }
            lock.lock(); welcomed += 1; lock.unlock()
            connection.sendJSON(["t": "welcome", "session": PathIds.sessionId(), "device": [
                "id": "phone-1", "name": "Pixel", "model": "Pixel", "sdk": 36,
                "screen": ["w": 1080, "h": 2340, "dpi": 450], "locked": true]])
        }
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: server.port),
                              knownDeviceId: nil, clientId: "test-client",
                              identity: macIdentity.identity, connectTimeout: 4, pairingTimeout: 20)
        session.pairingPolicy = .allowed

        let stop = NSLock()
        var running = true
        func stillRunning() -> Bool { stop.lock(); defer { stop.unlock() }; return running }
        func stopNow() { stop.lock(); running = false; stop.unlock() }

        let background = DispatchQueue(label: "test.sender")
        background.async {
            var n = 0
            while stillRunning() {
                session.sendJSON(["t": "noop", "n": n])
                session.touch(TouchEvent(action: .move, nx: 0.5, ny: 0.5), stream: 1)
                n += 1
                Thread.sleep(forTimeInterval: 0.001)  // real-time: a person's typing rate, over the connect window
            }
        }
        session.start()
        let deadline = Date().addingTimeInterval(1.5)
        var n = 0
        while Date() < deadline {
            session.key(KeyEvent(action: 0, keycode: UInt32(29 + n % 20)), stream: 1)
            session.sendBytes([1, 2, 3, 4, 5, 6, 7, 8, 9])
            n += 1
            Thread.sleep(forTimeInterval: 0.001)  // real-time: a person's typing rate, over the connect window
        }
        stopNow()
        XCTAssertTrue(waitFor { session.state == .ready }, "never ready: \(session.state)")
        session.closeAndWait()
    }
}
