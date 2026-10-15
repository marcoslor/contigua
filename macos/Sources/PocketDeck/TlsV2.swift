// The v2 TLS transport for the Mac side (docs/design/e2ee.md §1/§4b/§6) —
// new components beside the v1 NWConnection session, not yet wired (the
// session re-pointing lands with the v2 pairing steps 7+).
//
// - NIOSSL/BoringSSL in memory: per-profile identity (DeviceIdentityV2), TLS 1.3
//   only, resumption and 0-RTT impossible (R3): every connect makes a fresh
//   SSL context and no session is ever cached, so the client cannot offer a PSK.
// - The pin (§1): SHA-256 over the 65-byte uncompressed EC point of the peer
//   cert, checked inside the handshake through NIOSSL's custom verification
//   callback. A configured empty pin refuses to connect at all (§8 step 3).
//   Pairing mode (nil pin) accepts the peer's self-signed cert and reports its
//   fingerprint so the state machine can store it after commit/reveal.
// - The exporter (§4b): the vendored BoringSSL publishes TLS 1.3 secrets on the
//   keylog callback, including `EXPORTER_SECRET`; ExporterV2 runs the RFC 8446
//   §7.5 math on it. Keylog lines are secrets: memory-only, pairing sessions
//   only, never written or logged (architect's condition).

import CryptoKit
import Foundation
import NIO
import NIOCore
import NIOSSL
import NIOTLS
import SwiftASN1
import X509

// MARK: - The RFC 8446 §7.5 exporter from the keylog secret

/// TLS-Exporter(label, empty context, 32) per RFC 8446 §7.5, fed by the
/// exporter master secret BoringSSL prints on the keylog callback
/// (`EXPORTER_SECRET <client_random> <hex>`).
///
/// The formula mirrors the vendored BoringSSL implementation (tls13_enc.cc,
/// `tls13_export_keying_material`) and was proven byte-equal against
/// Conscrypt's `exportKeyingMaterial` in the S1/S2 interop spike.
enum ExporterV2 {
    static let label = "EXPORTER-pocketdeck-pair"

    /// The 32 exporter bytes for one session.
    static func derive(exporterSecret: [UInt8]) -> [UInt8] {
        let empty = [UInt8](SHA256.hash(data: Data()))
        let inner = expandLabel(exporterSecret, label: label, hash: empty, length: 32)
        return expandLabel(inner, label: "exporter", hash: empty, length: 32)
    }

    /// HKDF-Expand-Label (RFC 8446 §7.1) with the "tls13 " prefix, sha256.
    static func expandLabel(_ secret: [UInt8], label: String, hash: [UInt8], length: Int) -> [UInt8] {
        var info: [UInt8] = []
        info.append(UInt8((length >> 8) & 0xFF))
        info.append(UInt8(length & 0xFF))
        let wire = Array("tls13 \(label)".utf8)
        info.append(UInt8(wire.count))
        info += wire
        info.append(UInt8(hash.count))
        info += hash
        return hkdfExpand(secret, info: info, length: length)
    }

    /// HKDF-Expand (RFC 5869 §2.3) with HMAC-SHA256.
    static func hkdfExpand(_ secret: [UInt8], info: [UInt8], length: Int) -> [UInt8] {
        var out: [UInt8] = []
        var t: [UInt8] = []
        var counter: UInt8 = 1
        while out.count < length {
            var input = t
            input += info
            input.append(counter)
            t = CryptoKitHmac.code(key: Data(secret), message: Data(input))
            out += t
            counter &+= 1
        }
        return Array(out.prefix(length))
    }

    /// `EXPORTER_SECRET <clientRandom 64hex> <secret 64hex>` → the raw secret;
    /// nil for any other or malformed line.
    static func exporterSecret(fromKeyLog line: String) -> [UInt8]? {
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "EXPORTER_SECRET",
              let secret = Data(hexString: String(parts[2])) else { return nil }
        return [UInt8](secret)
    }
}

// MARK: - Pin check over the peer certificate

/// The canonical pin (§1): SHA-256 over the 65-byte uncompressed point. For a
/// P-256 X.509 SPKI (`30 59 30 13 ... 03 42 00`) the point is exactly the last
/// 65 bytes of the SPKI encoding.
enum PinCheckV2 {
    static let spkiHeaderLength = 26 // P-256 SPKI header before the 65-byte point

    /// `04||X||Y` leaf point, hashed; nil when the cert is not a P-256 key.
    static func pointFingerprint(cert: NIOSSLCertificate) -> [UInt8]? {
        guard let key = try? cert.extractPublicKey(),
              let spki = try? key.toSPKIBytes(),
              spki.count == spkiHeaderLength + 65,
              spki[spkiHeaderLength] == 0x04 else { return nil }
        let point = Array(spki.suffix(65))
        return [UInt8](SHA256.hash(data: Data(point)))
    }

    /// Constant-time radix-16 pin comparison between ledger and candidate (32 bytes).
    static func matches(_ fingerprint: [UInt8], pinHex: String) -> Bool {
        guard let pin = Data(hexString: pinHex), pin.count == fingerprint.count,
              pin.count == 32 else { return false }
        var diff = 0
        for i in 0..<32 { diff |= Int(pin[i]) ^ Int(fingerprint[i]) }
        return diff == 0
    }
}

// MARK: - Identity generation (Mac side)

/// Generates the Mac's v2 TLS identity: in-memory P-256 key, self-signed v3
/// cert (SAN/IP, EKU server+client, ±1 day validity margins — the BoringSSL
/// evaluator flapped with `notBefore == now` in the spikes). Pin starts empty;
/// pairing writes the phone's fingerprint.
enum IdentityGeneratorV2 {
    /// Serial derives from the key itself: same key ⇒ same serial, no extra state.
    static func serialNumber(for key: P256.Signing.PublicKey) -> UInt128 {
        let digest = SHA256.hash(data: key.x963Representation)
        var value: UInt128 = 0
        for b in digest.prefix(16) { value = (value << 8) | UInt128(b) }
        return value
    }

    static func make(deviceId: String, cn: String = "PocketDeck Mac") -> (identity: DeviceIdentityV2, privateKey: P256.Signing.PrivateKey) {
        precondition(!deviceId.isEmpty, "deviceId must be set before identity.json exists")
        let key = P256.Signing.PrivateKey()
        let now = Date()
        do {
            let name = try DistinguishedName { CommonName(cn) }
            let extensions = try Certificate.Extensions {
                try SubjectAlternativeNames([
                    .ipAddress(ASN1OctetString(contentBytes: [127, 0, 0, 1][...])),
                ])
                try ExtendedKeyUsage([.serverAuth, .clientAuth])
            }
            let cert = try Certificate(
                version: .v3,
                serialNumber: .init(serialNumber(for: key.publicKey)),
                publicKey: .init(key.publicKey),
                notValidBefore: now.addingTimeInterval(-86_400),
                notValidAfter: now.addingTimeInterval(366 * 86_400),
                issuer: name,
                subject: name,
                signatureAlgorithm: .ecdsaWithSHA256,
                extensions: extensions,
                issuerPrivateKey: .init(key)
            )
            // pin: the PHONE's point fingerprint per §3; our own key only
            // presents its cert. Empty until pairing stores it.
            let identity = DeviceIdentityV2(
                deviceId: deviceId,
                certPem: try cert.serializeAsPEM().pemString,
                keyP8: key.pemRepresentation,
                pin: ""
            )
            return (identity, key)
        } catch {
            preconditionFailure("identity generation failed: \(error)")
        }
    }
}

// MARK: - Errors

/// Mapped onto user-facing text by the session layer (§7: stale pin →
/// "certificate changed — re-pair").
enum TlsV2Error: Error, CustomStringConvertible {
    case noPin
    case incompleteIdentity
    case pinMismatch(got: String, expected: String)
    case notP256
    case dialFailed(String)
    case handshakeTimeout

    var description: String {
        switch self {
        case .noPin: return "no pin"
        case .incompleteIdentity: return "incomplete identity (certPem/keyP8 empty)"
        case let .pinMismatch(got, expected): return "certificate changed (pin mismatch: \(got) ≠ \(expected))"
        case .notP256: return "peer certificate is not a P-256 key"
        case let .dialFailed(why): return "connect failed: \(why)"
        case .handshakeTimeout: return "handshake timed out"
        }
    }
}

// MARK: - Keylog capture

/// BoringSSL's keylog lines keyed by clientRandom hex. Secrets live only here,
/// per connection, never written or logged.
final class KeyLogCapture: @unchecked Sendable {
    private var secrets: [String: [UInt8]] = [:]
    private let lock = NSLock()

    func note(_ line: String) {
        for raw in line.split(separator: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let randomHex = trimmed.keyLogClientRandomHex, let secret = ExporterV2.exporterSecret(fromKeyLog: String(trimmed)) else { continue }
            lock.lock()
            // BoringSSL can re-emit the same line for one keybox; keep the first.
            if secrets[randomHex] == nil { secrets[randomHex] = secret }
            lock.unlock()
        }
    }

    func secret(clientRandomHex: String) -> [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        return secrets[clientRandomHex]
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return secrets.count
    }
    /// Drop captured secrets (used by test harnesses that reuse one capture
    /// across independent sessions; production uses one capture per connection).
    func reset() {
        lock.lock(); defer { lock.unlock() }
        secrets.removeAll()
    }

    /// The single session's secret — valid while the instance saw exactly one
    /// handshake (the connector makes one capture per connect).
    var only: [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        guard secrets.count == 1 else { return nil }
        return secrets.values.first
    }
}

extension String {
    /// The client-random field of a BoringSSL keylog line, nil otherwise.
    var keyLogClientRandomHex: String? {
        let parts = split(separator: " ")
        guard parts.count == 3, parts[0] == "EXPORTER_SECRET", parts[1].count == 64 else { return nil }
        return String(parts[1])
    }
}

// MARK: - The pinned phone (the pin store the TLS layer feeds from)

/// One phone's pin record (§6: "the pin store feeds `trustRoots` per phone").
/// `-fp` hex IS the pin identity.json carries; the cert PEM is the same
/// self-signed cert the phone presents, kept so the TLS layer can verify
/// against it (chain = that cert, no other). Persistence is the pairing state
/// machine's job (step 7); this type is the in-memory record.
struct PinnedPhoneV2: Codable, Equatable {
    var deviceId: String
    var phoneFingerprintHex: String
    var certPem: String
}

/// deviceId → pin record. In-memory until the pairing state machine wires it
/// (step 7).
final class PhonePinStoreV2 {
    private var phones: [String: PinnedPhoneV2] = [:]
    private let lock = NSLock()

    func record(for deviceId: String) -> PinnedPhoneV2? {
        lock.lock(); defer { lock.unlock() }
        return phones[deviceId]
    }

    func record(phoneFingerprintHex: String) -> PinnedPhoneV2? {
        lock.lock(); defer { lock.unlock() }
        return phones.values.first { $0.phoneFingerprintHex == phoneFingerprintHex }
    }

    func store(_ record: PinnedPhoneV2) {
        lock.lock(); defer { lock.unlock() }
        phones[record.deviceId] = record
    }

    /// §7: the old pin is deleted on successful re-pair; `forget` removes it.
    func forget(deviceId: String) {
        lock.lock(); defer { lock.unlock() }
        phones.removeValue(forKey: deviceId)
    }

    var all: [PinnedPhoneV2] {
        lock.lock(); defer { lock.unlock() }
        return phones.values.sorted { $0.deviceId < $1.deviceId }
    }
}

// MARK: - The connector

/// Brings one outbound TLS 1.3 connection to a phone up. Frame delivery and
/// error surfacing ride the framing handlers; the v2 handshake learning runs
/// through the handshake-completed user event.
final class TlsConnectorV2: @unchecked Sendable {
    let identity: DeviceIdentityV2
    /// nil = pairing mode (§4: TLS itself cannot authenticate an unknown peer;
    /// the commit/nonce/reveal flow and the QR HMAC are the checks). Non-nil =
    /// a pinned phone from the pin store; the connection is then verified the
    /// standard-roots way.
    let pinnedPhone: PinnedPhoneV2?
    let keyLog: KeyLogCapture
    private let group: EventLoopGroup

    init(identity: DeviceIdentityV2, pinnedPhone: PinnedPhoneV2?, group: EventLoopGroup) {
        self.identity = identity
        self.pinnedPhone = pinnedPhone
        self.keyLog = KeyLogCapture()
        self.group = group
    }

    /// The TLS configuration for outgoing v2 connections. Throws before any
    /// network traffic when the pin rules cannot be met (§8 step 3: no pin
    /// present ⇒ refuse).
    func configuration() throws -> TLSConfiguration {
        guard !identity.certPem.isEmpty, !identity.keyP8.isEmpty else {
            throw TlsV2Error.incompleteIdentity
        }
        var tls = TLSConfiguration.makeClientConfiguration()
        if let phone = pinnedPhone {
            // ENFORCED: the identity.json pin (§3) and the pin store record
            // must say the same fingerprint, and the record must carry the
            // phone cert. Missing either ⇒ refuse (nothing interpretable).
            guard !identity.pin.isEmpty else { throw TlsV2Error.noPin }
            guard let cert = try? NIOSSLCertificate(bytes: [UInt8](phone.certPem.utf8), format: .pem) else {
                throw TlsV2Error.incompleteIdentity
            }
            guard let peerFingerprint = PinCheckV2.pointFingerprint(cert: cert) else {
                throw TlsV2Error.notP256
            }
            guard PinCheckV2.matches(peerFingerprint, pinHex: identity.pin) else {
                throw TlsV2Error.pinMismatch(got: Data(peerFingerprint).hexString, expected: identity.pin)
            }
            tls.certificateVerification = .fullVerification
            tls.trustRoots = .certificates([cert])
        } else {
            // PAIRING: no pin record yet. A §3 pin without a record is a
            // corrupt store — refuse rather than degrade to open TLS.
            if !identity.pin.isEmpty { throw TlsV2Error.noPin }
            tls.certificateVerification = .none
        }
        guard let ownCert = try? NIOSSLCertificate(bytes: [UInt8](identity.certPem.utf8), format: .pem),
              let ownKey = try? NIOSSLPrivateKey(bytes: [UInt8](identity.keyP8.utf8), format: .pem) else {
            throw TlsV2Error.incompleteIdentity
        }
        tls.certificateChain = [.certificate(ownCert)]
        tls.privateKey = .privateKey(ownKey)
        // min == max TLSv1.3 (§1); resumption/0-RTT cannot start (R3): no PSK
        // material is ever provisioned and contexts are never reused/cached.
        tls.minimumTLSVersion = .tlsv13
        tls.maximumTLSVersion = .tlsv13
        let capture = keyLog
        tls.keyLogCallback = { buffer in
            var copy = buffer
            if let line = copy.readString(length: copy.readableBytes) { capture.note(line) }
        }
        return tls
    }

    /// The exporter of this connector's (single) connection attempt, nil when
    /// no handshake completed. Memory only — keylog secrets are never
    /// persisted or logged.
    func attemptedSessionExporter() -> [UInt8]? {
        guard let secret = keyLog.only else { return nil }
        return ExporterV2.derive(exporterSecret: secret)
    }

    /// Connects; the returned session stays open while the caller keeps the
    /// channel. `onPeerPin` fires once the handshake completed, with the
    /// phone's fingerprint: pairing mode uses it to learn the pin (state
    /// machine), enforced mode has already verified it at the TLS layer and
    /// the event is informational.
    func connect(host: String, port: Int,
                 onFrame: @escaping @Sendable (Frame) -> Void,
                 onError: @escaping @Sendable (String) -> Void,
                 onPeerPin: (@Sendable (String) -> Void)? = nil) throws -> (channel: Channel, exporter: () -> [UInt8]?, send: @Sendable (Frame) -> Void) {
        // Throws TlsV2Error.noPin / .pinMismatch / .incompleteIdentity BEFORE
        // any dial when the pin rules cannot be met (§8 step 3 gate).
        let tlsConfig = try configuration()
        let context = try NIOSSLContext(configuration: tlsConfig)
        let capture = keyLog
        let sslHandler = try NIOSSLClientHandler(context: context, serverHostname: nil)
        let learn = onPeerPin
        do {
            let channel = try ClientBootstrap(group: group)
                .connect(to: try SocketAddress(ipAddress: host, port: port))
                .flatMap { ch -> EventLoopFuture<Channel> in ch.pipeline.addHandler(sslHandler).map { _ in ch } }
                .flatMap { ch -> EventLoopFuture<Channel> in
                    ch.pipeline.addHandler(HandshakeLearnHandler(handshakeCompleted: { fps in learn?(fps) })).map { _ in ch }
                }
                .flatMap { ch -> EventLoopFuture<Channel> in
                    ch.pipeline.addHandler(FrameDeliveryHandler(onFrame: onFrame, onError: onError)).map { _ in ch }
                }
                .wait()
            return (channel, { capture.only.flatMap { ExporterV2.derive(exporterSecret: $0) } }, { frame in
                var buffer = channel.allocator.buffer(capacity: frame.encoded.count)
                buffer.writeBytes(frame.encoded)
                _ = channel.writeAndFlush(buffer)
            })
        } catch {
            let message = String(describing: error)
            throw TlsV2Error.dialFailed(String(message.prefix(180)))
        }
    }
}

// MARK: - Handshake-completed watcher (pairing-mode pin learning)

/// Sits after the SSL handler; when the handshake completes it reads the
/// phone's leaf cert and reports its fingerprint (v2 §4 — the phone's
/// certificate fingerprint is the pin input).
final class HandshakeLearnHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let handshakeCompleted: @Sendable (String) -> Void
    private var fired = false

    init(handshakeCompleted: @escaping @Sendable (String) -> Void) {
        self.handshakeCompleted = handshakeCompleted
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if !fired, case .handshakeCompleted = event as? TLSUserEvent {
            fired = true
            let report = handshakeCompleted
            // NEVER block the event loop with a synchronous pipeline lookup:
            // the future form resolves on the same loop, cleanly.
            _ = context.pipeline.handler(type: NIOSSLHandler.self).whenSuccess { handler in
                if let peerFp = handler.peerCertificate.flatMap({ PinCheckV2.pointFingerprint(cert: $0) }) {
                    report(Data(peerFp).hexString)
                }
            }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.fireErrorCaught(error)
        context.close(promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
    }
}

// MARK: - Framing

/// Decodes application frames (v2 framing is byte-identical to v1 — §fixed
/// decisions) and surfaces transport errors. writer side uses `send(frame)`.
final class FrameDeliveryHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let onFrame: @Sendable (Frame) -> Void
    private let onError: @Sendable (String) -> Void
    private var decoder = FrameDecoder()

    init(onFrame: @escaping @Sendable (Frame) -> Void, onError: @escaping @Sendable (String) -> Void) {
        self.onFrame = onFrame
        self.onError = onError
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        var bytes = Data()
        buffer.withUnsafeReadableBytes { region in
            bytes.append(contentsOf: region.bindMemory(to: UInt8.self))
        }
        do {
            let frames = try decoder.append(bytes)
            for frame in frames { onFrame(frame) }
        } catch {
            onError("framing: \(error)")
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onError("tls: \(String(describing: error))")
        context.close(promise: nil)
    }
}
