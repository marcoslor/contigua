// A loopback "phone" for the session tests: a TLS 1.3 server presenting its
// own v2 identity and trusting exactly one Mac client certificate, speaking
// the framed protocol. `FakeV2PhoneBrain` scripts the §4 pairing machine by
// the book (commit/nonce/reveal, real exporter and fingerprints) so the Mac's
// verification and code derivation run against a peer that behaves like the
// design says a phone behaves — v2, mutual TLS, no plaintext anywhere.

import CryptoKit
import NIOTLS
import Foundation
import NIO
import NIOSSL
import XCTest
@testable import PocketDeck

final class FakeServer {
    final class Connection: @unchecked Sendable, Equatable {
        let id: Int
        let channel: Channel
        let capture: KeyLogCapture
        /// The Mac client cert's point fingerprint: this fake phone trusts
        /// exactly one client cert, so the peer's fingerprint is known (and
        /// verified by TLS) before any frame moves.
        let macFingerprintHex: String

        init(id: Int, channel: Channel, capture: KeyLogCapture, macFingerprintHex: String) {
            self.id = id
            self.channel = channel
            self.capture = capture
            self.macFingerprintHex = macFingerprintHex
        }

        static func == (lhs: Connection, rhs: Connection) -> Bool { lhs.id == rhs.id }

        /// PATH-3: the welcome names this fake session; a join echoes it.
        let sessionId = PathIds.sessionId()

        /// The connection's exporter, nil before the handshake completed.
        func exporter() -> [UInt8]? {
            guard let secret = capture.only else { return nil }
            return ExporterV2.derive(exporterSecret: secret)
        }

        func send(_ frame: Frame) {
            var buffer = channel.allocator.buffer(capacity: frame.encoded.count)
            buffer.writeBytes(frame.encoded)
            _ = channel.writeAndFlush(buffer)
        }

        func sendJSON(_ object: [String: Any]) {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            send(Frame(type: .json, stream: 0, payload: [UInt8](data)))
        }

        func close() { channel.close(promise: nil) }
    }

    /// Learns nothing at runtime: the trusted client cert IS the Mac's, so the
    /// fingerprint is fixed at connect time.
    private let macFingerprintHex: String

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    private let lock = NSLock()
    private var nextId = 0
    private(set) var accepted: [Connection] = []
    private var serverChannel: Channel?
    let phoneIdentity: DeviceIdentityV2
    /// The one trusted Mac client certificate (PEM).
    private let clientPem: String
    private var stopped = false

    var onFrame: ((Connection, Frame) -> Void)?
    /// Every frame as it arrived, before the reliable unwrap (path tests).
    var onRawFrame: ((Connection, Frame) -> Void)?
    var onClosed: ((Connection) -> Void)?

    /// The scripted phone brain; when set, frames go to it first and only
    /// unhandled ones reach the test's raw `onFrame`.
    var brain: FakeV2PhoneBrain?

    init(phoneIdentity: DeviceIdentityV2? = nil, trustingClientPem: String) throws {
        self.phoneIdentity = phoneIdentity ?? IdentityGeneratorV2.make(
            deviceId: "phone-\(Int.random(in: 1...999))", cn: "PocketDeck Fake Phone").identity
        self.clientPem = trustingClientPem
        let cert = try NIOSSLCertificate(bytes: [UInt8](trustingClientPem.utf8), format: .pem)
        guard let fp = PinCheckV2.pointFingerprint(cert: cert) else {
            struct BadCert: Error {}
            throw BadCert()
        }
        self.macFingerprintHex = Data(fp).hexString
        try startListener()
    }

    var port: UInt16 { serverChannel?.localAddress?.port.map(UInt16.init) ?? 0 }
    var phoneFingerprintHex: String { FakeV2PhoneBrain(identity: phoneIdentity, deviceId: "x").phoneFingerprintHex }

    func stop() {
        lock.lock(); let already = stopped; stopped = true; lock.unlock()
        guard !already else { return }
        serverChannel?.close(promise: nil)
        for connection in snapshotAccepted() { connection.channel.close(promise: nil) }
        try? group.syncShutdownGracefully()
    }

    private func snapshotAccepted() -> [Connection] {
        lock.lock(); defer { lock.unlock() }
        return accepted
    }

    private func startListener() throws {
        let trusted = try NIOSSLCertificate(bytes: [UInt8](clientPem.utf8), format: .pem)
        let phoneCert = try NIOSSLCertificate(bytes: [UInt8](phoneIdentity.certPem.utf8), format: .pem)
        let phoneKey = try NIOSSLPrivateKey(bytes: [UInt8](phoneIdentity.keyP8.utf8), format: .pem)
        let bootstrap = ServerBootstrap(group: group)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] ch -> EventLoopFuture<Void> in
                guard let self else { return ch.eventLoop.makeFailedFuture(Gone()) }
                do {
                    return try self.childPipeline(ch, phoneCert: phoneCert, phoneKey: phoneKey, trusted: trusted)
                } catch {
                    return ch.eventLoop.makeFailedFuture(error)
                }
            }
        serverChannel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
    }

    private final class Gone: Error {}

    private func childPipeline(_ ch: Channel, phoneCert: NIOSSLCertificate,
                               phoneKey: NIOSSLPrivateKey, trusted: NIOSSLCertificate) throws -> EventLoopFuture<Void> {
        // One context per connection (what the phone does too): no session
        // tickets, no resumption state to replay (R3). The per-connection
        // keylog capture gives the fake phone its own exporter view.
        var tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(phoneCert)],
            privateKey: .privateKey(phoneKey))
        tls.minimumTLSVersion = .tlsv13
        tls.maximumTLSVersion = .tlsv13
        tls.trustRoots = .certificates([trusted])
        tls.certificateVerification = .fullVerification
        let capture = KeyLogCapture()
        tls.keyLogCallback = { buffer in
            var copy = buffer
            if let line = copy.readString(length: copy.readableBytes) { capture.note(line) }
        }
        let context = try NIOSSLContext(configuration: tls)
        lock.lock()
        let id = nextId
        nextId += 1
        lock.unlock()
        let connection = Connection(id: id, channel: ch, capture: capture, macFingerprintHex: macFingerprintHex)
        try ch.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))

        let server = self
        try ch.pipeline.syncOperations.addHandler(FrameDeliveryHandler(
            onFrame: { frame in server.onConnectionFrame(connection, frame) },
            onError: { _ in }))
        lock.lock()
        accepted.append(connection)
        lock.unlock()
        ch.closeFuture.whenComplete { [weak self, weak connection] _ in
            guard let self, let connection else { return }
            self.lock.lock()
            self.accepted.removeAll { $0 === connection }
            self.lock.unlock()
            let closed = self.onClosed
            DispatchQueue.global().async { closed?(connection) }
        }
        return ch.eventLoop.makeSucceededVoidFuture()
    }

    private func onConnectionFrame(_ connection: Connection, _ frame: Frame) {
        onRawFrame?(connection, frame)
        // A protocol-4 Mac wraps reliable frames and pings each path bare.
        if frame.type == PathCodec.reliableType {
            guard let reliable = try? PathCodec.decodeReliable(frame) else { return }
            connection.send(PathCodec.encodeAck(reliable.seq + 1))
            dispatch(connection, reliable.inner)
            return
        }
        if frame.type == PathCodec.ackType { return }
        dispatch(connection, frame)
    }

    private func dispatch(_ connection: Connection, _ frame: Frame) {
        if frame.type == MessageType.json.rawValue,
           let message = JSONFrame.decode(payload: frame.payload), message.t == "path.ping" {
            connection.sendJSON(["t": "path.pong", "path": message.string("path") ?? "",
                                 "ts": message.int("ts") ?? 0])
            return
        }
        if let brain, brain.handle(connection: connection, frame: frame) { return }
        onFrame?(connection, frame)
    }
}

/// The scripted v2 phone: answers `pair.request` with a real `pair.commit`,
/// reveals on `pair.nonce`, derives its own §4 code, then on Allow sends
/// `pair.ok` (what each side pins) and `welcome`. Only the frames it handles
/// count as done; tests may also answer by hand.
final class FakeV2PhoneBrain {
    let identity: DeviceIdentityV2
    let deviceId: String
    /// The fake phone's device name in `welcome`.
    var name = "Pixel"
    /// Person behavior: nil = the test taps Allow by hand (`allow(on:)`);
    /// true/false = sent immediately after the reveal.
    var allow: Bool?
    var autoAllow = false
    /// When true the phone answers `hello` with `welcome` right away: the
    /// reconnect path where the phone already knows the clientId.
    var welcomeOnHello = false
    /// R2: what the phone "scanned": the one-time secret + the pinned Mac
    /// fingerprint (the fake phone proves the scan with pair.qr).
    var scannedSecret: Data?
    var scannedMacFpHex: String?
    /// When set, the phone's answer to `pair.request`/`pair.nonce` is this
    /// error instead (pair_denied / pair_timeout shapes).
    var error: String?
    /// The test wants a MITM-shaped commit mismatch (`pair_commit` on the Mac).
    var badCommit = false

    private let lock = NSLock()
    private var npByConnection: [Int: Data] = [:]
    private var codeByConnection: [Int: Int] = [:]
    private var pairRequestsSeen = 0
    var sawPairRequest: Bool { lock.lock(); defer { lock.unlock() }; return pairRequestsSeen > 0 }

    init(identity: DeviceIdentityV2, deviceId: String) {
        self.identity = identity
        self.deviceId = deviceId
    }

    var phoneFingerprintHex: String {
        guard let cert = try? NIOSSLCertificate(bytes: [UInt8](self.identity.certPem.utf8), format: .pem),
              let fp = PinCheckV2.pointFingerprint(cert: cert) else { return "" }
        return Data(fp).hexString
    }

    /// The §4 code the phone derived for the (single) connection, if any.
    var lastCode: Int? {
        lock.lock(); defer { lock.unlock() }
        return codeByConnection.values.first
    }

    /// The Np this connection committed to (diagnostics only; never logged).
    func committedNp(connection: FakeServer.Connection) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return npByConnection[connection.id]
    }

    /// Handles the frame; returns true when the brain owned it.
    func handle(connection: FakeServer.Connection, frame: Frame) -> Bool {
        guard frame.messageType == .json, let message = JSONFrame.decode(payload: frame.payload) else { return false }
        if let errorCode = error {
            if ["pair.request", "pair.nonce"].contains(message.t) {
                connection.sendJSON(["t": "error", "code": errorCode])
                return true
            }
            return false
        }
        switch message.t {
        case "hello":
            if let secret = scannedSecret {
                // The phone scanned THIS Mac's QR: pin by fingerprint, prove S.
                guard let expectedMacFp = scannedMacFpHex,
                      expectedMacFp == connection.macFingerprintHex else {
                    connection.sendJSON(["t": "error", "code": "pair_qr", "message": "wrong mac"])
                    return true
                }
                let exporter = connection.exporter() ?? []
                let hmac = PairingCodeV2.qrHmac(secret: secret,
                                                exporter: Data(exporter),
                                                phoneFp: Data(hexString: phoneFingerprintHex) ?? Data())
                connection.sendJSON(["t": "pair.qr", "m": PairingCodeV2.hex(hmac)])
                return true
            }
            if self.welcomeOnHello {
                connection.sendJSON(["t": "welcome", "session": connection.sessionId, "device": [
                    "id": self.deviceId, "name": self.name, "model": "Pixel", "sdk": 36,
                    "screen": ["w": 1080, "h": 2340, "dpi": 450], "locked": true]])
                return true
            }
            return false
        case "pair.ok":
            if scannedSecret != nil {
                // The Mac accepted the scan proof; the person allows (auto or
                // kept for the test), then the phone acks and welcomes.
                if self.allow ?? self.autoAllow {
                    connection.sendJSON(["t": "pair.ok"])
                    connection.sendJSON(["t": "welcome", "session": connection.sessionId, "device": [
                        "id": self.deviceId, "name": self.name, "model": "Pixel", "sdk": 36,
                        "screen": ["w": 1080, "h": 2340, "dpi": 450], "locked": true]])
                }
                return true
            }
            return false
        case "pair.request":
            let np = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            self.lock.lock()
            self.pairRequestsSeen += 1
            self.npByConnection[connection.id] = np
            self.lock.unlock()
            connection.sendJSON(["t": "pair.commit", "c": commitHex(np: np, connection: connection)])
            return true
        case "pair.nonce":
            guard let npHex = message.string("n"), let nm = Data(hexString: npHex), nm.count == 16,
                  let np = committedNp(connection: connection) else {
                connection.sendJSON(["t": "error", "code": "pair_commit", "message": "bad nonce"])
                return true
            }
            connection.sendJSON(["t": "pair.reveal", "n": np.hexString])
            let exporter = connection.exporter() ?? []
            let code = PairingCodeV2.code(exporter: Data(exporter),
                                          macFp: Data(hexString: connection.macFingerprintHex) ?? Data(),
                                          phoneFp: Data(hexString: phoneFingerprintHex) ?? Data(),
                                          Nm: nm, Np: np)
            self.lock.lock()
            self.codeByConnection[connection.id] = code
            self.lock.unlock()
            let answer = self.allow ?? self.autoAllow
            if answer == true {
                self.allow(connection)
            }
            return true
        default:
            return false
        }
    }

    private func commitHex(np: Data, connection: FakeServer.Connection) -> String {
        let macFp = Data(hexString: connection.macFingerprintHex) ?? Data()
        let phoneFp = Data(hexString: phoneFingerprintHex) ?? Data()
        if self.badCommit {
            // A commitment over materials that cannot match the reveal: the
            // Mac's rehash must catch it (§4 pair_commit).
            let wrong = PairingCodeV2.commit(Np: Data(count: 16), phoneFp: phoneFp, macFp: macFp)
            return PairingCodeV2.hex(wrong)
        }
        return PairingCodeV2.hex(PairingCodeV2.commit(Np: np, phoneFp: phoneFp, macFp: macFp))
    }

    /// Allow (the person tapped): pair.ok with both pins, then welcome.
    func allow(_ connection: FakeServer.Connection) {
        connection.sendJSON([
            "t": "pair.ok",
            "phoneFP": phoneFingerprintHex,
            "macFP": connection.macFingerprintHex,
        ])
        connection.sendJSON(["t": "welcome", "session": connection.sessionId, "device": [
            "id": deviceId, "name": name, "model": "Pixel", "sdk": 36,
            "screen": ["w": 1080, "h": 2340, "dpi": 450], "locked": true]])
    }
}
