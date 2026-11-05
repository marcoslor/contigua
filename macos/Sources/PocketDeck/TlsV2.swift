// The TLS transport for the Mac side (docs/design/e2ee.md §1/§4b/§6) — what
// every session dials with; the v1 NWConnection/plaintext path is gone.
//
// - NIOSSL/BoringSSL in memory: per-profile identity (DeviceIdentityV2), TLS 1.3
//   only, resumption and 0-RTT impossible (R3): every connect makes a fresh
//   SSL context and no session is ever cached, so the client cannot offer a PSK.
// - The pin (§1): SHA-256 over the 65-byte uncompressed EC point of the peer
//   cert, checked inside the handshake through NIOSSL's custom verification
//   callback. The dialed phone's own record (pins.json) is the pin; a record
//   that is missing, or has no cert, refuses to connect at all (§8 step 3).
//   identity.json's `pin` is only the §3 mirror of the phone in use.
//   Pairing mode (no record) accepts the peer's self-signed cert and reports
//   its fingerprint so the state machine can store it after commit/reveal.
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
/// cert (SAN/IP, EKU server+client, one day of clock skew before issuance).
/// The valid-after is far in the future: pins are permanent and the cert is
/// never renewed, so a short life would break every paired peer on expiry
/// (sec L-5). Existing identities are never regenerated. Pin starts empty;
/// pairing writes the phone's fingerprint.
enum IdentityGeneratorV2 {
    /// 100 years, the lifetime of a new identity at both ends of a pairing.
    static let lifetime: TimeInterval = 100 * 365 * 86_400

    /// Serial derives from the key itself: same key ⇒ same serial, no extra state.
    static func serialNumber(for key: P256.Signing.PublicKey) -> UInt128 {
        let digest = SHA256.hash(data: key.x963Representation)
        var value: UInt128 = 0
        for b in digest.prefix(16) { value = (value << 8) | UInt128(b) }
        return value
    }

    /// `notValidBefore`/`notValidAfter` exist for tests (an expired pinned
    /// cert); production uses the defaults.
    static func make(deviceId: String, cn: String = "PocketDeck Mac",
                     notValidBefore: Date? = nil,
                     notValidAfter: Date? = nil) -> (identity: DeviceIdentityV2, privateKey: P256.Signing.PrivateKey) {
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
                notValidBefore: notValidBefore ?? now.addingTimeInterval(-86_400),
                notValidAfter: notValidAfter ?? now.addingTimeInterval(lifetime),
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

/// One phone's pin record (§6: "the pin store feeds `trustRoots` per phone" —
/// today the pin is compared directly, see sec L-5).
/// `-fp` hex is the fingerprint the pin store carries; the cert PEM is the same
/// self-signed cert the phone presented, kept so the pin gate can re-derive and
/// cross-check the fingerprint before dialing. Persistence is `pins.json`
/// (0600); the in-memory store write-through saves on every change (step 7).
struct PinnedPhoneV2: Codable, Equatable {
    var deviceId: String
    var phoneFingerprintHex: String
    var certPem: String
}

extension PhonePinStoreV2 {
    /// pins.json in the profile's support folder, next to identity.json.
    static func fileUrl(in profile: Profile) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(profile.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("pins.json")
    }
}

enum PhonePinsFileV2 {
    /// Loads the store's records; an unreadable file means none.
    static func load(url: URL) -> [PinnedPhoneV2] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([PinnedPhoneV2].self, from: data) else { return [] }
        return list
    }

    /// 0600 atomic write like identity.json (pins are phone→trust data).
    @discardableResult
    static func save(_ records: [PinnedPhoneV2], url: URL) -> Bool {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            let data = try JSONEncoder().encode(records)
            let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
            guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                return false
            }
            guard rename(tmp.path, url.path) == 0 else {
                try? fm.removeItem(at: tmp)
                return false
            }
            return true
        } catch {
            Log.app.error("pins not saved: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

// MARK: - The §3 mirror of the phone in use

/// identity.json's `pin` names the phone the Mac is using; it is never a
/// second authority over another phone's record (the record is). These rules
/// keep it in step with the store, as values so K2 tests them without a file.
enum IdentityPinMirror {
    /// The fingerprint to mirror for `deviceId`: its record's, or "" when the
    /// store has none (the file must never name a phone the store forgot).
    static func pin(for deviceId: String, records: [PinnedPhoneV2]) -> String {
        records.first { $0.deviceId == deviceId }?.phoneFingerprintHex ?? ""
    }

    /// The mirror after `forgotten` left the store: empty when no remaining
    /// record holds it; otherwise unchanged (it still names a stored phone).
    static func pinAfterForget(current: String, records: [PinnedPhoneV2], forgotten: String) -> String {
        guard !current.isEmpty else { return "" }
        if records.contains(where: { $0.phoneFingerprintHex == current && $0.deviceId != forgotten }) {
            return current
        }
        return ""
    }
}

/// deviceId → pin record, write-through to `pins.json` (0600) when the owner
/// supplies the file URL. In-memory only otherwise (tests).
final class PhonePinStoreV2 {
    private var phones: [String: PinnedPhoneV2] = [:]
    private let lock = NSLock()
    private let fileUrl: URL?

    init(fileUrl: URL? = nil) {
        self.fileUrl = fileUrl
        if let fileUrl {
            for record in PhonePinsFileV2.load(url: fileUrl) { phones[record.deviceId] = record }
        }
    }
    private static func saveAll(_ phones: [String: PinnedPhoneV2], fileUrl: URL?) {
        guard let fileUrl else { return }
        _ = PhonePinsFileV2.save(Array(phones.values), url: fileUrl)
    }

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
        Self.saveAll(phones, fileUrl: fileUrl)
    }

    /// §7: the old pin is deleted on successful re-pair; `forget` removes it.
    func forget(deviceId: String) {
        lock.lock(); defer { lock.unlock() }
        guard phones.removeValue(forKey: deviceId) != nil else { return }
        Self.saveAll(phones, fileUrl: fileUrl)
    }

    /// Every record's fingerprint.
    func fingerprints() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return phones.values.map(\.phoneFingerprintHex).sorted()
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        phones.removeAll()
        Self.saveAll(phones, fileUrl: fileUrl)
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
    /// a pinned phone from the pin store; the connection is then verified by
    /// exact fingerprint, not by chain/date validation (sec L-5).
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
            // ENFORCED: the dialed phone's own record is the pin. identity.json's
            // §3 `pin` only mirrors the phone in use (rewritten on a successful
            // connect and on use), so it is never compared with another phone's
            // record: pairing A then B and switching back to A must not read as
            // a changed certificate. The record must carry its cert and its
            // fingerprint; missing either ⇒ refuse (nothing interpretable).
            guard let cert = try? NIOSSLCertificate(bytes: [UInt8](phone.certPem.utf8), format: .pem) else {
                throw TlsV2Error.incompleteIdentity
            }
            guard let peerFingerprint = PinCheckV2.pointFingerprint(cert: cert) else {
                throw TlsV2Error.notP256
            }
            guard !phone.phoneFingerprintHex.isEmpty else { throw TlsV2Error.noPin }
            guard PinCheckV2.matches(peerFingerprint, pinHex: phone.phoneFingerprintHex) else {
                throw TlsV2Error.pinMismatch(got: Data(peerFingerprint).hexString,
                                             expected: phone.phoneFingerprintHex)
            }
            // The pin IS the check (sec L-5): `connect()` installs a custom
            // verification callback that accepts the peer only when its leaf
            // fingerprint equals this pin. No trust roots, no hostname, and no
            // validity dates: the phone's self-signed leaf was issued for 366
            // days and is never renewed, so an expiry check would break every
            // paired phone after a year. Everything else is still rejected.
            // (Resumed handshakes are impossible: R3.)
            tls.certificateVerification = .noHostnameVerification
        } else {
            // PAIRING: no record for the dialed phone yet. The §3 mirror names
            // the phone last used and must not gate it.
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

    /// The client handler for one attempt. With a pin, a custom verification
    /// callback replaces BoringSSL's chain validation entirely: the leaf is
    /// accepted only when its P-256 point fingerprint equals the pin, and its
    /// validity dates are deliberately not consulted (sec L-5: the phone's
    /// self-signed leaf has a fixed 366-day life and is never renewed).
    static func makeClientHandler(context: NIOSSLContext, pinnedPinHex: String?) throws -> NIOSSLClientHandler {
        guard let pinHex = pinnedPinHex else {
            return try NIOSSLClientHandler(context: context, serverHostname: nil)
        }
        return try NIOSSLClientHandler(context: context, serverHostname: nil,
                                       customVerificationCallback: { chain, promise in
            guard let leaf = chain.first,
                  let fingerprint = PinCheckV2.pointFingerprint(cert: leaf),
                  PinCheckV2.matches(fingerprint, pinHex: pinHex) else {
                promise.succeed(.failed)
                return
            }
            promise.succeed(.certificateVerified)
        })
    }

    /// Connects; the returned session stays open while the caller keeps the
    /// channel. `onPeerPin` fires once the handshake completed, with the
    /// phone's fingerprint: pairing mode uses it to learn the pin (state
    /// machine), enforced mode has already verified it at the TLS layer and
    /// the event is informational.
    func connect(host: String, port: Int,
                 net: MacStreamStrategy.Net = .default,
                 onFrame: @escaping @Sendable (Frame) -> Void,
                 onError: @escaping @Sendable (String) -> Void,
                 onPeerPin: (@Sendable (String) -> Void)? = nil,
                 onPeerCert: (@Sendable (NIOSSLCertificate) -> Void)? = nil,
                 onWritableChange: (@Sendable (Bool) -> Void)? = nil,
                 handshakeTimeout: TimeAmount = .seconds(6)) throws -> (channel: Channel, exporter: () -> [UInt8]?, send: @Sendable (Frame) -> Void, isWritable: @Sendable () -> Bool, setReading: @Sendable (Bool) -> Void, serviceType: Int32?) {
        // Throws TlsV2Error.noPin / .pinMismatch / .incompleteIdentity BEFORE
        // any dial when the pin rules cannot be met (§8 step 3 gate).
        let tlsConfig = try configuration()
        let context = try NIOSSLContext(configuration: tlsConfig)
        let capture = keyLog
        // Pinned peers: the standard trust-roots path is replaced by a callback
        // that compares the presented leaf against the dialed record's pin and
        // ignores the certificate's validity dates (sec L-5). Pairing mode (no
        // record) keeps the plain handler: any cert completes, the pin is
        // learned from it.
        let sslHandler = try Self.makeClientHandler(context: context,
                                                    pinnedPinHex: pinnedPhone?.phoneFingerprintHex)
        let learn = onPeerPin
        let learnCert = onPeerCert
        // PATH-20: a path is ready only when TLS has finished, not when TCP
        // has. The hello is serialized over the finished attempts, so a
        // black-holed provider must never win it just by accepting a socket.
        let handshake = group.next().makePromise(of: Void.self)
        // R-12: a peer that accepts TCP and then goes silent must not block
        // this thread and hold the fd forever. The attempt timer still owns the
        // attempt; this closes the channel so the dial fails inside it.
        let handshakeDeadline = group.next().scheduleTask(in: handshakeTimeout) {
            handshake.fail(TlsV2Error.handshakeTimeout)
        }
        do {
            var bootstrap = ClientBootstrap(group: group)
                .channelOption(ChannelOptions.writeBufferWaterMark,
                               value: WriteBufferWaterMark(low: 256 << 10, high: 1 << 20))
            // N1: the stream socket asks for the interactive-video service
            // class before connect; the default socket stays unmarked.
            if let serviceType = MacStreamStrategy(net: net).socketServiceType {
                bootstrap = bootstrap.channelOption(
                    ChannelOptions.socketOption(
                        NIOBSDSocket.Option(rawValue: CInt(SO_NET_SERVICE_TYPE))),
                    value: serviceType)
            }
            let channel = try bootstrap
                .connect(to: try SocketAddress(ipAddress: host, port: port))
                .flatMap { ch -> EventLoopFuture<Channel> in
                    // Both handlers enter the pipeline in one event-loop turn,
                    // before the handshake can complete, so the learn handler
                    // never misses the SSL handler's event.
                    do {
                        try ch.pipeline.syncOperations.addHandler(sslHandler)
                        try ch.pipeline.syncOperations.addHandler(
                            HandshakeLearnHandler(handshakeCompleted: { fps in learn?(fps) },
                                                  peerCertificate: { cert in learnCert?(cert) },
                                                  handshakePromise: handshake))
                        if let onWritableChange {
                            try ch.pipeline.syncOperations.addHandler(WritabilityHandler(onChange: onWritableChange))
                        }
                    } catch {
                        return ch.eventLoop.makeFailedFuture(error)
                    }
                    return ch.eventLoop.makeSucceededFuture(ch)
                }
                .flatMap { ch -> EventLoopFuture<Channel> in
                    ch.pipeline.addHandler(FrameDeliveryHandler(onFrame: onFrame, onError: onError)).map { _ in ch }
                }
                .wait()
            do {
                try handshake.futureResult.wait()
            } catch {
                handshakeDeadline.cancel()
                channel.close(promise: nil)
                throw error
            }
            handshakeDeadline.cancel()
            return (channel, { capture.only.flatMap { ExporterV2.derive(exporterSecret: $0) } }, { frame in
                var buffer = channel.allocator.buffer(capacity: frame.encoded.count)
                buffer.writeBytes(frame.encoded)
                _ = channel.writeAndFlush(buffer)
            }, { channel.isWritable }, { reading in
                _ = channel.setOption(ChannelOptions.autoRead, value: reading)
            }, Self.serviceType(of: channel))
        } catch {
            handshakeDeadline.cancel()
            let message = String(describing: error)
            throw TlsV2Error.dialFailed(String(message.prefix(180)))
        }
    }

    /// N1: what the socket actually reports for `SO_NET_SERVICE_TYPE`, so the
    /// run proves the option landed instead of trusting the write.
    static func serviceType(of channel: Channel) -> Int32? {
        let option = ChannelOptions.socketOption(
            NIOBSDSocket.Option(rawValue: CInt(SO_NET_SERVICE_TYPE)))
        return try? channel.getOption(option).wait()
    }
}

/// Reports NIO's writability so the path layer can feed bulk only while the
/// channel's write buffer is under its water mark (D-2).
final class WritabilityHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let onChange: @Sendable (Bool) -> Void

    init(onChange: @escaping @Sendable (Bool) -> Void) {
        self.onChange = onChange
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        onChange(context.channel.isWritable)
        context.fireChannelWritabilityChanged()
    }
}

// MARK: - Handshake-completed watcher (pairing-mode pin learning)

/// Sits after the SSL handler; when the handshake completes it reads the
/// phone's leaf cert and reports its fingerprint (v2 §4 — the phone's
/// certificate fingerprint is the pin input).
final class HandshakeLearnHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let handshakeCompleted: @Sendable (String) -> Void
    private let peerCertificate: @Sendable (NIOSSLCertificate) -> Void
    /// Completed when the handshake finishes (or fails), after the callbacks
    /// above ran: the connector does not report a path ready before this.
    private let handshakePromise: EventLoopPromise<Void>?
    private var fired = false
    /// The promise completes once, on this handler's event loop.
    private var settled = false

    init(handshakeCompleted: @escaping @Sendable (String) -> Void,
         peerCertificate: @escaping @Sendable (NIOSSLCertificate) -> Void = { _ in },
         handshakePromise: EventLoopPromise<Void>? = nil) {
        self.handshakeCompleted = handshakeCompleted
        self.peerCertificate = peerCertificate
        self.handshakePromise = handshakePromise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if !fired, case .handshakeCompleted = event as? TLSUserEvent {
            fired = true
            let report = handshakeCompleted
            let done = handshakePromise
            // NEVER block the event loop with a synchronous pipeline lookup:
            // the future form resolves on the same loop, cleanly. The promise
            // is completed last so connect() cannot outrun the pin callback.
            context.pipeline.handler(type: NIOSSLHandler.self).whenComplete { result in
                switch result {
                case .success(let handler):
                    if let cert = handler.peerCertificate {
                        self.peerCertificate(cert)
                    }
                    if let peerFp = handler.peerCertificate.flatMap({ PinCheckV2.pointFingerprint(cert: $0) }) {
                        report(Data(peerFp).hexString)
                    }
                    if !self.settled {
                        self.settled = true
                        done?.succeed(())
                    }
                case .failure(let error):
                    if !self.settled {
                        self.settled = true
                        done?.fail(error)
                    }
                }
            }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !settled {
            settled = true
            handshakePromise?.fail(error)
        }
        context.fireErrorCaught(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !settled {
            settled = true
            handshakePromise?.fail(TlsV2Error.dialFailed("closed before the handshake finished"))
        }
        context.fireChannelInactive()
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

    func channelInactive(context: ChannelHandlerContext) {
        // The phone hung up (pair_denied close, phone restart, network loss):
        // the session must hear about it, not sit silent like v1's receive loop
        // never did.
        onError("closed-by-peer")
        context.close(promise: nil)
    }
}
