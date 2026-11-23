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

/// A source of paths (docs/design/paths.md §9). A provider moves bytes and
/// declares its class; it never reads a frame or decides a switch. The public
/// build has the LAN only; a direct build adds a provider without touching the
/// session layer, and a tunnel later is one more.
protocol PathProvider {
    var kind: PathKind { get }
    var availability: PathAvailability { get }
    /// Where this provider dials this phone; nil when it has no target.
    var endpoint: Session.Endpoint? { get }
}

/// The public build's provider: today's Bonjour discovery + TCP.
struct LanPathProvider: PathProvider {
    let endpoint: Session.Endpoint?
    let kind = PathKind.lan
    let availability = PathAvailability.ready
}

/// `state.lockSource` (PROTOCOL.md, MCP-31): which phone source gave `locked`.
enum PhoneLockSource: String, Equatable {
    case keyguardListener = "keyguard_listener"
    case broadcast
    case appRelay = "app_relay"
    case initialRead = "initial_read"
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
    /// The encoder's own limits (ISS-39); nil on a phone that sends no report.
    var encoder: EncoderSpec?

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
        encoder = EncoderSpec(json: device["encoder"])
    }
}

struct AppInfo: Equatable {
    var pkg: String
    var label: String
    var activity: String?
    /// Whether the phone can run a second instance of the app (WIN-24): the
    /// launcher declares it and the platform allows another task. A phone that
    /// says nothing counts as "one window at a time".
    var multi = false

    init?(json: [String: Any]) {
        guard let pkg = json["pkg"] as? String else { return nil }
        self.pkg = pkg
        label = json["label"] as? String ?? pkg
        activity = json["activity"] as? String
        multi = json["multi"] as? Bool ?? false
    }

    /// The identity a list entry is drawn and chosen by. A package can be
    /// launchable through more than one activity (a dual-messenger clone, a
    /// second launcher entry), and two entries with the same package gave the
    /// grid two equal ids: SwiftUI then draws neither of them, which is the
    /// person's empty slot. Launches already go by the activity, so it is the
    /// key here too.
    var id: String { activity ?? pkg }

    /// The words under the tile. A phone can send a blank label, or none at all
    /// (the decoder then carries the package as the label); the cell must still
    /// say what it opens, so the package's last part stands in for a dotted id.
    var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || trimmed == pkg else { return trimmed }
        return pkg.split(separator: ".").last.map(String.init) ?? pkg
    }
}

/// Video payloads, delivered off the main thread.
enum VideoEvent {
    case config(stream: UInt32, config: VideoConfig, picture: PictureRect)
    /// `path` is the path the frame arrived on, for the e2e frame log.
    case frame(stream: UInt32, frame: VideoFrameData, path: String)
    /// R6: the VIDEO_CHUNK assembler threw an incomplete access unit away.
    case chunkIncomplete(stream: UInt32)
}

enum SessionEvent {
    case state(SessionState, String?)
    case ready(PhoneInfo, isReconnect: Bool, address: CachedAddress?)
    /// PATH-17: no usable path; the windows say "reconnecting" at once and
    /// return to the live picture by themselves when a path joins.
    case pathsReconnecting(Bool)
    /// A switch completed: the owner asks each open stream for a keyframe.
    case pathsSwitched
    /// PATH-1: the phone refused this Mac's protocol version; the sentence
    /// names which app to update and the session stops retrying.
    case versionRefused(String)
    case apps([AppInfo])
    /// The adaptive layers ride along when the icon is one (`icon` message).
    case icon(pkg: String, png: Data, fg: Data?, bg: Data?, mono: Data?)
    case windowOpened(stream: UInt32, displayId: Int, width: Int, height: Int,
                      started: HandoffStart)
    /// `window.opened`'s `taskId` (WIN-25): the phone's own task for the
    /// display, kept to name and close the right window.
    case windowTask(stream: UInt32, taskId: Int)
    /// `window.task` (WIN-44): the app started a task of its own while one of
    /// its apps was streamed. The Mac decides with the New-item rule (WIN-45).
    case appTaskArrived(stream: UInt32, taskId: Int, pkg: String, label: String?)
    /// `state.maxWindows`: the most app windows the phone allows at once
    /// (WIN-32); a phone that reports none never sends this.
    case maxWindows(Int)
    case windowClosed(stream: UInt32, reason: String)
    /// `window.resize.ack`: the phone answered a `window.resize` with what it
    /// did (resized, density only, same, or refused).
    case windowResizeAck(stream: UInt32, width: Int, height: Int, dpi: Int, outcome: String)
    /// `window.title`: the app the display shows (`label`, `pkg`) and, on an
    /// app or link stream, the task's own label (`title`, WIN-28). The two
    /// stay apart: a link or handoff window names its app, an app window names
    /// its task.
    case windowTitle(stream: UInt32, label: String, pkg: String, title: String?)
    /// `window.still`: the stream is live but its encoder produced no output
    /// (PHONE-21). A picture heartbeat, never a first frame.
    case windowStill(stream: UInt32)
    /// One `stream.stats` message: the phone's counters for that stream's last
    /// window (nil fields when the phone or its codec has none).
    case phoneStats(stream: UInt32, stats: PhoneStreamStats)
    case phoneState(locked: Bool, battery: Int, charging: Bool, dnd: PhoneDndMode?, ringer: PhoneRingerMode?,
                    volume: Int?, volumeMax: Int?, screen: PhoneScreen?, secure: Bool?, panel: PhonePanel?,
                    lockSource: PhoneLockSource? = nil)
    /// `task.front`: the app in front on the phone's own screen, as one read
    /// (docs/PROTOCOL.md "Foreground app"). `seq` echoes the request; `pkg` is
    /// nil when nothing continuable was in front.
    case frontApp(seq: Int, pkg: String?)
    /// `ui.tree` (docs/PROTOCOL.md "UI tree", WIN-79): the accessibility tree of
    /// the display a stream's window lives on. `seq` echoes the request.
    case uiTree(UITree)
    /// `ui.settle` (PROTOCOL.md "UI tree" item 7, MCP-81): the phone's answer
    /// to "has this display stopped changing". `seq` echoes the request.
    case uiSettle(UISettleReply)
    /// `ui.press` (PROTOCOL.md "UI tree" item 8, MCP-86).
    case uiPress(UIPressReply)
    /// `ui.type` (PROTOCOL.md "UI tree" item 10, MCP-109).
    case uiType(UITypeReply)
    /// `ring.state`: a `phone.ring` started or ended.
    case ringState(ringing: Bool)
    /// `power.locked`: the phone's own power press with app streams up (its VD
    /// group re-lights; the windows hold their last frame for a short grace).
    case powerLocked
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
    /// The phone wrote a clipboard image (SHARE-16's paste flow).
    case clipImageDone(id: UInt32, ok: Bool)
    /// Share phone → Mac (docs/design/sharein.md).
    case shareText(String)
    case shareFileBegin(id: UInt32, name: String, mime: String)
    case shareFileData(id: UInt32, bytes: [UInt8])
    case shareFileEnd(id: UInt32, size: Int, sha256: String)
    case shareFileAbort(id: UInt32)
    /// Read-only phone files (docs/design/files.md): list/stat/read replies.
    case fsItems(id: UInt32, page: String?, digest: String?, items: [[String: Any]])
    case fsItem(id: UInt32, item: [String: Any])
    /// One `fs.digest` reply: path → a hex digest or "not_found".
    case fsDigest(id: UInt32, digests: [String: Any])
    case fsData(id: UInt32, bytes: [UInt8])
    case fsReadEnd(id: UInt32, size: Int, sha256: String)
    case fsThumbEnd(id: UInt32, mime: String, size: Int, sha256: String)
    /// A write's confirmed bytes (docs/PROTOCOL.md "Phone files").
    case fsProgress(id: UInt32, bytes: Int)
    /// A write or mutation finished; `item` is the new metadata on success.
    case fsResult(id: UInt32, ok: Bool, item: [String: Any]?, code: String?, message: String?)
    /// A watched folder's contents moved (docs/design/files.md §5).
    case fsChanges(paths: [String])
    case fsError(id: UInt32, code: String, message: String?)
    /// Notifications + media controls (docs/design/notify.md). `reason` is
    /// `no_access` when the Mac asked but the phone's listener grant is missing.
    case notifyState(on: Bool, reason: String?)
    case notifyPosted(id: String, pkg: String, when: Date?, title: String?, text: String?,
                      actions: [NotifyActionInfo], ongoing: Bool, live: NotifyLive? = nil,
                      alert: Bool, group: String? = nil)
    /// The picture that follows a `notify.post` (docs/design/notify.md, 2b).
    case notifyImage(id: String, mime: String, width: Int, height: Int, data: Data)
    case notifyRemoved(id: String)
    /// The phone's complete active set after a rejoin (NOTIFY-1): every id it
    /// still holds, sent after a quiet post for each one.
    case notifySnapshot(ids: [String])
    case mediaState(MediaState)
    /// "Media part 2": the active sessions and the chosen one, and the chosen
    /// session's artwork. A phone that does not know them never sends them.
    case mediaSessions([MediaSessionRow], chosen: String?)
    case mediaArt(key: String, mime: String?, width: Int?, height: Int?, data: Data?)
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
    /// N1's Mac side (ISS-40): read when this session dials, not per window.
    private var netStrategy: MacStreamStrategy.Net = .default
    /// One `session mac strategy:` line per session, written on the first
    /// installed channel (only there is the socket's read-back known).
    private var loggedSessionStrategy = false
    /// Every provider's dial target, in planner order (PATH-20). The public
    /// build has one (the LAN); a test may start a second LAN provider.
    private let providers: [PathProvider]
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

    private let queue = DispatchQueue(label: "app.contigua.session")
    private var exporterProvider: (() -> [UInt8]?)?
    private var eventLoopGroup: EventLoopGroup?
    private var ownsGroup: Bool = false

    private var decoder = FrameDecoder()
    /// window.content for each stream, waiting for the VIDEO_CONFIG it precedes (read on the reader).
    private var pendingPictures: [UInt32: PictureRect] = [:]
    /// R4: one incomplete chunked access unit per stream.
    private var videoChunks = VideoChunkAssembler()
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
    /// The pings whose pong has not arrived, by `ts`, with the Mac monotonic µs
    /// when each went out (for the clock-offset estimate).
    private var pingSentUs: [Int: Double] = [:]
    private let clockLock = NSLock()
    private var clockEstimator = ClockOffsetEstimator()
    private var pathTimer: Timer?
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

    // MARK: Paths (docs/design/paths.md §3–§9)

    /// One dialed path. The session queue owns every field.
    private struct Attempt {
        let id: String
        let endpoint: Endpoint
        var channel: Channel?
        var sendRaw: (@Sendable ([UInt8]) -> Void)?
        /// NIO's writability and read switch for this channel (D-2, R-11).
        var isWritable: (@Sendable () -> Bool)?
        var setReading: (@Sendable (Bool) -> Void)?
        var exporter: (() -> [UInt8]?)?
        var timer: DispatchWorkItem?  // gcd: the session's one timeout timer per attempt
        /// dialing -> ready -> hello/join -> welcomed, or failed (R-14).
        var machine = AttemptMachine()
        /// The dial used a pin: only such a path may join.
        var dialedPinned = false
        /// Which provider dialed it: a missing provider is re-dialed on the
        /// reconnect backoff while the session is below its path target (D-3).
        let providerIndex: Int
        /// A rejoin dial: its hello carries `join` at once (D-3).
        var rejoin = false
        /// A silence probe (PATH-24): a join beside a live path, never a
        /// start and never the orphan's own rejoin.
        var probeJoin = false
        /// The dialed host:port, for the cached address (C10).
        var address: CachedAddress?
        let kind: PathKind
    }

    private let pathLayer = PathLayer(log: { line in
        Log.session.notice("paths: \(line, privacy: .public)")  // log-ok: closed tokens and a byte count, never a value from the wire
    })
    private var pathStart = PathStart()
    private var attempts: [String: Attempt] = [:]
    private var attemptReasons: [String: String] = [:]
    /// The pin and the handshake-learned values every dial uses (a rejoin dial
    /// happens long after doConnect). A pairing session adopts the pin its
    /// pairing established, so its own rejoins are verified joins (PATH-52).
    private var dialPin: SessionPinState = .pairing(verified: false)
    private var dialLearned = SessionLockedBox(value: "")
    private var dialLearnedCert = SessionLockedBox<NIOSSLCertificate?>(value: nil)
    /// path id -> the provider that dialed it: a provider with no path and no
    /// attempt is missing and gets re-dialed (D-3).
    private var pathProvider: [String: Int] = [:]
    /// The orphan's rejoin schedule (E-11c): back-to-back with a 2.0 s timeout
    /// inside the grace, the reconnect backoff outside it.
    private var pathRejoin = PathRejoinMachine()
    /// True once a path was attached: a later path reaching an empty layer is
    /// a rejoin, not the founder (it replays instead of starting). Derived from
    /// the machine, never a flag beside it (RR-14).
    private var everAttached: Bool {
        if case .unfounded = pathMachine.state { return false }
        return true
    }
    /// Pre-welcome sends travel bare on the one attempt holding the plain
    /// hello (PATH-2). The box carries the decision across threads; the
    /// session queue clears it at the founding welcome (R-4/R-7).
    private let preWelcomeSender = SessionLockedBox<(@Sendable ([UInt8]) -> Void)?>(value: nil)
    /// Set once a `welcome` founded the session: from then on every frame is a
    /// path-layer frame, even with no path attached (PATH-6). The box is the
    /// one cross-thread view of [pathSessionId]; there is no second flag
    /// (RR-14).
    private let pathSessionId = SessionLockedBox<String?>(value: nil)
    /// X0: one `TCP_CONNECTION_INFO` reader per attached path. The stats lines
    /// read the current path's (the video is one connection); a closed path's
    /// reader is stopped so no timer outlives it.
    private let tcpInfoReaders = SessionLockedBox<[String: TCPInfoReader]>(value: [:])
    private var lastFramePath: String?
    private var pathMachine = PathSessionMachine()
    private var pathRanking = PathRanking()
    /// PATH-24: the single-path silence probe and its one dial in flight.
    private var pathProbe = PathProbeMachine()
    private var probeAttemptId: String?
    /// D-1: the phone's screen state from the last `state` message. A session
    /// that has not heard one yet counts as active (the safe default).
    private var phoneScreenOn = true
    private var reconnectingEmitted = false
    /// The Mac's notification opt-in for this session (NOTIFY-1): repeated on a
    /// rejoin after an outage, so the phone resends its active set. A box
    /// because the controller sets it from main and the session queue reads it.
    private let notifyEnabled = SessionLockedBox(value: false)
    private var pairingAttempt = false
    /// The founding path's phone identity, for the pairing pin record.
    private var foundingPeerPin = ""
    private var foundingPeerCert: NIOSSLCertificate?
    /// The streams this session closed: no later message may go out for one
    /// (WIN-38). Guarded by its own lock: sends come from the main thread, the
    /// session queue and the video queue.
    private var closedStreams = ClosedStreams()
    private let closedStreamsLock = NSLock()

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

    /// The phone's session-level error codes (docs/PROTOCOL.md "Error codes"):
    /// an `error` naming one of these is the session's, and the phone closes
    /// after it. `Session.sendError` always writes `stream: 0` for them, so the
    /// classification must accept stream 0 as well as a missing field (R2:
    /// `pair_cooldown` was read as a TLS failure because it carried stream 0).
    static let sessionErrorCodes: Set<String> = [
        "version", "bad_pin", "connections_off", "pairing_off", "not_paired",
        "no_session", "busy", "too_many_paths", "protocol", "forgotten",
        "pair_denied", "pair_timeout", "pair_cooldown", "pair_exporter",
        "pair_commit",
    ]

    private let connectTimeout: TimeInterval
    private let pairingTimeout: TimeInterval
    /// `--debug-no-margin-switch`: the e2e check's broken build; the ranking's
    /// margin switch is ignored, every other switch (failover, probe) stays.
    private let debugNoMarginSwitch: Bool

    // MARK: Inits

    /// The designated init: the owner decides the identity (profile-loaded),
    /// the pin record (nil = pairing) and the shared pin store.
    init(endpoint: Endpoint, endpoints: [Endpoint]? = nil,
         knownDeviceId: String?, strictDeviceId: String? = nil,
         clientId: String, identity: DeviceIdentityV2? = nil,
         pinnedPhone: PinnedPhoneV2? = nil, pinStore: PhonePinStoreV2? = nil,
         onPinEstablished: ((PinnedPhoneV2) -> Void)? = nil,
         group: EventLoopGroup? = nil,
         connectTimeout: TimeInterval = Session.defaultConnectTimeout,
         pairingTimeout: TimeInterval = Session.defaultPairingTimeout,
         debugNoMarginSwitch: Bool = false) {
        self.endpoint = endpoint
        self.debugNoMarginSwitch = debugNoMarginSwitch
        self.providers = (endpoints ?? [endpoint]).map { LanPathProvider(endpoint: $0) }
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
    convenience init(endpoint: Endpoint, endpoints: [Endpoint]? = nil,
                     knownDeviceId: String?, strictDeviceId: String? = nil,
                     clientId: String,
                     connectTimeout: TimeInterval = Session.defaultConnectTimeout,
                     pairingTimeout: TimeInterval = Session.defaultPairingTimeout) {
        self.init(endpoint: endpoint, endpoints: endpoints,
                  knownDeviceId: knownDeviceId, strictDeviceId: strictDeviceId,
                  clientId: clientId, identity: nil,
                  connectTimeout: connectTimeout, pairingTimeout: pairingTimeout)
    }

    // MARK: Lifecycle

    func start() {
        intentionalClose = false
        failedOnce = false
        // The session's own strategy key, read here rather than at a window's
        // open: the dial needs it (N1). One line per session, once the
        // socket exists, so `net_svc` can be read back.
        netStrategy = MacStreamStrategy.read(from: Profile.active.defaults).net
        transition(.connecting, nil)
        queue.async { [weak self] in self?.doConnect() }
    }

    private func doConnect() {
        guard !intentionalClose else { return }

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
        pairingAttempt = pinned == nil && pairingPolicy == .allowed

        if eventLoopGroup == nil {
            eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            ownsGroup = true
        }
        let group = eventLoopGroup!
        let learned = SessionLockedBox(value: "")
        let learnedCert = SessionLockedBox<NIOSSLCertificate?>(value: nil)
        learnedPinProvider = { learned.get() }
        learnedCertProvider = { learnedCert.get() }
        dialLearned = learned
        dialLearnedCert = learnedCert
        dialPin = pinned.map { .pinned($0) } ?? .pairing(verified: false)

        // PATH-20: every ready provider starts at once and only the hello is
        // serialized. PathStart hands the one plain hello to the first attempt
        // whose TLS is up and every other finished attempt joins the session.
        var live = Set<String>()
        var started: [(index: Int, provider: PathProvider, id: String)] = []
        for (index, provider) in readyProviders() {
            let id = PathIds.pathId(among: live)
            live.insert(id)
            started.append((index, provider, id))
        }
        pathStart = PathStart()
        pathProbe = PathProbeMachine()
        pathRejoin = PathRejoinMachine()
        probeAttemptId = nil
        _ = pathStart.handle(.start(started.map(\.id)))
        for item in started {
            startDial(index: item.index, provider: item.provider, join: false, id: item.id)
        }
    }

    /// The ready providers with their index, the target the rejoin dials up to.
    private func readyProviders() -> [(Int, PathProvider)] {
        providers.enumerated().compactMap { index, provider in
            provider.availability.isReady && provider.endpoint != nil ? (index, provider) : nil
        }
    }

    /// One dial: a start attempt (PathStart owns its hello) or a rejoin (D-3).
    /// `timeout` overrides the session's general one for a path that has its
    /// own deadline (E-11b's probe, E-11c's orphaned rejoin).
    private func startDial(index: Int, provider: PathProvider, join: Bool, id: String,
                           probe: Bool = false, timeout: TimeInterval? = nil) {
        guard let endpoint = provider.endpoint else { return }
        attempts[id] = Attempt(id: id, endpoint: endpoint,
                               dialedPinned: dialPin.isPinned,
                               providerIndex: index,
                               rejoin: join,
                               probeJoin: probe,
                               kind: provider.kind)
        let timer = DispatchWorkItem { [weak self] in  // gcd: the session's one deadline timer
            guard let self else { return }
            self.queue.async { self.attemptFailed(id, reason: "timeout") }
        }
        attempts[id]?.timer = timer
        // E-11b: a probe has its own 2.0 s connect timeout; the session's first
        // connect keeps the general one.
        let deadline = timeout ?? (probe ? PathProbeMachine.connectTimeout : connectTimeout)
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline, execute: timer)  // gcd: a deadline timer hops back to the session queue
        let group = eventLoopGroup!
        let learned = dialLearned
        let learnedCert = dialLearnedCert
        let pinned = dialPin.record
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in  // gcd: the TLS handshake blocks; one thread per path is the point
            self?.dial(id: id, endpoint: endpoint, pinned: pinned, group: group,
                       learned: learned, learnedCert: learnedCert)
        }
    }

    /// One provider's dial, off the session queue: resolution and the TLS
    /// handshake block, and the providers must run at the same time (§9.1).
    private func dial(id: String, endpoint: Endpoint, pinned: PinnedPhoneV2?,
                      group: EventLoopGroup,
                      learned: SessionLockedBox<String>,
                      learnedCert: SessionLockedBox<NIOSSLCertificate?>) {
        guard let target = resolveTarget(endpoint) else {
            queue.async { [weak self] in self?.attemptFailed(id, reason: "resolve") }
            return
        }
        let connector = TlsConnectorV2(identity: identity, pinnedPhone: pinned, group: group)
        do {
            let result = try connector.connect(host: target.host, port: target.port,
                net: netStrategy,
                onFrame: { [weak self] frame in
                    guard let self else { return }
                    self.queue.async { self.handlePathFrame(id, frame) }
                }, onError: { [weak self] message in
                    guard let self else { return }
                    self.queue.async { self.handlePathError(id, message) }
                }, onPeerPin: { fingerprint in learned.set(fingerprint) },
                onPeerCert: { cert in learnedCert.set(cert) },
                onWritableChange: { [weak self] writable in
                    guard let self, writable else { return }
                    self.queue.async { self.pathLayer.writable(id) }
                })
            queue.async { [weak self] in
                self?.install(id, result: result, target: target)
            }
        } catch let error as TlsV2Error {
            let reason: String
            switch error {
            case .pinMismatch: reason = "pin-mismatch"
            case .noPin: reason = "no-pin"
            default: reason = "tls"
            }
            queue.async { [weak self] in self?.attemptFailed(id, reason: reason) }
        } catch {
            let message = String(describing: error)
            // A mid-handshake verify failure IS the stale-pin refusal (§7).
            // A server alert means the PHONE refused this Mac's certificate
            // after our own pin passed (PAIR-31): its own token, counted twice.
            let lowered = message.lowercased()
            let reason: String
            if lowered.contains("certificate_verify_failed") || lowered.contains("certificate verify") {
                reason = "pin-mismatch"
            } else if lowered.contains("certificate unknown") || lowered.contains("certificate_unknown") {
                reason = "certificate_unknown"
            } else if lowered.contains("bad certificate") || lowered.contains("bad_certificate") {
                reason = "bad_certificate"
            } else {
                reason = "tls"
            }
            queue.async { [weak self] in self?.attemptFailed(id, reason: reason) }
        }
    }

    /// A provider's TLS handshake completed. Runs on the session queue.
    private func install(_ id: String,
                         result: (channel: Channel, exporter: () -> [UInt8]?, send: @Sendable (Frame) -> Void,
                                  isWritable: @Sendable () -> Bool, setReading: @Sendable (Bool) -> Void,
                                  serviceType: Int32?),
                         target: (host: String, port: Int)) {
        guard !intentionalClose, var attempt = attempts[id],
              attempt.machine.phase == .dialing else {
            result.channel.close()
            return
        }
        if !loggedSessionStrategy {
            loggedSessionStrategy = true
            let service = result.serviceType.map(String.init) ?? "-"
            Log.session.notice("session mac strategy: net=\(self.netStrategy.rawValue, privacy: .public) net_svc=\(service, privacy: .public)")  // log-ok: a closed token and the socket's own reading
        }
        attempt.channel = result.channel
        attempt.exporter = result.exporter
        attempt.isWritable = result.isWritable
        attempt.setReading = result.setReading
        attempt.sendRaw = { bytes in
            guard let frame = Frame(encoded: bytes) else { return }
            result.send(frame)
        }
        attempt.address = UInt16(exactly: target.port).map { CachedAddress(host: target.host, port: $0) }
        attempts[id] = attempt
        attemptEvent(id, .tlsReady)
        if state == .connecting { transition(.handshaking, nil) }
        Log.session.info("tls connected (path \(id, privacy: .public)); hello v\(PathVersion.current, privacy: .private)")
        if attempts[id]?.rejoin == true, let session = pathSessionId.get() {
            // D-3: the orphan's own dial joins the session it was on.
            sendHello(on: id, join: session)
        } else {
            performStart(pathStart.handle(.ready(id)))
        }
    }

    private func performStart(_ actions: [PathStartAction]) {
        for action in actions {
            switch action {
            case .sendPlainHello(let id):
                sendHello(on: id, join: nil)
            case .sendJoin(let ids, let session):
                for id in ids { sendHello(on: id, join: session) }
            case .sessionFounded:
                break
            case .fail:
                fail(attemptReasons.values.first ?? "tls")
            }
        }
    }

    /// Records one attempt transition and logs it (`attempt: <from> --<event>--> <to>`).
    /// Runs on the session queue, where the attempt record lives (R-14).
    private func attemptEvent(_ id: String, _ event: AttemptEvent) {
        guard var attempt = attempts[id] else { return }
        let before = attempt.machine.phase
        _ = attempt.machine.handle(event)
        attempts[id] = attempt
        guard before != attempt.machine.phase else { return }
        Log.session.notice("attempt: \(before.token, privacy: .public) --\(event.token, privacy: .public)--> \(attempt.machine.phase.token, privacy: .public) (path \(id, privacy: .public))")  // log-ok: closed phase tokens and a path id
    }

    /// The hello's codec list (WIN-59): AVC always, HEVC only when VideoToolbox
    /// reports hardware decode. A Mac with no list (an older build) means AVC.
    static func helloCodecs(hevcHardware: Bool = VideoCodec.hevcHardwareSupported) -> [String] {
        VideoCodec.hardwareTokens(hevcSupported: hevcHardware)
    }

    /// Sends this path's `hello` directly (no seq space exists before welcome).
    private func sendHello(on id: String, join: String?) {
        guard let attempt = attempts[id], let send = attempt.sendRaw else {
            // Without a hello there is no welcome; a rejoin's ending must still
            // reach the schedule exactly once (ISS-95).
            closeAttempt(id)
            return
        }
        if let join {
            // Only a pinned TLS connection may join (PATH-3): TLS is the only
            // authentication, and a pairing-mode one has verified nothing. The
            // phone would answer such a peer `busy` (PATH-11), so the attempt
            // ends here — and reports that ending, or the rejoin schedule would
            // stay in flight until the grace ends (ISS-95).
            guard attempt.dialedPinned else {
                Log.session.notice("paths: join refused, this attempt's TLS is unpinned (path \(id, privacy: .public))")  // log-ok: a path id
                closeAttempt(id)
                return
            }
        }
        var hello: [String: Any] = [
            "t": "hello", "v": PathVersion.current, "path": id,
            "clientId": clientId, "name": ClientIdentity.name, "id": identity.deviceId,
            "codecs": Self.helloCodecs(),
            // R4: this Mac reassembles VIDEO_CHUNK fragments, so a phone may
            // split a large access unit and let audio pass between the pieces.
            "videoChunks": true,
        ]
        if let join { hello["join"] = join }
        if pairingAttempt, join == nil { hello["pair"] = true }
        // Through the one recorder, so `ready --hello--> hello` is logged like
        // every other attempt transition (R-14): the machine call here was
        // silent.
        attemptEvent(id, .sentHello(join: join))
        send(Frame(type: MessageType.json.rawValue, stream: 0, payload: JSONFrame.payload(hello)).encoded)
        if join == nil {
            preWelcomeSender.set(send)
            exporterProvider = attempt.exporter
            if pairingAttempt {
                send(Frame(type: MessageType.json.rawValue, stream: 0,
                           payload: JSONFrame.payload(["t": "pair.request"])).encoded)
            }
        }
    }

    private func attemptFailed(_ id: String, reason: String) {
        guard !intentionalClose, let attempt = attempts[id] else { return }
        // A late timer for a path that already welcomed is not a failure.
        if attempt.machine.phase.isWelcomed || pathLayer.hasPath(id) {
            attempt.timer?.cancel()
            return
        }
        attemptReasons[id] = reason
        closeAttempt(id, failure: reason)
    }

    /// A rejoin dial failed: inside the grace the next tick dials at once
    /// (E-11c); outside it the reconnect backoff holds the next round (D-3).
    private func rejoinFailed() {
        let now = uptime
        dispatchRejoin(.failed(orphaned: pathMachine.isOrphaned, now: now), now: now)
    }

    /// Runs one rejoin-schedule event, logs any transition (`rejoin: <from>
    /// --<event>--> <to>`) and performs the dial it asks for.
    private func dispatchRejoin(_ event: PathRejoinEvent, now: TimeInterval,
                                missing: [(Int, PathProvider)] = []) {
        let before = pathRejoin.state
        let actions = pathRejoin.handle(event, now: now)
        if before != pathRejoin.state {
            let from = before.token
            let to = pathRejoin.state.token
            Log.session.notice("rejoin: \(from, privacy: .public) --\(event.token, privacy: .public)--> \(to, privacy: .public)")  // log-ok: closed state and event tokens
        }
        for action in actions {
            guard case .dial = action else { continue }
            var live = Set(attempts.keys)
            for id in pathLayer.pathIds { live.insert(id) }
            let orphaned = pathMachine.isOrphaned
            Log.session.notice("paths: rejoin round, \(missing.count, privacy: .public) provider(s), orphaned \(orphaned ? 1 : 0)")  // log-ok: a count and a closed flag
            for item in missing {
                let id = PathIds.pathId(among: live)
                live.insert(id)
                // E-11c: an orphaned rejoin gives up on its own 2.0 s.
                startDial(index: item.0, provider: item.1, join: true, id: id,
                          timeout: orphaned ? PathRejoinMachine.connectTimeout : nil)
            }
        }
    }

    /// Dials the providers that have neither a path nor an attempt while the
    /// session is below the paths its providers can give (D-3: orphaned or a
    /// path short). Runs on the session queue's tick.
    private func maintainPaths() {
        guard !intentionalClose, pathSessionId.get() != nil else { return }
        let ready = readyProviders()
        guard !ready.isEmpty else { return }
        let target = min(ready.count, PathLayer.maxPaths)
        let dialing: Set<Int> = Set(attempts.values.map(\.providerIndex))
        var attached: Set<Int> = Set(pathProvider.values)
        attached.formUnion(dialing)
        let missing = ready.filter { !attached.contains($0.0) }
        let needed = !missing.isEmpty && pathLayer.pathCount + attempts.count < target
        dispatchRejoin(.tick(needed: needed, orphaned: pathMachine.isOrphaned, now: uptime),
                       now: uptime, missing: needed ? missing : [])
    }

    // MARK: The single-path silence probe (PATH-24, E-11)

    /// True while an open stream expects a moving picture: a paused or covered
    /// one sends no frames by design, so its silence proves nothing.
    private var streamLiveForProbe: Bool {
        closedStreamsLock.lock()
        defer { closedStreamsLock.unlock() }
        return closedStreams.hasLiveStream
    }

    /// E-11's trigger and retry, once per 0.25 s tick.
    private func tickProbe() {
        let silent = pathLayer.currentPath.flatMap { pathLayer.silentFor($0) } ?? 0
        let event = PathProbeEvent.tick(pathCount: pathLayer.pathCount,
                                        streamLive: streamLiveForProbe,
                                        silentFor: silent)
        for action in pathProbe.handle(event, now: uptime) {
            switch action {
            case .dial: startProbe()
            case .cancel: cancelProbe()
            case .ignore: break
            }
        }
    }

    /// PATH-24: one join beside the live path, on a ready provider with no
    /// path, else the current path's own provider (a second TCP connection to
    /// the same endpoint).
    private func startProbe() {
        guard probeAttemptId == nil, let current = pathLayer.currentPath else { return }
        let ready = readyProviders()
        guard let pick = ready.first(where: { !pathProvider.values.contains($0.0) })
                ?? ready.first(where: { $0.0 == pathProvider[current] })
                ?? ready.first else { return }
        var live = Set(attempts.keys)
        for id in pathLayer.pathIds { live.insert(id) }
        let id = PathIds.pathId(among: live)
        probeAttemptId = id
        Log.session.notice("paths: probe \(id, privacy: .public) (paths \(self.pathLayer.pathCount, privacy: .public))")  // log-ok: a path id and a count
        startDial(index: pick.0, provider: pick.1, join: true, id: id, probe: true)
    }

    /// The probe is no longer wanted: close its dial and forget it.
    private func cancelProbe() {
        guard let id = probeAttemptId else { return }
        probeAttemptId = nil
        // The probe machine already returned to idle on the cancel: its
        // ending reports nothing.
        if attempts[id] != nil { closeAttempt(id, reports: false) }
    }

    private func probeFailed() {
        probeAttemptId = nil
        _ = pathProbe.handle(.failed, now: uptime)
    }

    /// The probe welcomed. E-11 switches at once only while the old path is
    /// still silent; otherwise PATH-7's two-path ping rule takes over. The old
    /// path is never failed or closed by this.
    private func probeWelcomed(_ id: String) {
        probeAttemptId = nil
        _ = pathProbe.handle(.welcomed, now: uptime)
        let silent = pathLayer.currentPath.flatMap { pathLayer.silentFor($0) } ?? 0
        handlePath(.probeWelcomed(id: id, oldSilent: silent >= PathProbeMachine.silence))
    }

    /// One path's channel ended. Before welcome that is a failed attempt; after
    /// it, one path died and the session lives on (§6).
    private func handlePathError(_ id: String, _ message: String) {
        if pathLayer.hasPath(id) {
            // Boot 6 left no trace of which side closed a live path: name the
            // class, never the message (R-PRIV-1).
            let token: String
            if message.contains("closed-by-peer") { token = "closed-by-peer" }
            else if message.hasPrefix("framing") { token = "framing" }
            else if message.hasPrefix("tls") { token = "tls" }
            else { token = "other" }
            Log.session.notice("paths: path down \(id, privacy: .public) (\(token, privacy: .public))")  // log-ok: closed reason token, never the wire message
            let wasCurrent = pathLayer.currentPath == id
            dropPath(id)
            handlePath(wasCurrent ? .currentFailed(id: id) : .pathDown(id: id))
            return
        }
        guard attempts[id] != nil else { return }
        var reason = "tls"
        let lowered = message.lowercased()
        if message.contains("closed-by-peer") {
            if !everReady && phoneErrorCode == nil { reason = "closed-early" }
        } else if lowered.contains("certificate_verify_failed") || lowered.contains("certificate verify failed") {
            reason = "pin-mismatch"
        } else if lowered.contains("certificate unknown") || lowered.contains("certificate_unknown") {
            reason = "certificate_unknown"
        } else if lowered.contains("bad certificate") || lowered.contains("bad_certificate") {
            reason = "bad_certificate"
        }
        attemptReasons[id] = reason
        closeAttempt(id, failure: reason)
    }

    /// Ends one attempt that never became a path. `failure` records a failed
    /// transition (otherwise the attempt is closed); `reports` hands the ending
    /// to the machine that owns the round — PathStart, the silence probe, the
    /// orphan's rejoin schedule — exactly once, from the one place that removes
    /// the attempt. A join whose ending went unreported left the rejoin
    /// schedule in flight until the grace ended (ISS-95); a session that is
    /// closing reports nothing, because no machine will dial again.
    private func closeAttempt(_ id: String, failure: String? = nil, reports: Bool = true) {
        guard let attempt = attempts[id] else { return }
        attempt.timer?.cancel()
        attemptEvent(id, failure.map { .failed(reason: $0) } ?? .closed)
        attempts.removeValue(forKey: id)
        if let channel = attempt.channel { channel.close() }
        guard reports else { return }
        if attempt.probeJoin {
            probeFailed()
        } else if attempt.rejoin {
            rejoinFailed()
        } else if let failure {
            performStart(pathStart.handle(.attemptFailed(id)))
        }
    }

    /// Ends one attached path: closes its channel and forgets the provider that
    /// dialed it, so a provider with no path is missing and gets re-dialed
    /// (E-5/PATH-22). Every detach goes through here: the machine's closePath,
    /// a socket error, a joined-path timeout and the planned drain.
    private func dropPath(_ id: String) {
        pathLayer.detach(id)
        pathProvider.removeValue(forKey: id)
        attempts.removeValue(forKey: id)
        var readers = tcpInfoReaders.get()
        readers.removeValue(forKey: id)?.stop()
        tcpInfoReaders.set(readers)
    }

    /// Adds a welcome'd path to the layer; the first one founds the session.
    private func attachPath(_ id: String) {
        guard let attempt = attempts[id], let send = attempt.sendRaw, let channel = attempt.channel else { return }
        attempts[id]?.timer?.cancel()
        guard pathLayer.pathCount < PathLayer.maxPaths else {
            closeAttempt(id)
            return
        }
        let path = PathLayer.Path(id: id, kind: .lan, send: send,
                                  close: { channel.close() },
                                  isWritable: attempt.isWritable ?? { true },
                                  setReading: attempt.setReading ?? { _ in })
        var readers = tcpInfoReaders.get()
        readers[id]?.stop()
        readers[id] = TCPInfoReader(channel: channel)
        tcpInfoReaders.set(readers)
        pathProvider[id] = attempt.providerIndex
        // E-5: the attempt is the path now. Counting a welcomed attempt as
        // well made `pathCount + attempts.count` count every attached path
        // twice, so a session that lost one of two never re-dialed.
        attempts.removeValue(forKey: id)
        if pathLayer.pathCount == 0 {
            pathLayer.start(first: path)
            if everAttached {
                // An orphan's path came back: unplanned-switch semantics, so the
                // frames held while no path was up replay onto it (PATH-6/9).
                handlePath(.pathUp(id: id, joined: true))
            } else {
                pathMachine.startLive(path: id)
            }
        } else {
            pathLayer.attach(path, joined: true)
            // Item 7's join predicate: a Mac-side fact that two paths are live
            // on one session, not a state-token transition.
            Log.session.notice("paths: attached \(id, privacy: .public) (paths \(self.pathLayer.pathCount))")  // log-ok: a path id and a count
            handlePath(.pathUp(id: id, joined: true))
        }
        pathRanking.register(id: id, kind: attempt.kind)
        if pathLayer.currentPath == id {
            // The ranking's current starts as the session's current: the
            // founder was made live without a pathUp event.
            _ = pathRanking.handle(.externalSwitch(id), now: uptime)
        }
        dialedAddress = attempt.address ?? dialedAddress
        dispatchRejoin(.welcomed, now: uptime)
    }

    // MARK: Path events and the session machine

    private func handlePathFrame(_ id: String, _ frame: Frame) {
        lastFramePath = id
        // PATH-24: any inbound frame on a live path ends the silence the probe
        // was covering, so a dial still in flight is dropped.
        if pathLayer.hasPath(id) {
            for action in pathProbe.handle(.inbound, now: uptime) {
                if case .cancel = action { cancelProbe() }
            }
        }
        guard pathLayer.hasPath(id) else {
            // Before this path joined the layer every frame is handshake
            // (welcome, or a refusal that ends the attempt).
            handleFrame(frame)
            return
        }
        for event in pathLayer.receive(path: id, frame: frame) {
            switch event {
            case .deliver(let inner):
                handleFrame(inner, path: id)
            case .pong(let path, let rtt, let rankingSample):
                // E-8/RRR-4: a pong on a path that carried bulk within the
                // last second measures the queue, not the link. It proved the
                // path alive above; it never enters the score.
                guard rankingSample else { break }
                let now = uptime
                pathRanking.addSample(id: path, rttMs: rtt, at: now)
                pathMachine.scores[path] = pathRanking.score(id: path, now: now) ?? -1
            case .ping:
                break
            case .peerSwitch(let path, let seq, let arrivedOn):
                if arrivedOn != path { pathLayer.drainNow(arrivedOn) }
                handlePath(.peerSwitch(id: path, seq: seq, arrivedOn: arrivedOn))
            case .down(let path):
                handlePathError(path, "closed-by-peer")
            case .ackAboveSent:
                Log.session.error("paths: ack above what was sent")
                phoneErrorCode = "protocol"
                fail("protocol")
            case .protocolError(let token):
                Log.session.error("paths: protocol error (\(token, privacy: .public))")  // log-ok: a closed token
                phoneErrorCode = "protocol"
                fail("protocol")
            }
        }
    }

    /// A bare `path.ping` read before its path's welcome. The phone pings a
    /// path the moment it attaches it, and a join is attached on the phone's
    /// acceptor thread: that ping can be on the wire ahead of the join's
    /// welcome. Answer it on the path it arrived on, naming the id our own
    /// hello gave that path. Nothing else pre-welcome changes course: every
    /// other frame still goes to the handshake router, and a ping for any
    /// other id is left to PathLayer (PATH-12).
    private func answerPreAttachPing(_ message: JSONMessage) {
        guard let id = lastFramePath, let attempt = attempts[id], let send = attempt.sendRaw else { return }
        let pingPath = message.string("path") ?? id
        guard pingPath == id else { return }
        let ts = Int64(message.int("ts") ?? 0)
        let pong = Frame(type: MessageType.json.rawValue, stream: 0, payload: JSONFrame.payload([
            "t": "path.pong", "path": pingPath, "ts": NSNumber(value: ts),
        ]))
        send(pong.encoded)
    }

    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func handlePath(_ event: PathSessionEvent) {
        let now = uptime
        for id in pathMachine.live {
            pathMachine.scores[id] = pathRanking.score(id: id, now: now) ?? -1
        }
        let before = pathMachine.state
        let actions = pathMachine.handle(event, now: now)
        for action in actions {
            switch action {
            case .startPing, .stopPing, .ignore:
                break
            case .ranking(let rankingEvent):
                _ = pathRanking.handle(rankingEvent, now: now)
            case .closePath(let path):
                dropPath(path)
            case .switchTo(let path):
                switchTo(path, why: event.token)
            case .replayFromLastAck:
                pathLayer.replayOnCurrent()
            case .requestKeyframes:
                emit(.pathsSwitched)
            case .markReconnecting:
                setReconnecting(true)
            case .end(let reason):
                fail(reason)
            }
        }
        if case .live = pathMachine.state { setReconnecting(false) }
        if before != pathMachine.state {
            Log.session.notice("paths: \(before.token, privacy: .public) --\(event.token, privacy: .public)--> \(self.pathMachine.state.token, privacy: .public)")  // log-ok: closed state tokens, never a value
        }
    }

    /// A failure or an orphan's join: the marker is the first frame on the new
    /// path, then the replay (PATH-9).
    private func switchTo(_ path: String, why: String) {
        guard pathLayer.hasPath(path) else { return }
        let from = pathLayer.currentPath
        pathLayer.moveTo(path, plannedFrom: nil)
        if let from, from != path {
            Log.session.notice("paths: sending \(from, privacy: .public) -> \(path, privacy: .public) (\(why, privacy: .public))")  // log-ok: path ids and a closed event token
        }
        _ = pathLayer.sendMarker(on: path, to: path)
        emit(.pathsSwitched)
    }

    /// A margin switch: the marker is the last frame on the old path (§5.4).
    private func plannedSwitch(to path: String) {
        guard pathLayer.hasPath(path), let old = pathLayer.currentPath, old != path else {
            Log.session.notice("paths: planned switch not possible")  // log-ok: a state token
            return
        }
        guard pathLayer.sendMarker(on: old, to: path) else { return }
        pathLayer.moveTo(path, plannedFrom: old)
        Log.session.notice("paths: sending \(old, privacy: .public) -> \(path, privacy: .public) (planned)")  // log-ok: path ids and a closed reason
        pathLayer.replayOnCurrent()
        handlePath(.peerSwitch(id: path, seq: 0, arrivedOn: old))
    }

    private func setReconnecting(_ on: Bool) {
        guard reconnectingEmitted != on else { return }
        reconnectingEmitted = on
        emit(.pathsReconnecting(on))
    }

    private func startPathTimer() {
        guard pathTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.tickPaths() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pathTimer = timer
    }

    /// D-1/PATH-7/RR-9: "active" is the phone's screen on, any open stream
    /// (a mirrored app window outlives the screen), or a bulk transfer in the
    /// last 2 s. The same rule on both sides.
    private var pingActive: Bool {
        if phoneScreenOn { return true }
        closedStreamsLock.lock()
        let streams = closedStreams.hasOpenStream
        closedStreamsLock.unlock()
        return streams || pathLayer.transferActive
    }

    private func tickPaths() {
        maintainPaths()
        tickProbe()
        pathLayer.pingAll(active: pingActive)
        let now = uptime
        // A pong lost on a path that is still receiving is a ranking sample,
        // never a failure (D-2/RR-14), exactly as the phone records it.
        for late in pathLayer.latePongs() {
            pathRanking.addSample(id: late, rttMs: nil, at: now)
        }
        for lost in pathLayer.lostPings() {
            pathRanking.addSample(id: lost, rttMs: nil, at: now)
            if lost == pathLayer.currentPath { handlePath(.pongLost(id: lost)) }
        }
        for stale in pathLayer.joinedTimeouts() {
            let wasCurrent = pathLayer.currentPath == stale
            dropPath(stale)
            handlePath(wasCurrent ? .currentFailed(id: stale) : .pathDown(id: stale))
        }
        for path in pathLayer.closeDrained() { dropPath(path) }
        if case .migrating(_, _, let since) = pathMachine.state, now - since >= PathTimers.drainBackstop {
            handlePath(.drainExpired)
        }
        if case .orphaned(let since) = pathMachine.state, now - since >= PathTimers.grace {
            handlePath(.graceExpired)
        }
        for action in pathRanking.handle(.tick(now: now), now: now) {
            switch action {
            case .switchTo(let path):
                if debugNoMarginSwitch {
                    Log.session.notice("paths: rank switch suppressed (debug)")  // log-ok: a closed debug token
                    break
                }
                Log.session.notice("paths: rank switch to \(path, privacy: .public)")  // log-ok: a path id, not a value from the wire
                plannedSwitch(to: path)
            case .sessionOrphan:
                if let current = pathLayer.currentPath { handlePath(.currentFailed(id: current)) }
            }
        }
    }

    /// Stops the session. The state transition is synchronous (callers see
    /// `.closed` at once); the blocking teardown — the channel's close future
    /// and `syncShutdownGracefully` — runs on the session's own queue, so a
    /// main-actor caller (every ConnectionController call site) never freezes
    /// while a wedged TLS channel drains (arch H4).
    func close() {
        enqueueClose(completion: nil)
    }

    /// Quit only: waits up to `timeout` for the teardown, so the process does
    /// not exit with a half-closed channel. Never called on the UI path.
    func closeAndWait(timeout: TimeInterval = 1) {
        let done = DispatchSemaphore(value: 0)
        enqueueClose { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    private func enqueueClose(completion: (() -> Void)?) {
        intentionalClose = true
        cancelTimers()
        transition(.closed, nil)
        // Strong self: the teardown must run even when the owner drops its
        // reference right after close (the quit path does exactly that).
        queue.async {
            self.closeBlocking()
            completion?()
        }
    }

    /// Runs on `queue`: the part of close() that can block.
    private func closeBlocking() {
        closeChannel()
        if ownsGroup {
            try? eventLoopGroup?.syncShutdownGracefully()
            eventLoopGroup = nil
            ownsGroup = false
        }
    }

    private func closeChannel() {
        exporterProvider = nil
        for id in Array(attempts.keys) { closeAttempt(id, reports: false) }
        attempts.removeAll()
        attemptReasons.removeAll()
        preWelcomeSender.set(nil)
        pathSessionId.set(nil)
        pathProvider.removeAll()
        let readers = tcpInfoReaders.get()
        for reader in readers.values { reader.stop() }
        tcpInfoReaders.set([:])
        pathRejoin = PathRejoinMachine()
        pathProbe = PathProbeMachine()
        probeAttemptId = nil
        pathLayer.closeAll()
    }

    /// Bonjour services still resolve through Network.framework (NIO cannot
    /// resolve `_contigua._tcp` names); the resolver runs on its own queue so
    /// the session queue is never blocked by it. The dial itself then goes to
    /// the resolved host/port over NIO. Note the dial keeps no interface
    /// pinning once resolved — a bridge-resolved address fails the TLS dial and
    /// the owner's planner falls back to the cached address.
    private func resolveTarget(_ endpoint: Endpoint) -> (host: String, port: Int)? {
        switch endpoint {
        case .hostPort(let host, let port):
            return (host, Int(port))
        case .service(let service, _):
            let conn = NWConnection(to: service, using: Self.tcpParameters(for: endpoint, net: netStrategy))
            let resolveQueue = DispatchQueue(label: "app.contigua.session.resolve")
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

    private func armPairingDeadline() {
        connectWatchdog?.cancel()
        connectWatchdog = nil
        // A person deciding is not a slow connect: the attempt timers stop
        // here and the pairing deadline owns the wait (PAIR-13).
        for id in Array(attempts.keys) {
            attempts[id]?.timer?.cancel()
            attempts[id]?.timer = nil
        }
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
        pathTimer?.invalidate()
        pathTimer = nil
    }

    private func transition(_ newState: SessionState, _ detail: String?) {
        state = newState
        emit(.state(newState, detail))
    }

    /// 32 lowercase hex: PORT's session id shape (PATH-3/19).
    static func isSessionId(_ text: String) -> Bool {
        text.count == 32 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// The session's TCP parameters. `net=video` asks the system for the
    /// interactive-video service class (N1's Mac side); the default leaves the
    /// parameters exactly as today.
    static func tcpParameters(for endpoint: Endpoint,
                              net: MacStreamStrategy.Net = .default) -> NWParameters {
        let parameters = NWParameters.tcp
        if net == .video {
            parameters.serviceClass = .interactiveVideo
        }
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

    /// X0: the current path's socket readings, shared by every window's stats
    /// line (the video is one connection). Nil before a path is live.
    func currentTCPInfo() -> TCPConnectionInfo? {
        guard let id = pathLayer.currentPath,
              let reader = tcpInfoReaders.get()[id] else { return nil }
        return reader.current()
    }

    // MARK: Receive dispatch

    private func handleFrame(_ frame: Frame, path: String? = nil) {
        switch frame.messageType {
        case .json:
            guard let message = JSONFrame.decode(payload: frame.payload) else {
                Log.session.error("unparseable JSON frame")
                return
            }
            receive(message)
        case .videoConfig:
            guard let config = try? VideoConfig(payload: frame.payload) else {
                Log.session.error("bad VIDEO_CONFIG payload")
                return
            }
            // The phone always sends the picture's rect ahead of a config; a config
            // without one cannot be cropped, so it is dropped.
            guard let picture = pendingPictures.removeValue(forKey: frame.stream) else {
                Log.session.error("VIDEO_CONFIG without window.content, stream \(frame.stream, privacy: .public)")
                return
            }
            onVideoEvent?(.config(stream: frame.stream, config: config, picture: picture))
        case .videoFrame:
            guard let data = try? VideoFrameData(payload: frame.payload) else {
                Log.session.error("bad VIDEO_FRAME payload")
                return
            }
            LatencyLog.shared.noteVideoFrame(stream: frame.stream)
            onVideoEvent?(.frame(stream: frame.stream, frame: data, path: path ?? "-"))
        case .videoChunk:
            guard let chunk = try? VideoChunkData(payload: frame.payload) else {
                Log.session.error("bad VIDEO_CHUNK payload, stream \(frame.stream, privacy: .public)")
                if videoChunks.forget(stream: frame.stream) {
                    onVideoEvent?(.chunkIncomplete(stream: frame.stream))
                }
                return
            }
            let result = videoChunks.add(stream: frame.stream, chunk: chunk)
            if result.discardedIncomplete {
                // R6: the stub it discarded was a picture the decoder needed.
                onVideoEvent?(.chunkIncomplete(stream: frame.stream))
            }
            guard let data = result.frame else { return }
            LatencyLog.shared.noteVideoFrame(stream: frame.stream)
            onVideoEvent?(.frame(stream: frame.stream, frame: data, path: path ?? "-"))
        case .shareData:
            emit(.shareFileData(id: frame.stream, bytes: frame.payload))
        case .clipData:
            emit(.clipImageData(id: frame.stream, bytes: frame.payload))
        case .fsData:
            emit(.fsData(id: frame.stream, bytes: frame.payload))
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

    /// window.content: where the picture sits in the frame of the VIDEO_CONFIG that follows.
    private func handleWindowContent(_ message: JSONMessage) {
        guard let stream = message.int("stream"), stream >= 0,
              let x = message.int("x"), let y = message.int("y"),
              let w = message.int("w"), let h = message.int("h"), x >= 0, y >= 0, w > 0, h > 0 else {
            Log.session.error("bad window.content")
            return
        }
        pendingPictures[UInt32(stream)] = PictureRect(x: x, y: y, w: w, h: h)
    }

    /// One decoded message from the phone. `internal` so a check can prove a
    /// message's parse without a socket (WIN-28: `label` and `title` apart).
    func receive(_ message: JSONMessage) {
        switch message.t {
        case "window.content":
            handleWindowContent(message)
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
            let codeHex = PairingCodeV2.codeHex(code)
            armPairingDeadline()
            // sec L-1: the code is a secret for its 120 s window; the log
            // carries its length only. The e2e bundles (PD_TEST_HOOKS) keep
            // the value so the pair check can compare both screens.
            Log.session.notice("pairing code derived for this screen (len \(codeHex.count, privacy: .public))")
            #if PD_TEST_HOOKS
            Log.session.notice("pairing code derived for this screen: \(codeHex, privacy: .public)")
            #endif
            emit(.pairCodeShown(deviceId: knownDeviceId, code: codeHex))
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
            // The pairing flow is verified: the record it establishes may be
            // adopted at the founding welcome, so later dials pin it (PATH-52).
            sessionPinEvent(.phoneAllowed)
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
            // PATH-3: `session` names the session this path belongs to. A join
            // must echo the id it asked for; a mismatch closes only that path.
            guard let session = message.string("session"), Self.isSessionId(session) else {
                Log.session.error("welcome without a valid session id")
                fail("protocol")
                return
            }
            let welcomedOn = lastFramePath
            if let welcomedOn, let asked = attempts[welcomedOn]?.machine.phase.joinSession {
                guard asked == session else {
                    Log.session.notice("path join mismatch")
                    closeAttempt(welcomedOn)
                    return
                }
                // A later path: one more connection, no second session, no
                // second ready event (PATH-3).
                // NOTIFY-1: an orphaned session's rejoin is the reconnect the
                // ready branch never sees (ISS-5); the opt-in is repeated once
                // the rejoined path is current. A probe join beside a live
                // path (no outage) sends nothing.
                var afterOutage = false
                if case .orphaned = pathMachine.state { afterOutage = true }
                attemptEvent(welcomedOn, .welcomed(session: session))
                let wasProbe = attempts[welcomedOn]?.probeJoin == true
                attachPath(welcomedOn)
                if wasProbe { probeWelcomed(welcomedOn) }
                emit(.pathsReconnecting(false))
                if afterOutage, notifyEnabled.get() {
                    Log.session.notice("notify: rejoined after an outage; asking for the active set")  // log-ok: a closed event, no value
                    sendJSON(["t": "notify.enable", "on": true])
                }
                return
            }
            // From here the seq space exists: no frame may travel bare again,
            // and a frame with no attached path is held for the join (R-4).
            // Clear the bare sender first: a frame racing the founding is
            // dropped (E-2), never written bare after the welcome.
            preWelcomeSender.set(nil)
            pathSessionId.set(session)
            if let welcomedOn {
                attemptEvent(welcomedOn, .welcomed(session: session))
                attachPath(welcomedOn)
            }
            performStart(pathStart.handle(.welcome(attempt: welcomedOn ?? "", session: session)))
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
            let pinRecord = storePinFor(info: info)
            // PATH-52: a pairing session adopts the pin its pairing just
            // established, so its own rejoin dials are verified joins. Only a
            // complete record (the handshake's own certificate carries the
            // pin) is adopted, and only after the phone's pair.ok.
            sessionPinEvent(.founded(record: pinRecord.flatMap(verifiablePinRecord)))
            knownDeviceIdReal = info.id
            if qrApproved {
                qrApproved = false
                emit(.qrPaired(deviceId: info.id))
            }
            phone = info
            connectWatchdog?.cancel()
            connectWatchdog = nil
            pairingDeadline?.cancel()
            pairingDeadline = nil
            startPing()
            startPathTimer()
            let isReconnect = everReady
            everReady = true
            transition(.ready, nil)
            // A window may open at once, and the phone may have slept since the
            // last session: one pong now gives the new offset without the 15 s
            // timer's wait (WIN-53).
            sendPing()
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
            let stream = UInt32(message.int("stream") ?? 0)
            emit(.windowOpened(stream: stream,
                               displayId: message.int("displayId") ?? 0,
                               width: message.int("w") ?? 0,
                               height: message.int("h") ?? 0,
                               started: message.string("started") == "fresh" ? .fresh : .moved))
            if let taskId = message.int("taskId") {
                emit(.windowTask(stream: stream, taskId: taskId))
            }
        case "window.resize.ack":
            // The phone applied (or refused) a `window.resize`: the coalescer
            // may send the value that waited behind it (PROTOCOL.md).
            emit(.windowResizeAck(stream: UInt32(message.int("stream") ?? 0),
                                  width: message.int("w") ?? 0,
                                  height: message.int("h") ?? 0,
                                  dpi: message.int("dpi") ?? 0,
                                  outcome: message.string("outcome") ?? ""))
        case "window.task":
            emit(.appTaskArrived(stream: UInt32(message.int("stream") ?? 0),
                                 taskId: message.int("taskId") ?? 0,
                                 pkg: message.string("pkg") ?? "",
                                 label: message.string("label")))
        case "window.closed":
            let closed = UInt32(message.int("stream") ?? 0)
            // RRR-5: the phone ended it, so it is no longer an open stream
            // (D-1's active test); a Mac close skips sendClose, so this is the
            // only place the id is forgotten.
            forgetStream(closed)
            // R6: an incomplete chunked unit dies with its stream.
            if videoChunks.forget(stream: closed) {
                onVideoEvent?(.chunkIncomplete(stream: closed))
            }
            emit(.windowClosed(stream: closed,
                               reason: message.string("reason") ?? ""))
        case "window.title":
            // `label` names the app the display shows; `title`, on an app or
            // link stream, its task (WIN-28). They are never folded together:
            // a link window's subject is the app, not the page.
            emit(.windowTitle(stream: UInt32(message.int("stream") ?? 0),
                              label: message.string("label") ?? "",
                              pkg: message.string("pkg") ?? "",
                              title: message.string("title")))
        case "window.still":
            emit(.windowStill(stream: UInt32(message.int("stream") ?? 0)))
        case "stream.stats":
            // The phone's 2 s counters for one streaming window; only sent
            // while this session asked for them with `stream.stats {on:true}`.
            guard let raw = message.int("stream"), raw > 0 else { return }
            emit(.phoneStats(stream: UInt32(raw),
                             stats: PhoneStreamStats(json: message.raw)))
        case "task.front":
            emit(.frontApp(seq: message.int("seq") ?? 0, pkg: message.string("pkg")))
        case "ui.tree":
            if let tree = UITree(message: message) { emit(.uiTree(tree)) }
        case "ui.settle":
            if let reply = UISettleReply(message: message) { emit(.uiSettle(reply)) }
        case "ui.press":
            if let reply = UIPressReply(message: message) { emit(.uiPress(reply)) }
        case "ui.type":
            if let reply = UITypeReply(message: message) { emit(.uiType(reply)) }
        case "state":
            phoneScreenOn = (message.string("screen") ?? "on") == "on"
            if let cap = message.int("maxWindows") {
                emit(.maxWindows(cap))
            }
            emit(.phoneState(locked: message.bool("locked") ?? false,
                             battery: message.int("battery") ?? 0,
                             charging: message.bool("charging") ?? false,
                             dnd: message.string("dnd").flatMap(PhoneDndMode.init(rawValue:)),
                             ringer: message.string("ringer").flatMap(PhoneRingerMode.init(rawValue:)),
                             volume: message.int("volume"),
                             volumeMax: message.int("volumeMax"),
                             screen: message.string("screen").flatMap(PhoneScreen.init(rawValue:)),
                             secure: message.bool("secure"),
                             panel: message.string("panel").flatMap(PhonePanel.init(rawValue:)),
                             lockSource: message.string("lockSource").flatMap(PhoneLockSource.init(rawValue:))))
        case "ring.state":
            emit(.ringState(ringing: message.bool("ringing") ?? false))
        case "power.locked":
            emit(.powerLocked)
        case "audio.state":
            emit(.audioState(on: message.bool("on") ?? false,
                             codec: UInt8(message.int("codec") ?? 0)))
        case "pong":
            notePong(message)
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
        case "clip.image.done":
            if let id = message.int("id") {
                emit(.clipImageDone(id: UInt32(truncatingIfNeeded: id),
                                    ok: message.bool("ok") ?? false))
            }
        case "notify.state":
            emit(.notifyState(on: message.bool("on") ?? false, reason: message.string("reason")))
        case "notify.post":
            // `alert` is required (NOTIFY-19): a post that does not say whether
            // Android would alert cannot be shown honestly.
            guard let alert = message.bool("alert") else { return }
            let whenMs = message.double("when")
            let live = NotifyLive(json: message.object("live"))
            emit(.notifyPosted(id: message.string("id") ?? "", pkg: message.string("pkg") ?? "",
                               when: whenMs.map { Date(timeIntervalSince1970: $0 / 1000) },
                               title: message.string("title"), text: message.string("text"),
                               actions: (message.array("actions") ?? []).compactMap { NotifyActionInfo(json: $0) },
                               ongoing: message.bool("ongoing") ?? false,
                               live: live, alert: alert, group: message.string("group")))
        case "notify.image":
            guard let encoded = message.string("data"),
                  let data = Data(base64Encoded: encoded),
                  let width = message.int("w"),
                  let height = message.int("h") else { return }
            emit(.notifyImage(id: message.string("id") ?? "",
                              mime: (message.string("mime") ?? "").lowercased(),
                              width: width, height: height, data: data))
        case "notify.remove":
            emit(.notifyRemoved(id: message.string("id") ?? ""))
        case "notify.snapshot":
            emit(.notifySnapshot(ids: message.strings("ids") ?? []))
        case "media.state":
            emit(.mediaState(MediaState(
                playing: message.bool("playing") ?? false,
                pkg: message.string("pkg"),
                key: message.string("key"),
                title: message.string("title"),
                artist: message.string("artist"),
                album: message.string("album"),
                durationMs: message.int("durationMs").map { Int64($0) },
                positionMs: message.int("positionMs").map { Int64($0) },
                rate: message.double("rate") ?? 0,
                canSeek: message.bool("canSeek") ?? false,
                volume: message.int("volume"),
                volumeMax: message.int("volumeMax"),
                receivedAt: Date().timeIntervalSince1970,
            )))
        case "media.sessions":
            let rows = (message.array("list") ?? []).compactMap { row -> MediaSessionRow? in
                guard let key = row["key"] as? String, !key.isEmpty,
                      let pkg = row["pkg"] as? String else { return nil }
                return MediaSessionRow(key: key, pkg: pkg,
                                       app: (row["app"] as? String) ?? pkg,
                                       playing: (row["playing"] as? Bool) ?? false)
            }
            emit(.mediaSessions(rows, chosen: message.string("chosen")))
        case "media.art":
            guard let key = message.string("key"), !key.isEmpty else { return }
            emit(.mediaArt(key: key, mime: message.string("mime"),
                           width: message.int("w"), height: message.int("h"),
                           data: message.data("data")))
        case "fs.items":
            guard let raw = message.int("id"), let id = UInt32(exactly: raw), id > 0 else { return }
            emit(.fsItems(id: id, page: message.string("page"),
                          digest: message.string("digest"),
                          items: message.array("items") ?? []))
        case "fs.item":
            guard let raw = message.int("id"), let id = UInt32(exactly: raw), id > 0, let item = message.object("item") else { return }
            emit(.fsItem(id: id, item: item))
        case "fs.digest":
            guard let raw = message.int("id"), let id = UInt32(exactly: raw), id > 0,
                  let digests = message.object("digests") else { return }
            emit(.fsDigest(id: id, digests: digests))
        case "fs.read.end":
            guard let raw = message.int("id"), let id = UInt32(exactly: raw), id > 0 else { return }
            emit(.fsReadEnd(id: id, size: message.int("size") ?? -1,
                            sha256: message.string("sha256") ?? ""))
        case "fs.thumb.end":
            guard let raw = message.int("id"), let id = UInt32(exactly: raw), id > 0 else { return }
            emit(.fsThumbEnd(id: id, mime: message.string("mime") ?? "",
                             size: message.int("size") ?? -1,
                             sha256: message.string("sha256") ?? ""))
        case "fs.progress":
            guard let raw = message.int("id"), let id = UInt32(exactly: raw), id > 0 else { return }
            emit(.fsProgress(id: id, bytes: message.int("bytes") ?? 0))
        case "fs.result":
            guard let raw = message.int("id"), let id = UInt32(exactly: raw), id > 0 else { return }
            emit(.fsResult(id: id, ok: message.bool("ok") ?? false,
                           item: message.object("item"),
                           code: message.string("code"), message: message.string("message")))
        case "fs.changes":
            emit(.fsChanges(paths: message.strings("paths") ?? []))
        case "error":
            let code = message.string("code") ?? "unknown"
            // PATH-1: the phone refused the version. Its `v` names which app
            // to update; there is no retry and no reduced session.
            if code == "version" {
                phoneErrorCode = "version"
                emit(.versionRefused(PathVersion.macSentence(peer: message.int("v"))))
                fail("version")
                return
            }
            // PAIR-30: the phone's authenticated word that it forgot this Mac.
            // It ends the session on its own too, but the Mac must enter the
            // trust-lost state at once, not wait out a path grace. The phone's
            // live-session errors carry `stream: 0` (or omit it) when the error
            // is the session's, not a stream request's.
            //
            // R2: the real phone's `sendError` ALWAYS writes `stream: 0` for a
            // session-level error (Session.kt: `stream: Int = 0`), so "no
            // stream field" is not the test — a `pair_cooldown` used to reach
            // the Mac and be read as a TLS failure. A known session code with
            // stream 0 (or absent) ends the session and names the reason.
            let stream = message.int("stream") ?? 0
            if stream == 0, Self.sessionErrorCodes.contains(code) {
                // An fs failure names the request it answers; it is not the
                // session-level error a stream-0 `error` otherwise is.
                if let raw = message.int("id"), let id = UInt32(exactly: raw), id > 0 {
                    emit(.fsError(id: id, code: code, message: message.string("message")))
                    return
                }
                // RR-12: a rejoin refused because the session is gone (the
                // phone's server restarted, or its grace ended first) ends the
                // orphan at once, so the controller's reconnect starts exactly
                // one new session instead of dialing a dead id for the grace.
                // RRR-9: for a join, `busy` means that same thing (the session
                // is ending), never "another Mac is connected": it fails as
                // `no_session` so the person reads the right sentence.
                if let attemptId = lastFramePath,
                   attempts[attemptId]?.machine.phase.joinSession != nil,
                   code == "no_session" || code == "busy" {
                    let refusal = code == "busy" ? "no_session" : code
                    phoneErrorCode = refusal
                    fail(refusal)
                    return
                }
                phoneErrorCode = code
                fail(code)
                return
            }
            // An fs failure names the request it answers; it is not the
            // session-level error a stream-less `error` otherwise is.
            if let raw = message.int("id"), let id = UInt32(exactly: raw), id > 0 {
                emit(.fsError(id: id, code: code, message: message.string("message")))
                return
            }
            if message.int("stream") == nil { phoneErrorCode = code }
            // RRR-5: the phone has forgotten this stream (a window it closed
            // itself); it must not keep the fast ping alive either.
            if code == "no_stream", let raw = message.int("stream"),
               let stream = UInt32(exactly: raw) {
                forgetStream(stream)
            }
            emit(.phoneError(code: code, message: message.string("message"),
                             stream: UInt32(message.int("stream") ?? 0)))
            // A terminal reply before `welcome` ends the attempt now: the phone's
            // next act is the close, and neither that close nor the 6 s watchdog
            // may be what ends a handshake the phone already answered (PAIR-13's
            // "return as soon as the terminal reply arrives").
            if message.int("stream") == nil, !everReady {
                fail(code)
                return
            }
        case "path.ping":
            // The phone's ticker pings a path the moment it is attached; for a
            // join that is on its acceptor thread, so the ping can precede the
            // join's welcome. Answer it for the path we are attaching: it names
            // the id our own hello gave that path, so no other frame moves and
            // nothing else pre-welcome changes course.
            answerPreAttachPing(message)
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
    private func storePinFor(info: PhoneInfo) -> PinnedPhoneV2? {
        let pin = learnedPeerPin
        guard !pin.isEmpty else { return nil }
        var certPem = ""
        if let cert = aspectPeerCert, let der = try? cert.toDERBytes() {
            let b64 = Data(der).base64EncodedString()
            certPem = "-----BEGIN CERTIFICATE-----\n\(stripBase64Lines(b64))-----END CERTIFICATE-----\n"
        }
        let record = PinnedPhoneV2(deviceId: info.id, phoneFingerprintHex: pin, certPem: certPem)
        phonePinStore?.store(record)
        pinSessionEstablished?(record)
        return record
    }

    /// The record only when TLS could verify it on the next dial: its own
    /// certificate parses and carries the pin. The adoption transition never
    /// holds a record that could only fail (PATH-52).
    private func verifiablePinRecord(_ record: PinnedPhoneV2) -> PinnedPhoneV2? {
        guard let cert = try? NIOSSLCertificate(bytes: [UInt8](record.certPem.utf8), format: .pem),
              let fingerprint = PinCheckV2.pointFingerprint(cert: cert),
              PinCheckV2.matches(fingerprint, pinHex: record.phoneFingerprintHex) else {
            return nil
        }
        return record
    }

    /// Moves the session's own pin state and logs the transition with closed
    /// tokens: never a fingerprint, an id or key material (R-PRIV-1).
    private func sessionPinEvent(_ event: SessionPinEvent) {
        let before = dialPin
        guard dialPin.handle(event) else { return }
        let from = before.token
        let to = dialPin.token
        Log.session.notice("session pin: \(from, privacy: .public) --\(event.token, privacy: .public)--> \(to, privacy: .public)")  // log-ok: closed state and event tokens
    }

    /// Dev and e2e bundles log an 8-hex prefix of the exporter's SHA-256 for
    /// K4/e2e evidence (two sessions must not look resumed); the release
    /// bundle (PDBuildVariant=release, as bundle.sh stamps it) logs neither
    /// the prefix nor anything else derived from handshake secrets.
    static func logsExporterHash(variant: String?) -> Bool {
        variant != "release"
    }

    /// The 32 exporter's SHA-256 prefix, logged once per session (K4/e2e
    /// compare the two ends; R5: a prefix is not key material, and the full
    /// hash and the exporter itself never leave memory). Nil-safe: a failed
    /// handshake logs nothing.
    private func logExporterOnce() {
        guard Self.logsExporterHash(variant: Bundle.main.object(forInfoDictionaryKey: "PDBuildVariant") as? String) else { return }
        guard !loggedExporterSha else { return }
        guard let exporter = exporterProvider?() else { return }
        loggedExporterSha = true
        let digest = SHA256.hash(data: Data(exporter))
        let hashTag = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        Log.session.notice("v2 exporter ready \(hashTag, privacy: .public)")
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
            self?.sendPing()
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    /// One ping. `ts` stays the wall-clock millisecond every peer echoes;
    /// `monoUs` is this Mac's CLOCK_MONOTONIC in µs, the base the pong's `now`
    /// can be compared on. An older phone ignores the extra field.
    private func sendPing() {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let sentUs = Self.monotonicUs()
        clockLock.lock()
        if pingSentUs.count >= 16 { pingSentUs.removeAll() }
        pingSentUs[ts] = sentUs
        clockLock.unlock()
        sendJSON(["t": "ping", "ts": ts, "monoUs": Int(sentUs)])
    }

    /// A pong carrying `now` (the phone's CLOCK_MONOTONIC µs, the clock
    /// VIDEO_FRAME's ptsUs uses) feeds the offset estimate. The first estimate
    /// of a session is logged once, numbers only: the field log then shows the
    /// two clocks were compared.
    private func notePong(_ message: JSONMessage) {
        guard let ts = message.int("ts"), let phoneNow = message.int("now"),
              phoneNow > 0 else { return }
        let receivedUs = Self.monotonicUs()
        clockLock.lock()
        let sentUs = pingSentUs.removeValue(forKey: ts)
        if let sentUs {
            let had = clockEstimator.offsetUs != nil
            let note = clockEstimator.note(sentUs: sentUs, receivedUs: receivedUs,
                                           phoneNowUs: Double(phoneNow),
                                           at: ProcessInfo.processInfo.systemUptime)
            let rtt = (receivedUs - sentUs) / 1000
            clockLock.unlock()
            if let jump = note.jumpMs {
                // A slept phone's CLOCK_MONOTONIC stopped and restarted: the
                // estimate restarts from this sample (numbers only).
                Log.session.notice("clock offset: jump \(Int(jump.rounded()), privacy: .public)ms")  // log-ok: a duration in ms, no content
            } else if !had, let offset = note.offsetUs {
                Log.session.notice("clock offset: rtt=\(String(format: "%.1f", rtt), privacy: .public)ms offset=\(Int(offset / 1000), privacy: .public)ms")  // log-ok: numbers only (rtt and offset), no content
            }
            return
        }
        clockLock.unlock()
    }

    /// The current phone→Mac clock offset in µs, nil until a pong with `now`.
    var phoneClockOffsetUs: Double? {
        clockLock.lock()
        defer { clockLock.unlock() }
        return clockEstimator.offsetUs
    }

    private static func monotonicUs() -> Double {
        ProcessInfo.processInfo.systemUptime * 1_000_000
    }

    // MARK: Pairing API

    /// Carries the QR sheet's one-time secret `s` on a probe session (R2): the
    /// phone proves the scan by the `pair.qr` HMAC over the exporter.
    func useQRSecret(_ secret: Data) { qrSecret = secret }

    // MARK: Send

    private func emit(_ event: SessionEvent) {
        if Thread.isMainThread {
            onEvent?(event)
        } else {
            DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
        }
    }

    @discardableResult
    func sendBytes(_ bytes: [UInt8]) -> Bool {
        guard let frame = Frame(encoded: bytes) else { return false }
        return sendReliable(frame)
    }

    /// One frame above the path layer. Before founding there is no seq space:
    /// handshake and pairing frames travel bare on the one path that holds the
    /// plain hello (PATH-2), and any other send is dropped with `sent(false)`
    /// (E-2) — admitting it would spend a seq that never reaches a path, and the
    /// phone would hold every later frame at the seq-1 gap (RR-2). After
    /// founding every frame is a path-layer frame: with no attached path it is
    /// held for replay, never written bare to a dead attempt (PATH-6, R-4).
    @discardableResult
    private func sendReliable(_ frame: Frame, completion: (@Sendable (Bool) -> Void)? = nil) -> Bool {
        if let preWelcome = preWelcomeSender.get() {
            preWelcome(frame.encoded)
            completion?(true)
            return true
        }
        guard pathSessionId.get() != nil else {
            completion?(false)
            return false
        }
        pathLayer.send(frame, completion: completion)
        return true
    }

    @discardableResult
    func sendJSON(_ object: [String: Any]) -> Bool {
        #if PD_TEST_HOOKS
        // Test hook: what the Mac asked the phone for, in order, so a window
        // test can prove an item sent nothing (WIN-27) as well as what it sent.
        sentLock.lock(); sentMessages.append(object); sentLock.unlock()
        #endif
        // RRR-5: an opened stream counts as activity only once its send is
        // accepted; a `window.open` dropped before founding (E-2) is not open.
        var opening: UInt32?
        if let type = object["t"] as? String,
           let value = object["stream"] as? Int,
           let stream = UInt32(exactly: value) {
            guard sendAllowed(type: type, stream: stream) else { return false }
            if ClosedStreams.opening.contains(type) { opening = stream }
        }
        let accepted = sendBytes(JSONFrame.encode(object))
        if let opening, accepted {
            closedStreamsLock.lock()
            closedStreams.opened(opening)
            closedStreamsLock.unlock()
        }
        return accepted
    }

    /// The one gate for a closed stream (WIN-38): false when the message must
    /// be dropped. Every per-stream JSON message and input frame comes through
    /// here, so a late hover flush, pause, resize or input from any caller
    /// never reaches a phone that has forgotten the stream.
    private func sendAllowed(type: String, stream: UInt32) -> Bool {
        closedStreamsLock.lock()
        let decision = closedStreams.decide(type: type, stream: stream)
        closedStreamsLock.unlock()
        guard decision == .drop else { return true }
        Log.session.notice("\(ClosedStreams.lateLog(type: type, stream: stream), privacy: .public)")
        return false
    }

    /// RRR-5: the phone ended this stream; it stops counting as activity.
    private func forgetStream(_ stream: UInt32) {
        closedStreamsLock.lock()
        closedStreams.forget(stream)
        closedStreamsLock.unlock()
    }

    #if PD_TEST_HOOKS
    private let sentLock = NSLock()
    private var sentMessages: [[String: Any]] = []

    /// Every message asked for under this type (`"window.open"`), oldest first.
    func sent(_ type: String) -> [[String: Any]] {
        sentLock.lock(); defer { sentLock.unlock() }
        return sentMessages.filter { $0["t"] as? String == type }
    }

    /// Forget what was asked: a test reads the messages of one phase.
    func clearSent() {
        sentLock.lock(); sentMessages.removeAll(); sentLock.unlock()
    }
    #endif

    func requestApps() { sendJSON(["t": "apps.list"]) }
    /// `px` is the pixel side of the 108 dp layer the Mac will draw (docs/PROTOCOL.md);
    /// an older phone ignores it and answers at 216.
    func requestIcon(pkg: String, px: Int? = nil) {
        var message: [String: Any] = ["t": "apps.icon", "pkg": pkg]
        if let px { message["px"] = px }
        sendJSON(message)
    }
    func openApp(stream: UInt32, pkg: String, activity: String?, width: Int, height: Int, dpi: Double,
                 newInstance: Bool = false) {
        sendPing()
        var message: [String: Any] = ["t": "window.open", "stream": Int(stream), "w": width, "h": height, "dpi": Int(dpi.rounded()), "pkg": pkg]
        if let activity { message["activity"] = activity }
        // WIN-25: another task of the app on this display, never a reuse of
        // the one that is there.
        if newInstance { message["newInstance"] = true }
        sendJSON(message)
    }
    /// WIN-46: one more window for a task the app started itself.
    func adoptTask(stream: UInt32, taskId: Int, pkg: String, width: Int, height: Int, dpi: Double) {
        sendPing()
        sendJSON(["t": "window.adopt", "stream": Int(stream), "taskId": taskId, "pkg": pkg,
                  "w": width, "h": height, "dpi": Int(dpi.rounded())])
    }
    func openLink(stream: UInt32, url: String, width: Int, height: Int, dpi: Double) {
        sendPing()
        sendJSON(["t": "link.open", "stream": Int(stream), "w": width, "h": height, "dpi": Int(dpi.rounded()), "url": url])
    }
    func openPhone(stream: UInt32, width: Int, height: Int, dpi: Double) {
        sendPing()
        sendJSON(["t": "window.open", "stream": Int(stream), "w": width, "h": height, "dpi": Int(dpi.rounded()), "mode": "phone"])
    }
    func continueTask(stream: UInt32, width: Int, height: Int, dpi: Double) {
        sendPing()
        sendJSON(["t": "task.continue", "stream": Int(stream), "w": width, "h": height, "dpi": Int(dpi.rounded())])
    }
    /// `task.front`: one read of the app in front on the phone's own screen
    /// (docs/PROTOCOL.md "Foreground app"); the reply echoes `seq`.
    func requestFront(seq: Int) {
        sendJSON(["t": "task.front", "seq": seq])
    }
    /// `ui.tree` (docs/PROTOCOL.md "UI tree", WIN-79): one read of the display a
    /// stream's window lives on. The reply echoes `seq` and is not a watch.
    func requestUITree(stream: UInt32, seq: Int) {
        sendPing()
        sendJSON(["t": "ui.tree", "stream": Int(stream), "seq": seq])
    }
    /// `ui.settle` (docs/PROTOCOL.md "UI tree" item 7, MCP-81): answer when the
    /// stream's display has not changed for `quietMs` with nothing loading, or
    /// at `timeoutMs`. Sent on the same ordered lane as the input before it.
    func requestUISettle(stream: UInt32, seq: Int, quietMs: Int, timeoutMs: Int) {
        sendJSON(["t": "ui.settle", "stream": Int(stream), "seq": seq,
                  "quietMs": quietMs, "timeoutMs": timeoutMs])
    }
    /// `ui.press` (docs/PROTOCOL.md "UI tree" item 8, MCP-86): press the node
    /// keyed `k` where it is now; `expect` is the label the asking client was
    /// last answered for it. Never logged: the label is on-screen text.
    /// `ui.type` (docs/PROTOCOL.md "UI tree" item 10, MCP-109): type into the
    /// focused field of the stream's display, as keys or by setting its text,
    /// never through the clipboard (MCP-110). Never logged: the text is the
    /// agent's input.
    func requestUIType(stream: UInt32, seq: Int, text: String, clear: Bool, submit: Bool) {
        sendJSON(["t": "ui.type", "stream": Int(stream), "seq": seq, "text": text,
                  "clear": clear, "submit": submit])
    }
    func requestUIPress(stream: UInt32, seq: Int, k: Int, holdMs: Int?, expect: String?) {
        var message: [String: Any] = ["t": "ui.press", "stream": Int(stream), "seq": seq, "k": k]
        if let holdMs { message["holdMs"] = holdMs }
        if let expect { message["expect"] = expect }
        sendJSON(message)
    }
    func resizeWindow(stream: UInt32, width: Int, height: Int, dpi: Double) {
        sendJSON(["t": "window.resize", "stream": Int(stream), "w": width, "h": height, "dpi": Int(dpi.rounded())])
    }
    func closeWindow(stream: UInt32) { sendJSON(["t": "window.close", "stream": Int(stream)]) }
    func pauseWindow(stream: UInt32) {
        guard sendJSON(["t": "window.pause", "stream": Int(stream)]) else { return }
        closedStreamsLock.lock()
        closedStreams.pause(stream)
        closedStreamsLock.unlock()
    }
    func resumeWindow(stream: UInt32) {
        guard sendJSON(["t": "window.resume", "stream": Int(stream)]) else { return }
        closedStreamsLock.lock()
        closedStreams.resume(stream)
        closedStreamsLock.unlock()
    }
    func requestKeyframe(stream: UInt32) { sendJSON(["t": "window.keyframe", "stream": Int(stream)]) }

    /// Session-wide `stream.stats` switch (docs/PROTOCOL.md "Stream stats"):
    /// while on, the phone reports each streaming window every 2 s. The Mac
    /// turns it on with the first window and off with the last. False when the
    /// session is not ready: the caller asks again rather than losing the ask.
    @discardableResult
    func setStreamStats(_ on: Bool) -> Bool {
        sendJSON(["t": "stream.stats", "on": on])
    }
    func launch(stream: UInt32, pkg: String, activity: String?) {
        var message: [String: Any] = ["t": "window.launch", "stream": Int(stream), "pkg": pkg]
        if let activity { message["activity"] = activity }
        sendJSON(message)
    }
    func nav(stream: UInt32, action: String) { sendJSON(["t": "nav", "stream": Int(stream), "action": action]) }
    /// `phone.wake`: wake the phone's own screen; the keyguard stays
    /// (docs/PROTOCOL.md "Phone screen").
    func wakePhone() { sendJSON(["t": "phone.wake"]) }
    /// `phone.panel`: hold the mirrored panel off, or give it back. [ignorePower]
    /// is the Mac's keep-it-off setting (docs/PROTOCOL.md "Phone screen").
    func setPhonePanel(off: Bool, ignorePower: Bool = false) {
        sendJSON(["t": "phone.panel", "off": off, "ignorePower": ignorePower])
    }
    func startAudio(codecs: [Int] = [Int(AudioConfig.codecOpus), Int(AudioConfig.codecAAC)]) { sendJSON(["t": "audio.start", "codecs": codecs]) }
    func stopAudio() { sendJSON(["t": "audio.stop"]) }
    func text(stream: UInt32, text: String) { sendJSON(["t": "text", "stream": Int(stream), "text": text]) }
    func installApk(id: UInt32, files: [[String: Any]]) { sendJSON(["t": "apk.install", "id": Int(id), "files": files]) }
    func cancelApk(id: UInt32) { sendJSON(["t": "apk.cancel", "id": Int(id)]) }
    func enableNotifications(_ on: Bool) {
        // Remembered so a same-session rejoin after an outage can repeat it
        // (NOTIFY-1/PATH-6): the phone answers with its active set.
        notifyEnabled.set(on)
        sendJSON(["t": "notify.enable", "on": on])
    }
    /// The Mac's own "Share clipboard with your phone" setting, sent at ready and
    /// on every change: the phone has no switch, so this is what stops its sends.
    func enableClipboard(_ on: Bool) { sendJSON(["t": "clip.enable", "on": on]) }

    /// A Mac banner click (docs/design/notify.md): run the phone notification's
    /// own action on the window's display or on the phone's screen. The id is
    /// one the phone issued; an older phone ignores the message, which leaves
    /// the window at its launcher activity (today's behaviour).
    func openNotification(id: String, target: NotifyOpenTarget, stream: UInt32? = nil) {
        sendJSON(NotifyOpenMessage.make(id: id, target: target, stream: stream))
    }

    /// `notify.action` (docs/design/notify.md): press one of the actions the
    /// phone advertised for this id; `text` only rides along for a reply action.
    func notifyAction(id: String, index: Int, text: String?) {
        var message: [String: Any] = ["t": "notify.action", "id": id, "i": index]
        if let text, !text.isEmpty { message["text"] = text }
        sendJSON(message)
    }

    /// `notify.dismiss`: clear that forwarded notification on the phone.
    func notifyDismiss(id: String) {
        sendJSON(["t": "notify.dismiss", "id": id])
    }

    /// `media.command` (docs/design/notify.md "Media part 2"): transport, a
    /// seek position or a volume level, optionally for one session key.
    func mediaCommand(_ command: MediaCommand, key: String? = nil) {
        sendJSON(MediaMessage.command(command, key: key))
    }

    /// `media.choose`: which phone session Now Playing follows.
    func mediaChoose(_ key: String) { sendJSON(MediaMessage.choose(key: key)) }

    /// `phone.ring` (docs/PROTOCOL.md "Ring"): the phone's app plays its alarm
    /// over the lock screen, at the alarm volume, for at most 30 s.
    func ring(seconds: Int = 30) { sendJSON(["t": "phone.ring", "seconds": max(1, min(30, seconds))]) }

    func stopRing() { sendJSON(["t": "phone.ring.stop"]) }

    /// `phone.dnd` (docs/PROTOCOL.md "Focus and Do Not Disturb").
    func setDnd(_ mode: PhoneDndMode) { sendJSON(["t": "phone.dnd", "mode": mode.rawValue]) }

    /// `phone.ringer` (docs/PROTOCOL.md "Ringer").
    func setRinger(_ mode: PhoneRingerMode) { sendJSON(["t": "phone.ringer", "mode": mode.rawValue]) }

    /// `phone.volume` (docs/PROTOCOL.md "Volume"): the phone's music stream.
    func setVolume(_ level: Int) { sendJSON(["t": "phone.volume", "level": level]) }
    func sendApkData(id: UInt32, bytes: [UInt8], sent: @escaping @Sendable (Bool) -> Void) { sendData(.apkData, id: id, bytes: bytes, sent: sent) }
    func dropStart(id: UInt32, name: String, mime: String, size: Int, sha256: String, resume: Int = 0,
                   target: String? = nil, index: Int = 1, count: Int = 1) {
        var message: [String: Any] = ["t": "drop.start", "id": Int(id), "name": name, "mime": mime, "size": size, "sha256": sha256]
        if resume > 0 { message["resume"] = resume }
        if let target { message["target"] = target }
        // The batch position always rides the wire: the phone shares once,
        // after the last file (SHARE-17).
        message["index"] = index
        message["count"] = count
        sendJSON(message)
    }
    func cancelDrop(id: UInt32) { sendJSON(["t": "drop.cancel", "id": Int(id)]) }
    func sendDropData(id: UInt32, bytes: [UInt8], sent: @escaping @Sendable (Bool) -> Void) { sendData(.dropData, id: id, bytes: bytes, sent: sent) }
    func clipImageStart(id: UInt32, mime: String, size: Int, paste: Bool = false) {
        var message: [String: Any] = ["t": "clip.image.start", "id": Int(id), "mime": mime, "size": size]
        // A person's own ⌘V is explicit, like a drop: it bypasses the sync
        // switch (SHARE-16). The switch governs only the background sync.
        if paste { message["paste"] = true }
        sendJSON(message)
    }
    func clipImageEnd(id: UInt32, size: Int, sha256: String) { sendJSON(["t": "clip.image.end", "id": Int(id), "size": size, "sha256": sha256]) }
    func clipImageAbort(id: UInt32) { sendJSON(["t": "clip.image.abort", "id": Int(id)]) }
    func sendClipData(id: UInt32, bytes: [UInt8], sent: @escaping @Sendable (Bool) -> Void) { sendData(.clipData, id: id, bytes: bytes, sent: sent) }

    // MARK: Phone files (read-only, docs/design/files.md)

    func fsList(id: UInt32, path: String, page: String?) {
        var message: [String: Any] = ["t": "fs.list", "id": Int(id), "path": path]
        if let page { message["page"] = page }
        sendJSON(message)
    }
    func fsStat(id: UInt32, path: String) {
        sendJSON(["t": "fs.stat", "id": Int(id), "path": path])
    }
    func fsDigest(id: UInt32, paths: [String]) {
        sendJSON(["t": "fs.digest", "id": Int(id), "paths": paths])
    }
    func fsRead(id: UInt32, path: String, offset: Int, length: Int, etag: String?) {
        var message: [String: Any] = ["t": "fs.read", "id": Int(id), "path": path,
                                      "offset": offset, "length": length]
        if let etag { message["etag"] = etag }
        sendJSON(message)
    }
    func fsThumb(id: UInt32, path: String, size: Int, etag: String?) {
        var message: [String: Any] = ["t": "fs.thumb", "id": Int(id), "path": path, "size": size]
        if let etag { message["etag"] = etag }
        sendJSON(message)
    }
    func fsCancel(id: UInt32) {
        let accepted = sendJSON(["t": "fs.cancel", "id": Int(id)])
        Log.files.notice("session: fs.cancel sent ok=\(accepted, privacy: .public)")  // log-ok: a closed flag, no name
    }
    func fsWrite(id: UInt32, path: String, size: Int, sha256: String, etag: String?,
                 exclusive: Bool) {
        var message: [String: Any] = ["t": "fs.write", "id": Int(id), "path": path,
                                      "size": size, "sha256": sha256]
        if let etag { message["etag"] = etag }
        if exclusive { message["exclusive"] = true }
        sendJSON(message)
    }
    func fsWriteData(id: UInt32, bytes: [UInt8], sent: @escaping @Sendable (Bool) -> Void) {
        sendData(.fsData, id: id, bytes: bytes, sent: sent)
    }
    func fsMove(id: UInt32, from: String, to: String, etag: String?) {
        var message: [String: Any] = ["t": "fs.move", "id": Int(id), "from": from, "to": to]
        if let etag { message["etag"] = etag }
        sendJSON(message)
    }
    func fsDelete(id: UInt32, path: String, recursive: Bool, etag: String?) {
        var message: [String: Any] = ["t": "fs.delete", "id": Int(id), "path": path,
                                      "recursive": recursive]
        if let etag { message["etag"] = etag }
        sendJSON(message)
    }
    func fsMkdir(id: UInt32, path: String) {
        sendJSON(["t": "fs.mkdir", "id": Int(id), "path": path])
    }
    func fsSetAttrs(id: UInt32, path: String, mtime: Int) {
        sendJSON(["t": "fs.setAttrs", "id": Int(id), "path": path, "mtime": mtime])
    }
    func fsWatch(id: UInt32, paths: [String], on: Bool) {
        sendJSON(["t": on ? "fs.watch" : "fs.unwatch", "id": Int(id), "paths": paths])
    }
    private func sendData(_ kind: MessageType, id: UInt32, bytes: [UInt8], sent: @escaping @Sendable (Bool) -> Void) {
        // The replay buffer holds the frame; the completion means "accepted for
        // delivery", so a producer waits on credit without blocking the UI,
        // and an orphaned session keeps the frame for the join (PATH-6, R-4).
        // Before founding it is dropped with `sent(false)` (E-2): a FileDrop
        // then fails the transfer instead of waiting for a seq that is gone.
        sendReliable(Frame(type: kind, stream: id, payload: bytes), completion: sent)
    }
    func sendClipboard(_ text: String) { sendJSON(["t": "clip.set", "text": text]) }
    func touch(_ event: TouchEvent, stream: UInt32) {
        sendInput(Frame(type: .touch, stream: stream, payload: event.payload), type: "touch")
    }
    func scroll(_ event: ScrollEvent, stream: UInt32) {
        sendInput(Frame(type: .scroll, stream: stream, payload: event.payload), type: "scroll")
    }
    func hover(_ event: HoverEvent, stream: UInt32) {
        sendInput(Frame(type: .hover, stream: stream, payload: event.payload), type: "hover")
    }
    func key(_ event: KeyEvent, stream: UInt32) {
        sendInput(Frame(type: .key, stream: stream, payload: event.payload), type: "key")
    }

    private func sendInput(_ frame: Frame, type: String) {
        guard sendAllowed(type: type, stream: frame.stream) else { return }
        sendBytes(frame.encoded)
    }

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

/// The phone's `ui.type` reply (PROTOCOL.md "UI tree" item 10, MCP-109): how
/// it typed, or the code it refused with, having typed nothing. Never the text.
struct UITypeReply: Equatable {
    let seq: Int
    let stream: UInt32
    let ok: Bool
    /// `inserted`, `replaced` or `unknown`.
    let entry: String?
    /// `keys` or `set_text`.
    let via: String?
    /// The text's length in code points, as the phone counted it.
    let characters: Int?
    let code: String?

    init(seq: Int, stream: UInt32, ok: Bool, entry: String? = nil, via: String? = nil,
         characters: Int? = nil, code: String? = nil) {
        self.seq = seq
        self.stream = stream
        self.ok = ok
        self.entry = entry
        self.via = via
        self.characters = characters
        self.code = code
    }

    init?(message: JSONMessage) {
        guard let ok = message.bool("ok"), let stream = message.int("stream") else { return nil }
        self.init(seq: message.int("seq") ?? 0, stream: UInt32(max(0, stream)), ok: ok,
                  entry: message.string("entry"), via: message.string("via"),
                  characters: message.int("characters"), code: message.string("code"))
    }
}
