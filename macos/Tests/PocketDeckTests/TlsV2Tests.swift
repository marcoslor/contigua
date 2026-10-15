// Tests for the v2 TLS transport (docs/design/e2ee.md §4b/§6, phase-2 step 3):
// exporter math vectors, keylog parsing, the pin gates, identity generation,
// and a loopback mutual-TLS 1.3 session with the exporter mirrored on both
// ends. The loopback server is in-process (spike harness style); the real
// profile storage and network devices are never touched.

import CryptoKit
import Foundation
import NIO
import NIOSSL
import XCTest
@testable import PocketDeck

final class TlsV2Tests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!

    override func setUp() {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    override func tearDown() {
        try! group.syncShutdownGracefully()
        super.tearDown()
    }

    // MARK: Exporter math (fixed vectors — the formula RFC 8446 §7.5)

    func testExporterVectors() {
        let zero = [UInt8](repeating: 0, count: 32)
        XCTAssertEqual(ExporterV2.derive(exporterSecret: zero).hexByteString,
                       "380c2602efd61000023783cb8280d36f3fb3a8c1b22a7d0e5247e6e227f3340c")
        let labeled = [UInt8](SHA256.hash(data: Data("pocketdeck-exporter-test-1".utf8)))
        XCTAssertEqual(ExporterV2.derive(exporterSecret: labeled).hexByteString,
                       "68544181667677211b2823d71b530f48800be1ab6e762a4612d2d4fe85312d80")
    }

    func testKeyLogLineParsing() {
        let random = String(repeating: "aa", count: 32)
        let secret = String(repeating: "bb", count: 32)
        XCTAssertEqual(ExporterV2.exporterSecret(fromKeyLog: "EXPORTER_SECRET \(random) \(secret)"),
                       [UInt8](repeating: 0xBB, count: 32))
        XCTAssertNil(ExporterV2.exporterSecret(fromKeyLog: "CLIENT_TRAFFIC_SECRET_0 \(random) \(secret)"))
        XCTAssertNil(ExporterV2.exporterSecret(fromKeyLog: "EXPORTER_SECRET only-two-parts"))
        XCTAssertNil(ExporterV2.exporterSecret(fromKeyLog: "EXPORTER_SECRET \(random) zzz"))
    }

    // MARK: Pin gates (nothing dials when the rules fail)

    /// §3 pin claims a phone but the store has no record: refuse pre-dial.
    func testPinWithoutStoreRecordRefuses() {
        let identity = DeviceIdentityV2(deviceId: "mac", certPem: "CERT", keyP8: "KEY",
                                        pin: String(repeating: "7a", count: 32))
        let connector = TlsConnectorV2(identity: identity, pinnedPhone: nil, group: group)
        do {
            _ = try connector.configuration()
            XCTFail("a §3 pin without a store record must refuse (§8 step 3)")
        } catch TlsV2Error.noPin {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// A store record whose cert's fingerprint disagrees with the §3 pin: a
    /// stale/corrupt pin store refuses instead of silently loosening TLS.
    func testStoreRecordWithWrongFingerprintRefuses() throws {
        let mac = IdentityGeneratorV2.make(deviceId: "mac")
        let otherPhone = IdentityGeneratorV2.make(deviceId: "phone-x", cn: "PocketDeck Phone X")
        let xCert = try NIOSSLCertificate(bytes: [UInt8](otherPhone.identity.certPem.utf8), format: .pem)
        let record = PinnedPhoneV2(deviceId: "phone-a",
                                   phoneFingerprintHex: Data(PinCheckV2.pointFingerprint(cert: xCert)!).hexString,
                                   certPem: otherPhone.identity.certPem)
        // The identity pins a DIFFERENT phone's fingerprint than the record's.
        let mismatched = DeviceIdentityV2(deviceId: mac.identity.deviceId,
                                          certPem: mac.identity.certPem,
                                          keyP8: mac.identity.keyP8,
                                          pin: String(repeating: "3b", count: 32))
        let connector = TlsConnectorV2(identity: mismatched, pinnedPhone: record, group: group)
        do {
            _ = try connector.configuration()
            XCTFail("store/identity disagreement must refuse")
        } catch TlsV2Error.pinMismatch {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: Identity generation

    func testIdentityGenerationRoundParses() throws {
        let generated = IdentityGeneratorV2.make(deviceId: "mac-unit-1")
        XCTAssertEqual(generated.identity.deviceId, "mac-unit-1")
        XCTAssertEqual(generated.identity.pinVersion, 2)
        XCTAssertTrue(generated.identity.pin.isEmpty, "the pin is set at pairing, not at generation")
        let cert = try NIOSSLCertificate(bytes: [UInt8](generated.identity.certPem.utf8), format: .pem)
        let ownFingerprint = Data(PinCheckV2.pointFingerprint(cert: cert)!).hexString
        XCTAssertEqual(ownFingerprint, PointFingerprint.hex(ofKey: generated.privateKey.publicKey))
        // The TLS stack reads the private key back from the stored PEM.
        _ = try NIOSSLPrivateKey(bytes: [UInt8](generated.identity.keyP8.utf8), format: .pem)
    }

    func testTlsConfigurationIs13Only() throws {
        let generated = IdentityGeneratorV2.make(deviceId: "mac-unit-1")
        let connector = TlsConnectorV2(identity: generated.identity, pinnedPhone: nil, group: group)
        let config = try connector.configuration()
        XCTAssertEqual(config.minimumTLSVersion, .tlsv13)
        XCTAssertEqual(config.maximumTLSVersion, .tlsv13)
    }

    // MARK: Loopback mutual TLS

    /// An in-process "phone" TLS server echoing one frame back: TLS 1.3, client
    /// auth required, trusting exactly one client certificate (the spike-
    /// proven trustRoots route). A different Mac's cert fails the chain check,
    /// semantically a pin mismatch. The REAL phone-side pin enforcement is
    /// Android work (steps 5/9/K4).
    private func loopbackServer(trusting clientCert: NIOSSLCertificate?,
                                phoneMaterial: (identity: DeviceIdentityV2, privateKey: P256.Signing.PrivateKey)? = nil) throws -> (port: Int, capture: KeyLogCapture, channel: Channel, phoneFingerprint: String, phoneIdentity: DeviceIdentityV2, phoneKey: P256.Signing.PrivateKey) {
        let material = phoneMaterial ?? IdentityGeneratorV2.make(deviceId: "phone-unit-1", cn: "PocketDeck Phone")
        let phoneCert = try NIOSSLCertificate(bytes: [UInt8](material.identity.certPem.utf8), format: .pem)
        let phoneKey = try NIOSSLPrivateKey(bytes: [UInt8](material.identity.keyP8.utf8), format: .pem)
        let trusted: NIOSSLCertificate
        if let clientCert {
            trusted = clientCert
        } else {
            let stranger = IdentityGeneratorV2.make(deviceId: "not-the-client-mac")
            trusted = try NIOSSLCertificate(bytes: [UInt8](stranger.identity.certPem.utf8), format: .pem)
        }
        var tls = TLSConfiguration.makeServerConfiguration(certificateChain: [.certificate(phoneCert)],
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
        let server = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch -> EventLoopFuture<Void> in
                do {
                    try ch.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                    try ch.pipeline.syncOperations.addHandler(EchoFramesHandler())
                    return ch.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return ch.eventLoop.makeFailedFuture(error)
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        let phoneFingerprint = Data(PinCheckV2.pointFingerprint(cert: phoneCert)!).hexString
        return (server.localAddress!.port!, capture, server, phoneFingerprint, material.identity, material.privateKey)
    }

    private final class EchoFramesHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            context.writeAndFlush(wrapOutboundOut(unwrapInboundIn(data)), promise: nil)
        }
    }

    private func cert(_ identity: DeviceIdentityV2) throws -> NIOSSLCertificate {
        try NIOSSLCertificate(bytes: [UInt8](identity.certPem.utf8), format: .pem)
    }

    func testLoopbackHandshakePinsAndExportsIdentically() throws {
        let mac = IdentityGeneratorV2.make(deviceId: "mac-unit-2")
        let phone = try loopbackServer(trusting: try cert(mac.identity))
        defer { phone.channel.close(promise: nil) }

        // Pairing mode: no pin yet; the connector LEARNS the phone's
        // fingerprint through the handshake-completed event.
        let connector = TlsConnectorV2(identity: mac.identity, pinnedPhone: nil, group: group)
        let learnedPin = NSLockedBox(value: "")
        let frameBox = NSLockedBox<Frame?>(value: nil)
        let errorBox = NSLockedBox(value: "")
        let gotFrame = DispatchSemaphore(value: 0)
        let session = try connector.connect(host: "127.0.0.1", port: phone.port,
                                            onFrame: { frame in
            frameBox.set(frame)
            gotFrame.signal()
        }, onError: { errorBox.set($0) }, onPeerPin: { learnedPin.set($0) })
        defer { session.channel.close(promise: nil) }

        // The handshake completes and the exporter materializes.
        let exporterClient = waitForOptional { session.exporter() }
        XCTAssertNotNil(exporterClient, "handshake never completed; error=\(errorBox.get()) learned=\(learnedPin.get())")
        XCTAssertEqual(exporterClient!.count, 32)

        // Pairing mode learned THE phone's fingerprint.
        let learned = waitFor { learnedPin.get().count == 64 ? learnedPin.get() : nil }
        XCTAssertEqual(learned, phone.phoneFingerprint)

        // Framing unchanged: the mock phone echoes our frame byte for byte.
        session.send(Frame(type: MessageType.json, stream: 0, payload: Array("ping".utf8)))
        XCTAssertTrue(waitForSignal(gotFrame, seconds: 5), "no echoed frame")
        XCTAssertEqual(frameBox.get()?.type, MessageType.json.rawValue)
        XCTAssertEqual(frameBox.get()?.payload, Array("ping".utf8))

        // Same session, same 32 bytes on both ends (the §4b/S1-S2 property).
        XCTAssertEqual(session.exporter(), ExporterV2.derive(exporterSecret: phone.capture.only ?? []))
    }

    func testEnforcedReconnectUsesThePinnedPhoneRecord() throws {
        // Same server listener, same phone identity reused; the pairing
        // session learns the pin, the reconnect session verifies against the
        // store record — and each handshake is a FULL one (R3: no resumption).
        let mac = IdentityGeneratorV2.make(deviceId: "mac-unit-5")
        let phoneMaterial = IdentityGeneratorV2.make(deviceId: "phone-unit-1", cn: "PocketDeck Phone")
        let server = try loopbackServer(trusting: try cert(mac.identity), phoneMaterial: phoneMaterial)
        defer { server.channel.close(promise: nil) }

        // 1) pairing session: learn the phone's fingerprint.
        let pairing = TlsConnectorV2(identity: mac.identity, pinnedPhone: nil, group: group)
        let learnedPin = NSLockedBox(value: "")
        let pairingSession = try pairing.connect(host: "127.0.0.1", port: server.port,
                                                 onFrame: { _ in }, onError: { _ in },
                                                 onPeerPin: { learnedPin.set($0) })
        defer { pairingSession.channel.close(promise: nil) }
        let learned = waitFor { learnedPin.get().count == 64 ? learnedPin.get() : nil }
        XCTAssertEqual(learned, server.phoneFingerprint)
        let exporterPairing = waitForOptional { pairingSession.exporter() }
        XCTAssertNotNil(exporterPairing, "pairing handshake did not complete")
        pairingSession.channel.close(promise: nil)
        Thread.sleep(forTimeInterval: 0.2)
        Thread.sleep(forTimeInterval: 0.2)
        server.capture.reset()

        // 2) reconnect with the store record: standard trust-roots chain vs
        // the pinned phone cert (the review's wording: the pin store feeds
        // trustRoots per phone).
        let record = PinnedPhoneV2(deviceId: phoneMaterial.identity.deviceId,
                                   phoneFingerprintHex: server.phoneFingerprint,
                                   certPem: phoneMaterial.identity.certPem)
        let store = PhonePinStoreV2()
        store.store(record)
        XCTAssertEqual(store.record(for: record.deviceId), record)
        let pinnedMac = DeviceIdentityV2(deviceId: mac.identity.deviceId,
                                         certPem: mac.identity.certPem,
                                         keyP8: mac.identity.keyP8,
                                         pin: server.phoneFingerprint)
        let reconnect = TlsConnectorV2(identity: pinnedMac,
                                       pinnedPhone: store.record(for: record.deviceId), group: group)
        let reconnectLearned = NSLockedBox(value: "")
        let reconnectSession = try reconnect.connect(host: "127.0.0.1", port: server.port,
                                                     onFrame: { _ in }, onError: { _ in },
                                                     onPeerPin: { reconnectLearned.set($0) })
        defer { reconnectSession.channel.close(promise: nil) }
        let exporterReconnect = waitForOptional { reconnectSession.exporter() }
        XCTAssertNotNil(exporterReconnect, "pinned reconnect must complete")
        // Fresh-full-handshake property (R3): different session ⇒ different
        // exporter bytes (a resumed session would re-derive the same ones).
        XCTAssertNotEqual(exporterReconnect, exporterPairing)
        XCTAssertEqual(exporterReconnect, ExporterV2.derive(exporterSecret: server.capture.only ?? []))
        XCTAssertEqual(reconnectLearned.get(), pinnedMac.pin)
    }

    func testServerRefusesUnknownClientFingerprint() throws {
        // Enforced on the phone side: the phone only knows THIS Mac yet.
        let server = try loopbackServer(trusting: nil)
        defer { server.channel.close(promise: nil) }
        let mac = IdentityGeneratorV2.make(deviceId: "mac-unit-4")
        let connector = TlsConnectorV2(identity: mac.identity, pinnedPhone: nil, group: group)
        let refused = DispatchSemaphore(value: 0)
        let message = NSLockedBox(value: "")
        _ = try? connector.connect(host: "127.0.0.1", port: server.port,
                                   onFrame: { _ in }, onError: { error in
            message.set(error)
            refused.signal()
        }, onPeerPin: { _ in })
        XCTAssertTrue(waitForSignal(refused, seconds: 10))
        XCTAssertTrue(message.get().contains("sslError") || message.get().contains("certificate") || message.get().contains("UNKNOWN_CA") || message.get().contains("closed-by-peer"),
                      "a rejected client cert surfaces as a TLS error or a hangup, not silence: \(message.get())")
    }

    private func waitFor(_ what: () -> String?) -> String? {
        return waitForOptional(what)
    }

    private func waitForOptional<T>(_ what: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let value = what() { return value }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return what()
    }

    private func waitForSignal(_ semaphore: DispatchSemaphore, seconds: Int) -> Bool {
        semaphore.wait(timeout: .now() + Double(seconds)) == .success
    }
}

// MARK: bisect removed
extension Array where Element == UInt8 {
    var hexByteString: String { map { String(format: "%02x", $0) }.joined() }
}

final class NSLockedBox<T> {
    private let lock = NSLock()
    private var underlying: T
    init(value: T) { underlying = value }
    func set(_ newValue: T) {
        lock.lock(); underlying = newValue; lock.unlock()
    }
    func get() -> T {
        lock.lock(); defer { lock.unlock() }
        return underlying
    }
}
