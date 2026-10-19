// One TLS session per phone. Owns the NIO channel (TlsConnectorV2), the framed
// reader/writer, the handshake state machine, the 15 s app-level ping and
// reconnect.
//
// Everything the rest of the app sees is a `SessionEvent` delivered on the
// main queue; video frames included (the display layer hops to its own queue).

import CryptoKit
import Foundation
import Network
import NIO
import NIOCore
import NIOSSL
import NIOPosix

enum SessionState: Equatable {
    case idle
    case connecting
    case handshaking
    case ready
    case failed(String)
    case closed
}

/// How the display's content got there (`window.opened` `started`, used by
/// `task.continue`; docs/design/handoff.md).
enum HandoffStart: Equatable {
    /// The task was moved to the display; its state is kept.
    case moved
    /// The phone couldn't move the task and relaunched the package instead: the
    /// app's state may be lost, and the window says so.
    case fresh
}

struct PhoneInfo: Equatable {
    var id: String
    var name: String
    var model: String
    var sdk: Int
    var screenWidth: Int
    var screenHeight: Int
    var screenDpi: Int
    var locked: Bool
    var battery: Int?
    var charging: Bool?

    var screenSize: CGSize { CGSize(width: screenWidth, height: screenHeight) }

    init?(device: [String: Any]?) {
        guard let device else { return nil }
        let screen = device["screen"] as? [String: Any] ?? [:]
        id = device["id"] as? String ?? ""
        name = device["name"] as? String ?? "Android"
        model = device["model"] as? String ?? ""
        sdk = (device["sdk"] as? NSNumber)?.intValue ?? 0
        screenWidth = (screen["w"] as? NSNumber)?.intValue ?? 0
        screenHeight = (screen["h"] as? NSNumber)?.intValue ?? 0
        screenDpi = (screen["dpi"] as? NSNumber)?.intValue ?? 0
        locked = (device["locked"] as? NSNumber)?.boolValue ?? false
        battery = (device["battery"] as? NSNumber)?.intValue
        charging = (device["charging"] as? NSNumber)?.boolValue
    }
}

struct AppInfo: Equatable {
    var pkg: String
    var label: String
    var activity: String?

    init?(json: [String: Any]) {
        guard let pkg = json["pkg"] as? String else { return nil }
        self.pkg = pkg
        label = json["label"] as? String ?? pkg
        activity = json["activity"] as? String
    }
}

/// Video payloads, delivered off the main thread.
enum VideoEvent {
    case config(stream: UInt32, config: VideoConfig)
    case frame(stream: UInt32, frame: VideoFrameData)
}

enum SessionEvent {
    case state(SessionState, String?)
    case ready(PhoneInfo, isReconnect: Bool, address: CachedAddress?)
    case apps([AppInfo])
    /// The adaptive layers ride along when the icon is one (`icon` message).
    case icon(pkg: String, png: Data, fg: Data?, bg: Data?, mono: Data?)
    case windowOpened(stream: UInt32, displayId: Int, width: Int, height: Int,
                      started: HandoffStart)
    case windowClosed(stream: UInt32, reason: String)
    case windowTitle(stream: UInt32, label: String, pkg: String)
    case phoneState(locked: Bool, battery: Int, charging: Bool)
    case audioState(on: Bool, codec: UInt8)
    case phoneError(code: String, message: String?, stream: UInt32)
    /// The phone showed this code for the person to compare with its screen.
    case pairCodeShown(deviceId: String?, code: String)
    /// The person tapped Allow; the key and `welcome` follow.
    case pairApproved
    /// The phone accepted the key we were showing in a QR: it is stored now.
    case qrPaired(deviceId: String)
    /// A cached address answered with a different device id: refuse it.
    case identityMismatch(expected: String, actual: String)
    case protocolViolation(String)
    /// The phone's clipboard now holds this text (`clip.set`).
    case clipboard(String)
    case apkProgress(id: UInt32, bytes: Int)
    case apkResult(ApkResult)
    /// The phone saved a dropped file (docs/design/dragdrop.md).
    case dropProgress(id: UInt32, bytes: Int)
    case dropResult(DropResult)
    /// The phone shares a clipboard image (`clip.image.*` + CLIP_DATA).
    case clipImageBegin(id: UInt32, mime: String, size: Int)
    case clipImageData(id: UInt32, bytes: [UInt8])
    case clipImageEnd(id: UInt32, size: Int, sha256: String)
    case clipImageAbort(id: UInt32)
    /// Share phone → Mac (docs/design/sharein.md).
    case shareText(String)
    case shareFileBegin(id: UInt32, name: String, mime: String)
    case shareFileData(id: UInt32, bytes: [UInt8])
    case shareFileEnd(id: UInt32, size: Int, sha256: String)
    case shareFileAbort(id: UInt32)
    /// Notifications + media controls (docs/design/notify.md).
    case notifyState(on: Bool)
    case notifyPosted(id: String, pkg: String, when: Date?, title: String?, text: String?)
    case notifyRemoved(id: String)
    case mediaState(MediaState)
}

/// The phone's `drop.result` (docs/design/dragdrop.md).
struct DropResult: Equatable {
    var id: UInt32
    var ok: Bool
    var code: String?
    var message: String?
    /// Where the file landed on the phone (success only).
    var path: String?
}

/// The phone's `apk.result` (docs/design/apk.md).
struct ApkResult: Equatable {
    var id: UInt32
    var ok: Bool
    var code: String?
    var message: String?
    var pkg: String?
    var label: String?
    var version: String?
}

final class Session {
    enum Endpoint {
        case hostPort(host: String, port: UInt16)
        case service(NWEndpoint, pinnedTo: NWInterface? = nil)
    }

    private let endpoint: Endpoint
    private let knownDeviceFor: String?
    var knownDeviceId: String? {
        // Set for real on `welcome`; before that it is the remembered id this
        // attempt dialed against (the pin-mismatch cache drop reads exactly
        // that pre-welcome identity).
        knownDeviceIdReal ?? knownDeviceFor
    }
    private var knownDeviceIdReal: String?
    private let strictDeviceId: String?
    private let clientId: String
    /// The Mac's v2 TLS identity (docs/design/e2ee.md §3); loaded per profile by
    /// the caller, or generated ad hoc (placeholder sessions, unit tests).
    private let identity: DeviceIdentityV2
    /// A pin record handed in by the owner (a reconnect to a phone the pin
    /// store knows). nil = pairing mode; the store is only consulted for
    /// automatic attempts through `resolvePinnedPhone`.
    private let pinnedPhone: PinnedPhoneV2?
    /// Shared, persisted when the owner wires it (`pins.json`); pair.ok keeps
    /// the record the session learned.
    private let phonePinStore: PhonePinStoreV2?
    /// Called when pairing established a pin: lets the owner sync identity.json's
    /// mirrored pin (§3) on the same event.
    private let pinSessionEstablished: ((PinnedPhoneV2) -> Void)?

    private let queue = DispatchQueue(label: "dev.pocketdeck.session")
    private let connectionLock = NSLock()
    private var channel: Channel?
    private var channelSend: (@Sendable (Frame) -> Void)?
    private var exporterProvider: (() -> [UInt8]?)?
    private var eventLoopGroup: EventLoopGroup?
    private var ownsGroup: Bool = false

    private var decoder = FrameDecoder()
    /// The dialed host:port of the current/most recent attempt (§2): welcome
    /// turns it into the cached address the planner falls back on (C10).
    private var dialedAddress: CachedAddress?
    /// The peer state the TLS layer learns: the phone's certificate fingerprint
    /// and the cert itself. Set asynchronously by the handshake watcher, read
    /// on demand (pairing happens well after the handshake completed).
    private var learnedPinProvider: (() -> String)?
    private var learnedCertProvider: (() -> NIOSSLCertificate?)?
    private var learnedPeerPin: String { learnedPinProvider?() ?? "" }
    private var aspectPeerCert: NIOSSLCertificate? { learnedCertProvider?() }
    private var macFingerprintHex: String

    private var pingTimer: Timer?
    private var connectWatchdog: DispatchWorkItem?
    private var pairingDeadline: DispatchWorkItem?
    /// The session-level `error` code the phone sent on this connection, if any.
    private var phoneErrorCode: String?
    private var everReady = false
    private var intentionalClose = false
    private var loggedUnknown: Set<String> = []

    /// The v2 pairing room: the phone's committed hash, our nonce, the code
    /// state. All used on the session queue only.
    private var remoteCommit: Data?
    private var ourNm: Data?
    private var pendingNp: Data?
    /// The one-time QR secret S this probe carries (nil outside QR probes);
    /// never written anywhere (R2).
    private var qrSecret: Data?
    /// The phone allowed a QR pairing (its pair.ok); `.qrPaired` waits for welcome.
    private var qrApproved = false
    private var loggedExporterSha = false
    private var failedOnce = false

    enum PairingPolicy { case never, allowed, probe }
    var pairingPolicy: PairingPolicy = .allowed

    private(set) var state: SessionState = .idle
    private(set) var phone: PhoneInfo?

    var onEvent: ((SessionEvent) -> Void)?
    var onVideoEvent: ((VideoEvent) -> Void)?
    var onAudioEvent: ((AudioEvent) -> Void)?

    static let pingInterval: TimeInterval = 15
    static let defaultConnectTimeout: TimeInterval = 6
    static let defaultPairingTimeout: TimeInterval = 125

    private let connectTimeout: TimeInterval
    private let pairingTimeout: TimeInterval

    // MARK: Inits

    /// The designated init: the owner decides the identity (profile-loaded),
    /// the pin record (nil = pairing) and the shared pin store.
    init(endpoint: Endpoint, knownDeviceId: String?, strictDeviceId: String? = nil,
         clientId: String, identity: DeviceIdentityV2? = nil,
         pinnedPhone: PinnedPhoneV2? = nil, pinStore: PhonePinStoreV2? = nil,
         onPinEstablished: ((PinnedPhoneV2) -> Void)? = nil,
         group: EventLoopGroup? = nil,
         connectTimeout: TimeInterval = Session.defaultConnectTimeout,
         pairingTimeout: TimeInterval = Session.defaultPairingTimeout) {
        self.endpoint = endpoint
        self.knownDeviceFor = knownDeviceId
        self.strictDeviceId = strictDeviceId
        self.clientId = clientId
        if let identity {
            self.identity = identity
        } else {
            // No profile in scope (placeholder sessions, unit tests): ad-hoc
            // TNI identity, never persisted.
            self.identity = IdentityGeneratorV2.make(
                deviceId: clientId.isEmpty ? UUID().uuidString.lowercased() : clientId).identity
        }
        self.pinnedPhone = pinnedPhone
        self.phonePinStore = pinStore
        self.pinSessionEstablished = onPinEstablished
        self.eventLoopGroup = group
        self.connectTimeout = connectTimeout
        self.pairingTimeout = pairingTimeout

        if let cert = try? NIOSSLCertificate(bytes: [UInt8](self.identity.certPem.utf8), format: .pem),
           let fp = PinCheckV2.pointFingerprint(cert: cert) {
            self.macFingerprintHex = Data(fp).hexString
        } else {
            self.macFingerprintHex = ""
        }
    }

    /// Placeholder sessions (WindowManager construction) and most unit tests:
    /// an ad-hoc identity, no pin store.
    convenience init(endpoint: Endpoint, knownDeviceId: String?, strictDeviceId: String? = nil,
                     clientId: String,
                     connectTimeout: TimeInterval = Session.defaultConnectTimeout,
                     pairingTimeout: TimeInterval = Session.defaultPairingTimeout) {
        self.init(endpoint: endpoint, knownDeviceId: knownDeviceId, strictDeviceId: strictDeviceId,
                  clientId: clientId, identity: nil,
                  connectTimeout: connectTimeout, pairingTimeout: pairingTimeout)
    }

    // MARK: Lifecycle

    func start() {
        intentionalClose = false
        failedOnce = false
        transition(.connecting, nil)
        armConnectWatchdog()
        queue.async { [weak self] in self?.doConnect() }
    }

    private func doConnect() {
        guard !intentionalClose else { return }
        guard let target = resolveTarget(endpoint) else {
            fail("resolve"); return
        }
        dialedAddress = nil
        if let port = UInt16(exactly: target.port) {
            dialedAddress = CachedAddress(host: target.host, port: port)
        }

        // The pin record for a reconnect comes from the shared store; pairing
        // attempts NEVER use one (§7: a stale pin must not block a person's
        // re-pair), and an automatic attempt without any record cannot
        // authenticate at all (v2 replaces the v1 key), so it fails up front.
        var pinned = self.pinnedPhone
        if pinned == nil, let store = phonePinStore {
            if let id = knownDeviceId ?? strictDeviceId {
                pinned = store.record(for: id)
            }
        }
        if pinned == nil, pairingPolicy == .never {
            Log.session.notice("no pin for \(self.describeEndpoint(), privacy: .public); not connecting automatically")
            fail("no-pin"); return
        }

        if eventLoopGroup == nil {
            eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            ownsGroup = true
        }
        let group = eventLoopGroup!

        let connector = TlsConnectorV2(identity: identity, pinnedPhone: pinned, group: group)
        let learned = SessionLockedBox(value: "")
        let learnedCert = SessionLockedBox<NIOSSLCertificate?>(value: nil)
        let connectResult: (channel: Channel, exporter: () -> [UInt8]?, send: @Sendable (Frame) -> Void)?
        do {
            connectResult = try connector.connect(host: target.host, port: target.port,
                  onFrame: { [weak self] frame in
                guard let self else { return }
                self.queue.async { self.handleFrame(frame) }
            }, onError: { [weak self] err in
                guard let self else { return }
                self.queue.async { self.handleTransportError(err) }
            }, onPeerPin: { fp in learned.set(fp) },
               onPeerCert: { cert in learnedCert.set(cert) })
        } catch let error as TlsV2Error {
            Log.session.error("tls connect refused: \(error.description, privacy: .public)")
            switch error {
            case .pinMismatch: fail("pin-mismatch")
            case .noPin: fail("no-pin")
            default: fail("tls")
            }
            return
        } catch {
            let message = String(describing: error)
            // A mid-handshake verification failure IS the stale-pin refusal
            // (§7): the dial carries the pin record's phone cert as its only
            // trust root, so the peer cert failing to verify means the phone's
            // certificate changed. Surface it as pin-mismatch, not generic tls.
            if message.contains("certificate_verify_failed") || message.contains("certificate verify") {
                Log.session.error("tls verify refused: \(message.prefix(160), privacy: .public)")
                fail("pin-mismatch"); return
            }
            Log.session.error("tls connect failed: \(message.prefix(160), privacy: .public)")
            fail("tls"); return
        }
        guard let res = connectResult else {
            fail("tls"); return
        }
        channel = res.channel
        channelSend = res.send
        exporterProvider = res.exporter
        // The handshake watcher resolves asynchronously: the pin and the peer
        // cert are read on demand (pairing time is well after the handshake).
        learnedPinProvider = { learned.get() }
        learnedCertProvider = { learnedCert.get() }
        transition(.handshaking, nil)
        Log.session.info("tls connected (\(self.describeEndpoint(), privacy: .public)); hello v2")
        sendJSON(["t": "hello", "v": 2, "clientId": clientId, "name": ClientIdentity.name, "id": identity.deviceId])
        // Unpaired target + a user-driven session: start the code pairing right
        // away. A paired target answers `welcome` instead; policy .never stays
        // silent (it would make the phone prompt for nobody), and a QR probe
        // only opens the pairing channel for the phone to answer.
        if pinned == nil, pairingPolicy == .allowed {
            sendJSON(["t": "pair.request"])
        }
    }

    func close() {
        intentionalClose = true
        cancelTimers()
        closeChannel()
        transition(.closed, nil)
        if ownsGroup {
            try? eventLoopGroup?.syncShutdownGracefully()
            eventLoopGroup = nil
            ownsGroup = false
        }
    }

    private func closeChannel() {
        connectionLock.lock()
        let ch = channel
        channel = nil
        channelSend = nil
        exporterProvider = nil
        connectionLock.unlock()
        if let ch { try? ch.close().wait() }
    }

    /// Bonjour services still resolve through Network.framework (NIO cannot
    /// resolve `_pocketdeck._tcp` names); the resolver runs on its own queue so
    /// the session queue is never blocked by it. The dial itself then goes to
    /// the resolved host/port over NIO. Note the dial keeps no interface
    /// pinning once resolved — a bridge-resolved address fails the TLS dial and
    /// the owner's planner falls back to the cached address.
    private func resolveTarget(_ endpoint: Endpoint) -> (host: String, port: Int)? {
        switch endpoint {
        case .hostPort(let host, let port):
            return (host, Int(port))
        case .service(let service, _):
            let conn = NWConnection(to: service, using: Self.tcpParameters(for: endpoint))
            let resolveQueue = DispatchQueue(label: "dev.pocketdeck.session.resolve")
            let sem = DispatchSemaphore(value: 0)
            var resolved: NWEndpoint?
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resolved = conn.currentPath?.remoteEndpoint
                    sem.signal()
                case .failed, .cancelled:
                    sem.signal()
                default:
                    break
                }
            }
            conn.start(queue: resolveQueue)
            _ = sem.wait(timeout: .now() + 5)
            conn.cancel()
            guard let remote = resolved, case let .hostPort(host, port) = remote else { return nil }
            let hostString: String
            switch host {
            case let .name(name, _): hostString = name
            default:
                guard let textual = Self.ipAddressString(host) else { return nil }
                hostString = textual
            }
            return (hostString, Int(port.rawValue))
        }
    }

    /// The numeric form of a resolved NWEndpoint.Host (a dial needs an address
    /// NIO can use; a name would resolve again and might answer differently).
    static func ipAddressString(_ host: NWEndpoint.Host) -> String? {
        if case let .ipv4(ip) = host { return dialableHost("\(ip)") }
        if case let .ipv6(ip) = host { return dialableHost("\(ip)") }
        let parts = String(describing: host).components(separatedBy: CharacterSet(charactersIn: "()"))
        return dialableHost(parts.count > 1 ? parts[1] : parts.first ?? "")
    }

    /// The host string NIO can dial for a resolved address.
    ///
    /// Network.framework reports Bonjour-resolved ports interface-scoped
    /// ("192.168.1.5%en0"). `SocketAddress(ipAddress:)` only accepts a zone on
    /// IPv6 (it hands those to getaddrinfo), so a scoped IPv4 must lose it or
    /// every discovered phone fails to parse. On IPv6 the zone is dropped too,
    /// except for link-local (fe80::/10), which is unroutable without one.
    static func dialableHost(_ textual: String) -> String? {
        let trimmed = textual.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return nil }
        let percent = trimmed.firstIndex(of: "%")
        let address = percent.map { String(trimmed[..<$0]) } ?? trimmed
        let scope = percent.map { String(trimmed[trimmed.index(after: $0)...]) }
        guard !address.isEmpty else { return nil }
        guard address.contains(":") else { return address }
        guard isIPv6LinkLocal(address), let scope, !scope.isEmpty else { return address }
        return "\(address)%\(scope)"
    }

    /// fe80::/10 — the first hextet between fe80 and febf.
    private static func isIPv6LinkLocal(_ address: String) -> Bool {
        let hextet = address.prefix(while: { $0 != ":" })
        guard let value = UInt16(hextet, radix: 16) else { return false }
        return (value & 0xffc0) == 0xfe80
    }

    private func armConnectWatchdog() {
        connectWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.intentionalClose, self.state != .ready else { return }
            Log.session.notice("connect timed out after \(self.connectTimeout, privacy: .public)s")
            self.fail("timeout")
        }
        connectWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + connectTimeout, execute: work)
    }

    private func armPairingDeadline() {
        connectWatchdog?.cancel()
        connectWatchdog = nil
        pairingDeadline?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.intentionalClose, self.state != .ready else { return }
            Log.session.notice("no answer from the phone after \(self.pairingTimeout, privacy: .public)s")
            self.phoneErrorCode = "pair_timeout"
            self.fail("pair_timeout")
        }
        pairingDeadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + pairingTimeout, execute: work)
    }

    private func cancelTimers() {
        connectWatchdog?.cancel()
        connectWatchdog = nil
        pairingDeadline?.cancel()
        pairingDeadline = nil
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func transition(_ newState: SessionState, _ detail: String?) {
        state = newState
        emit(.state(newState, detail))
    }

    static func tcpParameters(for endpoint: Endpoint) -> NWParameters {
        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 10
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 15
        }
        if case .service(_, let interface?) = endpoint {
            parameters.requiredInterface = interface
        }
        return parameters
    }

    private func describeEndpoint() -> String {
        switch endpoint {
        case .hostPort(let host, let port): return "\(host):\(port)"
        case .service(let service, _): return String(describing: service)
        }
    }

    // MARK: Receive dispatch

    private func handleTransportError(_ message: String) {
        // The pinned-reconnect paths surface the stale-pin case as a TLS verify
        // failure inside the record's trustRoots (§7: "certificate changed").
        // A plain "closed-by-peer" is the phone's normal hang-up: notice, not
        // error (the phone treats aborted sessions quietly; the Mac mirrors it).
        if message.hasPrefix("closed-by-peer") {
            if !intentionalClose {
                Log.session.notice("the phone closed the TLS session")
            }
        } else {
            Log.session.error("tls transport refused: \(message.lowercased().prefix(240), privacy: .public)")
        }
        let lowered = message.lowercased()
        if message.contains(TlsV2Error.pinMismatch(got: "", expected: "").description.prefix(18)) {
            fail("pin-mismatch")
            return
        }
        // The trust root IS the pinned leaf; its verify failing mid-handshake
        // means the phone's certificate changed (stale pin, §7).
        if lowered.contains("certificate_verify_failed") || lowered.contains("certificate verify failed") {
            fail("pin-mismatch")
            return
        }
        fail("tls")
    }

    private func handleFrame(_ frame: Frame) {
        switch frame.messageType {
        case .json:
            guard let message = JSONFrame.decode(payload: frame.payload) else {
                Log.session.error("unparseable JSON frame")
                return
            }
            handleJSON(message)
        case .videoConfig:
            guard let config = try? VideoConfig(payload: frame.payload) else {
                Log.session.error("bad VIDEO_CONFIG payload")
                return
            }
            onVideoEvent?(.config(stream: frame.stream, config: config))
        case .videoFrame:
            guard let data = try? VideoFrameData(payload: frame.payload) else {
                Log.session.error("bad VIDEO_FRAME payload")
                return
            }
            LatencyLog.shared.noteVideoFrame(stream: frame.stream)
            onVideoEvent?(.frame(stream: frame.stream, frame: data))
        case .shareData:
            emit(.shareFileData(id: frame.stream, bytes: frame.payload))
        case .clipData:
            emit(.clipImageData(id: frame.stream, bytes: frame.payload))
        case .audioConfig:
            guard let config = try? AudioConfig(payload: frame.payload) else {
                Log.session.error("bad AUDIO_CONFIG payload")
                return
            }
            onAudioEvent?(.config(config))
        case .audioFrame:
            guard let data = try? AudioFrameData(payload: frame.payload) else {
                Log.session.error("bad AUDIO_FRAME payload")
                return
            }
            onAudioEvent?(.frame(data))
        default:
            Log.session.notice("ignoring phone->mac frame type \(frame.type, privacy: .public)")
        }
    }

    private func handleJSON(_ message: JSONMessage) {
        switch message.t {
        case "challenge":
            // A v1 phone sends its challenge right after hello; none of v1
            // survives in v2 (fixed decision), so surface the version mismatch.
            phoneErrorCode = "version"
            fail("version")
        case "pair.commit":
            // §4 step 1: the phone commits before the Mac releases its nonce.
            logExporterOnce()
            guard let hex = message.string("c"), let commit = Data(hexString: hex), commit.count == 32 else {
                phoneErrorCode = "pair_commit"
                fail("pair_commit"); return
            }
            remoteCommit = commit
            let nm = (0..<16).map { _ in UInt8.random(in: 0...255) }
            ourNm = Data(nm)
            sendJSON(["t": "pair.nonce", "n": Data(nm).hexString])
        case "pair.reveal":
            // §4 steps 3-4: verify the commitment, then both derive the code.
            guard let commit = remoteCommit, let nm = ourNm, nm.count == 16 else {
                phoneErrorCode = "pair_commit"
                fail("pair_commit"); return
            }
            guard let npHex = message.string("n"), let np = Data(hexString: npHex), np.count == 16 else {
                phoneErrorCode = "pair_commit"
                fail("pair_commit"); return
            }
            let macFp = Data(hexString: macFingerprintHex) ?? Data()
            let phoneFp = Data(hexString: learnedPeerPin) ?? Data()
            guard macFp.count == 32, phoneFp.count == 32 else {
                // Either end's fingerprint is unknown (no handshake learning):
                // a commit over unknown inputs cannot be trusted. §4: pair_commit.
                phoneErrorCode = "pair_commit"
                fail("pair_commit"); return
            }
            let expected = PairingCodeV2.commit(Np: np, phoneFp: phoneFp, macFp: macFp)
            guard expected == commit else {
                Log.session.error("pair commit mismatch: the reveal rehash differs")
                phoneErrorCode = "pair_commit"
                fail("pair_commit"); return
            }
            pendingNp = np
            guard let exporter = exporterProvider?() else {
                Log.session.error("no exporter on a pairing session")
                fail("tls"); return
            }
            let code = PairingCodeV2.code(exporter: Data(exporter), macFp: macFp, phoneFp: phoneFp, Nm: nm, Np: np)
            armPairingDeadline()
            Log.session.notice("pairing code derived for this screen: \(PairingCodeV2.codeHex(code), privacy: .public)")
            emit(.pairCodeShown(deviceId: knownDeviceId, code: PairingCodeV2.codeHex(code)))
        case "pair.qr":
            logExporterOnce()
            // R2: the phone proves the scan with HMAC(S, "pd-qr-v2" || exporter
            // || phoneFP); verified here, the phone's cert is pinned from the
            // handshake. The phone's Allow prompt still gates: it answers
            // pair.ok (no fields) after its person allows.
            guard let secret = qrSecret, let exporter = exporterProvider?() else {
                Log.session.error("pair.qr outside a QR probe session")
                phoneErrorCode = "pair_qr"
                fail("pair_qr"); return
            }
            let phoneFp = Data(hexString: learnedPeerPin) ?? Data()
            guard phoneFp.count == 32 else {
                Log.session.error("pair.qr without a handshake fingerprint")
                phoneErrorCode = "pair_qr"
                fail("pair_qr"); return
            }
            let expectedHmac = PairingCodeV2.qrHmac(secret: secret, exporter: Data(exporter), phoneFp: phoneFp)
            guard let receivedHex = message.string("m"),
                  let received = Data(hexString: receivedHex), received == expectedHmac else {
                Log.session.error("pair.qr HMAC rejected")
                phoneErrorCode = "pair_qr"
                fail("pair_qr"); return
            }
            sendJSON([
                "t": "pair.ok",
                "phoneFP": learnedPeerPin,
                "macFP": macFingerprintHex,
            ])
        case "pair.ok":
            logExporterOnce()
            if let fpHex = message.string("phoneFP") {
                // The pins-carrying shape (§4 code path): cross-check the pin we
                // learned from the handshake with what the phone shared.
                guard !learnedPeerPin.isEmpty, fpHex == learnedPeerPin else {
                    Log.session.error("pair.ok phoneFP disagrees with the handshake fingerprint")
                    phoneErrorCode = "pair_commit"
                    fail("pair_commit"); return
                }
            }
            // The person allowed on the phone. On the QR path the sheet
            // completes on the welcome that follows: the pin is stored there,
            // and the controller closes this probe as soon as it hears.
            emit(.pairApproved)
            if qrSecret != nil { qrApproved = true }
        case "welcome":
            logExporterOnce()
            guard let device = message.object("device"), let info = PhoneInfo(device: device) else {
                Log.session.error("welcome without device")
                return
            }
            if let strict = strictDeviceId, info.id != strict {
                // A cached address must keep belonging to the same phone.
                Log.session.error("address answers as \(info.id, privacy: .public), expected \(strict, privacy: .public); dropping")
                emit(.identityMismatch(expected: strict, actual: info.id))
                closeChannel()
                cancelTimers()
                intentionalClose = true
                transition(.failed(ConnectionFailure.identityMismatch), ConnectionFailure.identityMismatch)
                return
            }
            storePinFor(info: info)
            knownDeviceIdReal = info.id
            if qrApproved {
                qrApproved = false
                emit(.qrPaired(deviceId: info.id))
            }
            phone = info
            cancelTimers()
            startPing()
            let isReconnect = everReady
            everReady = true
            transition(.ready, nil)
            emit(.ready(info, isReconnect: isReconnect, address: dialedAddress))
        case "apps":
            let apps = (message.array("apps") ?? []).compactMap { AppInfo(json: $0) }
            emit(.apps(apps))
        case "icon":
            if let pkg = message.string("pkg"), let b64 = message.string("png"), let png = Data(base64Encoded: b64) {
                emit(.icon(pkg: pkg, png: png,
                           fg: message.data("fg"), bg: message.data("bg"), mono: message.data("mono")))
            }
        case "window.opened":
            emit(.windowOpened(stream: UInt32(message.int("stream") ?? 0),
                               displayId: message.int("displayId") ?? 0,
                               width: message.int("w") ?? 0,
                               height: message.int("h") ?? 0,
                               started: message.string("started") == "fresh" ? .fresh : .moved))
        case "window.closed":
            emit(.windowClosed(stream: UInt32(message.int("stream") ?? 0),
                               reason: message.string("reason") ?? ""))
        case "window.title":
            emit(.windowTitle(stream: UInt32(message.int("stream") ?? 0),
                              label: message.string("label") ?? "",
                              pkg: message.string("pkg") ?? ""))
        case "state":
            emit(.phoneState(locked: message.bool("locked") ?? false,
                             battery: message.int("battery") ?? 0,
                             charging: message.bool("charging") ?? false))
        case "audio.state":
            emit(.audioState(on: message.bool("on") ?? false,
                             codec: UInt8(message.int("codec") ?? 0)))
        case "pong":
            break
        case "clip.set":
            if let text = message.string("text") { emit(.clipboard(text)) }
        case "apk.progress":
            if let id = message.int("id"), let bytes = message.int("bytes") {
                emit(.apkProgress(id: UInt32(truncatingIfNeeded: id), bytes: bytes))
            }
        case "apk.result":
            if let id = message.int("id") {
                emit(.apkResult(ApkResult(id: UInt32(truncatingIfNeeded: id), ok: message.bool("ok") ?? false,
                                          code: message.string("code"), message: message.string("message"),
                                          pkg: message.string("pkg"), label: message.string("label"),
                                          version: message.string("version"))))
            }
        case "share.text":
            if let text = message.string("text") { emit(.shareText(text)) }
        case "share.file":
            if let id = message.int("id") {
                emit(.shareFileBegin(id: UInt32(truncatingIfNeeded: id), name: message.string("name") ?? "",
                                     mime: message.string("mime") ?? ""))
            }
        case "share.end":
            if let id = message.int("id") {
                emit(.shareFileEnd(id: UInt32(truncatingIfNeeded: id), size: message.int("size") ?? -1,
                                   sha256: message.string("sha256") ?? ""))
            }
        case "share.abort":
            if let id = message.int("id") { emit(.shareFileAbort(id: UInt32(truncatingIfNeeded: id))) }
        case "drop.progress":
            if let id = message.int("id"), let bytes = message.int("bytes") {
                emit(.dropProgress(id: UInt32(truncatingIfNeeded: id), bytes: bytes))
            }
        case "drop.result":
            if let id = message.int("id") {
                emit(.dropResult(DropResult(id: UInt32(truncatingIfNeeded: id), ok: message.bool("ok") ?? false,
                                            code: message.string("code"), message: message.string("message"),
                                            path: message.string("path"))))
            }
        case "clip.image.start":
            if let id = message.int("id") {
                emit(.clipImageBegin(id: UInt32(truncatingIfNeeded: id),
                                     mime: message.string("mime") ?? "",
                                     size: message.int("size") ?? -1))
            }
        case "clip.image.end":
            if let id = message.int("id") {
                emit(.clipImageEnd(id: UInt32(truncatingIfNeeded: id), size: message.int("size") ?? -1,
                                   sha256: message.string("sha256") ?? ""))
            }
        case "clip.image.abort":
            if let id = message.int("id") { emit(.clipImageAbort(id: UInt32(truncatingIfNeeded: id))) }
        case "notify.state":
            emit(.notifyState(on: message.bool("on") ?? false))
        case "notify.post":
            let whenMs = message.double("when")
            emit(.notifyPosted(id: message.string("id") ?? "", pkg: message.string("pkg") ?? "",
                               when: whenMs.map { Date(timeIntervalSince1970: $0 / 1000) },
                               title: message.string("title"), text: message.string("text")))
        case "notify.remove":
            emit(.notifyRemoved(id: message.string("id") ?? ""))
        case "media.state":
            emit(.mediaState(MediaState(
                playing: message.bool("playing") ?? false,
                pkg: message.string("pkg"),
                title: message.string("title"),
                artist: message.string("artist"),
                album: message.string("album"),
                durationMs: message.int("durationMs").map { Int64($0) },
                positionMs: message.int("positionMs").map { Int64($0) },
                rate: message.double("rate") ?? 0,
                receivedAt: Date().timeIntervalSince1970,
            )))
        case "error":
            let code = message.string("code") ?? "unknown"
            if message.int("stream") == nil { phoneErrorCode = code }
            emit(.phoneError(code: code, message: message.string("message"),
                             stream: UInt32(message.int("stream") ?? 0)))
        default:
            if !loggedUnknown.contains(message.t) {
                loggedUnknown.insert(message.t)
                Log.session.notice("ignoring unknown JSON t=\(message.t, privacy: .public)")
            }
        }
    }

    /// Pairing ended with `pair.ok` + `welcome`: keep the phone's pin record (cert
    /// + fingerprint learned at the handshake) and let the owner mirror §3's
    /// identity.json pin. Only reached right after a pairing session's success.
    private func storePinFor(info: PhoneInfo) {
        let pin = learnedPeerPin
        guard !pin.isEmpty else { return }
        var certPem = ""
        if let cert = aspectPeerCert, let der = try? cert.toDERBytes() {
            let b64 = Data(der).base64EncodedString()
            certPem = "-----BEGIN CERTIFICATE-----\n\(stripBase64Lines(b64))-----END CERTIFICATE-----\n"
        }
        let record = PinnedPhoneV2(deviceId: info.id, phoneFingerprintHex: pin, certPem: certPem)
        phonePinStore?.store(record)
        pinSessionEstablished?(record)
    }

    /// Dev and e2e bundles log the exporter hash for K4/e2e evidence; the
    /// release bundle (PDBuildVariant=release, as bundle.sh stamps it) logs
    /// neither the hash nor anything else derived from handshake secrets.
    static func logsExporterHash(variant: String?) -> Bool {
        variant != "release"
    }

    /// The 32 exporter's SHA-256, logged once per session (K4/e2e compare the
    /// two ends' hashes; the exporter itself and its keylog secret never leave
    /// memory). Nil-safe: a failed handshake logs nothing.
    private func logExporterOnce() {
        guard Self.logsExporterHash(variant: Bundle.main.object(forInfoDictionaryKey: "PDBuildVariant") as? String) else { return }
        guard !loggedExporterSha else { return }
        guard let exporter = exporterProvider?() else { return }
        loggedExporterSha = true
        let digest = SHA256.hash(data: Data(exporter))
        Log.session.notice("v2 exporter sha256: \(digest.map { String(format: "%02x", $0) }.joined(), privacy: .public)")
    }

    /// 76-char PEM body strip for the record's cert (base64 → lines).
    private func stripBase64Lines(_ b64: String) -> String {
        var out = ""
        var i = b64.startIndex
        while i < b64.endIndex {
            let end = b64.index(i, offsetBy: 64, limitedBy: b64.endIndex) ?? b64.endIndex
            out += b64[i..<end] + "\n"
            i = end
        }
        return out
    }
    // MARK: Ping

    private func startPing() {
        pingTimer?.invalidate()
        let timer = Timer(timeInterval: Self.pingInterval, repeats: true) { [weak self] _ in
            self?.sendJSON(["t": "ping", "ts": Int(Date().timeIntervalSince1970 * 1000)])
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    // MARK: Pairing API

    /// Carries the QR sheet's one-time secret `s` on a probe session (R2): the
    /// phone proves the scan by the `pair.qr` HMAC over the exporter.
    func useQRSecret(_ secret: Data) { qrSecret = secret }

    // MARK: Exporter

    /// The 32 exporter bytes of this connection attempt (pairing only).
    func attemptedExporter() -> [UInt8]? { exporterProvider?() }

    // MARK: Send

    private func emit(_ event: SessionEvent) {
        if Thread.isMainThread {
            onEvent?(event)
        } else {
            DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
        }
    }

    func sendBytes(_ bytes: [UInt8]) {
        connectionLock.lock()
        let ch = channel
        connectionLock.unlock()
        guard let ch else { return }
        var buf = ch.allocator.buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        _ = ch.writeAndFlush(buf)
    }

    func sendJSON(_ object: [String: Any]) {
        sendBytes(JSONFrame.encode(object))
    }

    func requestApps() { sendJSON(["t": "apps.list"]) }
    func requestIcon(pkg: String) { sendJSON(["t": "apps.icon", "pkg": pkg]) }
    func openApp(stream: UInt32, pkg: String, activity: String?, width: Int, height: Int, dpi: Double) {
        var message: [String: Any] = ["t": "window.open", "stream": Int(stream), "w": width, "h": height, "dpi": Int(dpi.rounded()), "pkg": pkg]
        if let activity { message["activity"] = activity }
        sendJSON(message)
    }
    func openLink(stream: UInt32, url: String, width: Int, height: Int, dpi: Double) {
        sendJSON(["t": "link.open", "stream": Int(stream), "w": width, "h": height, "dpi": Int(dpi.rounded()), "url": url])
    }
    func openPhone(stream: UInt32, width: Int, height: Int, dpi: Double) {
        sendJSON(["t": "window.open", "stream": Int(stream), "w": width, "h": height, "dpi": Int(dpi.rounded()), "mode": "phone"])
    }
    func continueTask(stream: UInt32, width: Int, height: Int, dpi: Double) {
        sendJSON(["t": "task.continue", "stream": Int(stream), "w": width, "h": height, "dpi": Int(dpi.rounded())])
    }
    func resizeWindow(stream: UInt32, width: Int, height: Int, dpi: Double) {
        sendJSON(["t": "window.resize", "stream": Int(stream), "w": width, "h": height, "dpi": Int(dpi.rounded())])
    }
    func closeWindow(stream: UInt32) { sendJSON(["t": "window.close", "stream": Int(stream)]) }
    func pauseWindow(stream: UInt32) { sendJSON(["t": "window.pause", "stream": Int(stream)]) }
    func resumeWindow(stream: UInt32) { sendJSON(["t": "window.resume", "stream": Int(stream)]) }
    func requestKeyframe(stream: UInt32) { sendJSON(["t": "window.keyframe", "stream": Int(stream)]) }
    func launch(stream: UInt32, pkg: String, activity: String?) {
        var message: [String: Any] = ["t": "window.launch", "stream": Int(stream), "pkg": pkg]
        if let activity { message["activity"] = activity }
        sendJSON(message)
    }
    func nav(stream: UInt32, action: String) { sendJSON(["t": "nav", "stream": Int(stream), "action": action]) }
    func startAudio(codecs: [Int] = [Int(AudioConfig.codecOpus), Int(AudioConfig.codecAAC)]) { sendJSON(["t": "audio.start", "codecs": codecs]) }
    func stopAudio() { sendJSON(["t": "audio.stop"]) }
    func text(stream: UInt32, text: String) { sendJSON(["t": "text", "stream": Int(stream), "text": text]) }
    func installApk(id: UInt32, files: [[String: Any]]) { sendJSON(["t": "apk.install", "id": Int(id), "files": files]) }
    func cancelApk(id: UInt32) { sendJSON(["t": "apk.cancel", "id": Int(id)]) }
    func enableNotifications(_ on: Bool) { sendJSON(["t": "notify.enable", "on": on]) }
    func mediaCommand(_ action: String) { sendJSON(["t": "media.command", "action": action]) }
    func sendApkData(id: UInt32, bytes: [UInt8], sent: @escaping @Sendable (Bool) -> Void) { sendData(.apkData, id: id, bytes: bytes, sent: sent) }
    func dropStart(id: UInt32, name: String, mime: String, size: Int, sha256: String, resume: Int = 0) {
        var message: [String: Any] = ["t": "drop.start", "id": Int(id), "name": name, "mime": mime, "size": size, "sha256": sha256]
        if resume > 0 { message["resume"] = resume }
        sendJSON(message)
    }
    func cancelDrop(id: UInt32) { sendJSON(["t": "drop.cancel", "id": Int(id)]) }
    func sendDropData(id: UInt32, bytes: [UInt8], sent: @escaping @Sendable (Bool) -> Void) { sendData(.dropData, id: id, bytes: bytes, sent: sent) }
    func clipImageStart(id: UInt32, mime: String, size: Int) { sendJSON(["t": "clip.image.start", "id": Int(id), "mime": mime, "size": size]) }
    func clipImageEnd(id: UInt32, size: Int, sha256: String) { sendJSON(["t": "clip.image.end", "id": Int(id), "size": size, "sha256": sha256]) }
    func clipImageAbort(id: UInt32) { sendJSON(["t": "clip.image.abort", "id": Int(id)]) }
    func sendClipData(id: UInt32, bytes: [UInt8], sent: @escaping @Sendable (Bool) -> Void) { sendData(.clipData, id: id, bytes: bytes, sent: sent) }
    private func sendData(_ kind: MessageType, id: UInt32, bytes: [UInt8], sent: @escaping @Sendable (Bool) -> Void) {
        guard let ch = channel else { return sent(false) }
        let frame = Frame(type: kind, stream: id, payload: bytes).encodedData()
        var buf = ch.allocator.buffer(capacity: frame.count)
        buf.writeBytes(frame)
        ch.writeAndFlush(buf).whenComplete { result in
            switch result {
            case .success: sent(true)
            case .failure: sent(false)
            }
        }
    }
    func sendClipboard(_ text: String) { sendJSON(["t": "clip.set", "text": text]) }
    func touch(_ event: TouchEvent, stream: UInt32) { sendBytes(Frame(type: .touch, stream: stream, payload: event.payload).encoded) }
    func scroll(_ event: ScrollEvent, stream: UInt32) { sendBytes(Frame(type: .scroll, stream: stream, payload: event.payload).encoded) }
    func hover(_ event: HoverEvent, stream: UInt32) { sendBytes(Frame(type: .hover, stream: stream, payload: event.payload).encoded) }
    func key(_ event: KeyEvent, stream: UInt32) { sendBytes(Frame(type: .key, stream: stream, payload: event.payload).encoded) }

    // MARK: Fail

    private func fail(_ transportReason: String) {
        if failedOnce { return }
        failedOnce = true
        closeChannel()
        cancelTimers()
        let reason = phoneErrorCode ?? transportReason
        phoneErrorCode = nil
        Log.session.notice("session failed: \(reason, privacy: .public)")
        if !intentionalClose {
            transition(.failed(reason), reason)
        } else {
            transition(.closed, nil)
        }
    }
}


extension Data {
    /// Lowercase hex -> bytes (used for the pair.ok key).
    init?(hexString: String) {
        guard hexString.count % 2 == 0, !hexString.isEmpty else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

final class SessionLockedBox<T> {
    private let lock = NSLock()
    private var underlying: T
    init(value: T) { underlying = value }
    func set(_ newValue: T) { lock.lock(); underlying = newValue; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return underlying }
}
