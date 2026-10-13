// One TCP session per phone. Owns the NWConnection, the framed reader/writer,
// the handshake state machine, the 15 s app-level ping and reconnect.
//
// Everything the rest of the app sees is a `SessionEvent` delivered on the
// main queue; video frames included (the display layer hops to its own queue).

import Foundation
import Network

enum SessionState: Equatable {
    case idle
    case connecting
    case handshaking
    case ready
    case failed(String)
    case closed
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

enum SessionEvent {    case state(SessionState, String?)
    case ready(PhoneInfo, isReconnect: Bool, address: CachedAddress?)
    case apps([AppInfo])
    case icon(pkg: String, png: Data)
    case windowOpened(stream: UInt32, displayId: Int, width: Int, height: Int)
    case windowClosed(stream: UInt32, reason: String)
    case windowTitle(stream: UInt32, label: String, pkg: String)
    case phoneState(locked: Bool, battery: Int, charging: Bool)
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
}

final class Session {
    enum Endpoint {
        case hostPort(host: String, port: UInt16)
        /// `pinnedTo`: connect only over the interface the service was found on.
        case service(NWEndpoint, pinnedTo: NWInterface? = nil)
    }

    private let endpoint: Endpoint
    private let keyStore: PairKeyStore
    private var knownDeviceId: String?
    /// Set when the endpoint is a cached address for this exact device id: the
    /// challenge must name it, or the connection is refused (the address may
    /// have been handed to another phone).
    private let strictDeviceId: String?

    private let clientId: String
    private var connection: NWConnection?
    private var decoder = FrameDecoder()
    private let queue = DispatchQueue(label: "dev.pocketdeck.session")
    private var pingTimer: Timer?
    private var connectWatchdog: DispatchWorkItem?
    /// Armed while a person decides on the phone; the phone's own 120 s limit
    /// normally answers first, this covers a phone that vanished mid-prompt.
    private var pairingDeadline: DispatchWorkItem?
    /// `connection` is swapped from the session queue and from the main queue
    /// (watchdog, close); every swap goes through `takeConnection`.
    private let connectionLock = NSLock()
    private var pendingPairKey: Data?
    /// The session-level `error` code the phone sent on this connection, if any.
    private var phoneErrorCode: String?
    private var authDeviceId: String?
    private var authInFlight = false
    private var authAttempts = 0
    private var everReady = false
    private var intentionalClose = false
    private var loggedUnknown: Set<String> = []
    /// Key from an open QR sheet: tried before any stored key, and a rejection
    /// never falls back to the code flow (`pair.request`).
    private var qrKey: Data?
    private var authedWithQRKey = false

    /// What a handshake may do when the phone asks for a pairing and we hold
    /// no key for it. Automatic reconnects must never ask the phone to show a
    /// code (it would prompt for a Mac the user is not pairing); only a
    /// user-driven session may send `pair.request`.
    enum PairingPolicy { case never, allowed }
    var pairingPolicy: PairingPolicy = .allowed

    private(set) var state: SessionState = .idle
    private(set) var phone: PhoneInfo?

    /// All events, on the main queue.
    var onEvent: ((SessionEvent) -> Void)?

    /// Video is delivered synchronously on the session queue: frames never hop
    /// through the main thread before reaching their display layer.
    var onVideoEvent: ((VideoEvent) -> Void)?

    static let pingInterval: TimeInterval = 15
    /// One attempt gets this long to reach `welcome` (or, when pairing, the
    /// phone's code). A Bonjour connection can stay in `waiting` forever (an
    /// interface that cannot reach the phone); the owner needs a failure to try
    /// again, and the socket must be cancelled.
    static let defaultConnectTimeout: TimeInterval = 6
    /// The phone gives a person 120 s to answer (docs/PROTOCOL.md "Pairing").
    static let defaultPairingTimeout: TimeInterval = 125

    private let connectTimeout: TimeInterval
    private let pairingTimeout: TimeInterval

    init(endpoint: Endpoint, knownDeviceId: String?, strictDeviceId: String? = nil,
         clientId: String, keyStore: PairKeyStore,
         connectTimeout: TimeInterval = Session.defaultConnectTimeout,
         pairingTimeout: TimeInterval = Session.defaultPairingTimeout) {
        self.endpoint = endpoint
        self.knownDeviceId = knownDeviceId
        self.strictDeviceId = strictDeviceId
        self.clientId = clientId
        self.keyStore = keyStore
        self.connectTimeout = connectTimeout
        self.pairingTimeout = pairingTimeout
    }

    convenience init(host: String, port: UInt16, knownDeviceId: String? = nil,
                     clientId: String, keyStore: PairKeyStore) {
        self.init(endpoint: .hostPort(host: host, port: port), knownDeviceId: knownDeviceId,
                  clientId: clientId, keyStore: keyStore)
    }

    // MARK: Lifecycle

    func start() {
        intentionalClose = false
        transition(.connecting, nil)
        let options = Self.tcpParameters(for: endpoint)
        let conn: NWConnection
        switch endpoint {
        case .hostPort(let host, let port):
            conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port) ?? 1, using: options)
        case .service(let service, _):
            conn = NWConnection(to: service, using: options)
        }
        Log.session.info("connecting (\(self.describeEndpoint(), privacy: .public))")
        connectionLock.lock()
        connection = conn
        connectionLock.unlock()
        decoder = FrameDecoder()
        phoneErrorCode = nil
        authedWithQRKey = false
        conn.stateUpdateHandler = { [weak self] newState in self?.handleConnectionState(newState, on: conn) }
        conn.start(queue: queue)
        receive(on: conn)
        armConnectWatchdog()
    }

    func close() {
        intentionalClose = true
        cancelTimers()
        retire(takeConnection(ifCurrent: nil))
        transition(.closed, nil)
    }

    /// Detaches the live connection (only if `conn` still is it; nil = whichever
    /// is live) so the caller can cancel it exactly once.
    private func takeConnection(ifCurrent conn: NWConnection?) -> NWConnection? {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        guard let current = connection, conn == nil || conn === current else { return nil }
        connection = nil
        return current
    }

    private var currentConnection: NWConnection? {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        return connection
    }

    private func isCurrent(_ conn: NWConnection) -> Bool {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        return connection === conn
    }

    /// Every dropped connection is cancelled: the phone serves one session, and a
    /// socket that is merely forgotten keeps its slot (or lets a late TCP
    /// completion open a session nobody speaks on).
    private func retire(_ conn: NWConnection?) {
        guard let conn else { return }
        conn.stateUpdateHandler = nil
        conn.cancel()
    }

    /// A session that has not reached `ready` in time is treated as failed, so
    /// the app can try the cached address; `waiting` alone never fails.
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

    /// The phone showed its code: from here the person, not the network, sets
    /// the pace, so the connect watchdog gives way to the pairing deadline.
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

    /// A Bonjour service is advertised on every interface the phone's Wi-Fi
    /// reaches and on any VM/VPN bridge the Mac has; Network.framework may pick
    /// an interface that cannot reach it and wait there forever. The first
    /// attempt is pinned to the interface the browser found the phone on (Wi-Fi
    /// first); the owner alternates with an unpinned attempt after a failure. A
    /// plain host:port keeps the defaults (tests connect over loopback).
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

    private func transition(_ newState: SessionState, _ detail: String?) {
        state = newState
        emit(.state(newState, detail))
    }

    // MARK: Receive

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, self.isCurrent(conn) else { return }
            if let data, !data.isEmpty {
                do {
                    for frame in try self.decoder.append(data) { self.handleFrame(frame) }
                } catch {
                    Log.session.error("framing error: \(String(describing: error), privacy: .public)")
                    self.emit(.protocolViolation(String(describing: error)))
                    self.fail("framing", on: conn)
                    return
                }
            }
            if let error {
                Log.session.error("receive error: \(String(describing: error), privacy: .public)")
                self.fail("receive", on: conn)
                return
            }
            if isComplete { self.fail("closed-by-peer", on: conn); return }
            self.receive(on: conn)
        }
    }

    private func handleConnectionState(_ newState: NWConnection.State, on conn: NWConnection) {
        guard isCurrent(conn) else { retire(conn); return }
        switch newState {
        case .ready:
            Log.session.info("tcp ready; sending hello")
            transition(.handshaking, nil)
            sendJSON(["t": "hello", "v": 1, "clientId": clientId, "name": ClientIdentity.name])
        case .waiting(let error):
            Log.session.notice("connection waiting: \(String(describing: error), privacy: .public)")
        case .failed(let error):
            Log.session.error("connection failed: \(String(describing: error), privacy: .public)")
            fail("failed", on: conn)
        case .cancelled:
            if !intentionalClose { fail("cancelled", on: conn) } else { transition(.closed, nil) }
        default:
            break
        }
    }

    /// `transportReason` says what the socket did; the phone's error frame
    /// says more and wins. Fails once per
    /// connection: a second report for the same (or an already replaced)
    /// connection is ignored. Never retries: the owner decides when to try again.
    private func fail(_ transportReason: String, on conn: NWConnection? = nil) {
        guard let dead = takeConnection(ifCurrent: conn) else { return }
        retire(dead)
        cancelTimers()
        let reason = phoneErrorCode ?? transportReason
        phoneErrorCode = nil
        // Some servers close right after rejecting auth without the error frame
        // surviving the close; two failed auth handshakes mean the key is stale.
        if authInFlight, authAttempts >= 2 {
            Log.session.notice("auth rejected twice; forgetting pairing key")
            forgetAuthKey()
        }
        guard !intentionalClose else { transition(.closed, nil); return }
        transition(.failed(reason), reason)
    }

    /// The endpoint belongs to a different phone now: never authenticate and
    /// never reconnect to it. The owner drops the cached address on the event.
    private func refuseIdentityMismatch() {
        intentionalClose = true
        cancelTimers()
        retire(takeConnection(ifCurrent: nil))
        transition(.failed(ConnectionFailure.identityMismatch), ConnectionFailure.identityMismatch)
    }

    // MARK: Frame dispatch

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
        default:
            Log.session.notice("ignoring phone->mac frame type \(frame.type, privacy: .public)")
        }
    }

    private func handleJSON(_ message: JSONMessage) {
        switch message.t {
        case "challenge":
            let nonce = message.string("nonce") ?? ""
            // The challenge names the phone, which picks the right key even when
            // we connected by address rather than through discovery.
            if let id = message.string("id"), !id.isEmpty {
                if let expected = strictDeviceId, id != expected {
                    // A cached address must keep belonging to the same phone.
                    Log.session.error("address answers as \(id, privacy: .public), expected \(expected, privacy: .public); dropping")
                    emit(.identityMismatch(expected: expected, actual: id))
                    refuseIdentityMismatch()
                    return
                }
                knownDeviceId = id
            }
            // An open QR sheet takes precedence: the phone has the key as soon as
            // the user scans, and until then `auth_failed` is the expected answer
            // (never `pair.request`, which would spam the phone with prompts).
            if let key = qrKey {
                authDeviceId = knownDeviceId
                authInFlight = false
                authAttempts = 0
                authedWithQRKey = true
                sendJSON(["t": "auth", "mac": PairCrypto.hmacHex(key: key, nonceHex: nonce)])
                return
            }
            if let candidate = keyStore.candidateKey(knownDeviceId: knownDeviceId) {
                authDeviceId = candidate.deviceId
                authInFlight = true
                authAttempts += 1
                sendJSON(["t": "auth", "mac": PairCrypto.hmacHex(key: candidate.key, nonceHex: nonce)])
            } else if pairingPolicy == .never {
                // Nothing to authenticate with and nobody asked to pair: do not
                // make the phone show a code.
                authDeviceId = nil
                authInFlight = false
                authAttempts = 0
                phoneErrorCode = "auth_failed"
                fail("no-key")
            } else {
                authDeviceId = nil
                authInFlight = false
                authAttempts = 0
                sendJSON(["t": "pair.request"])
            }
        case "pair.code_shown":
            // The phone waits for its person (up to 120 s); the connect
            // watchdog must not cut them off in the meantime.
            guard let code = message.string("code"), !code.isEmpty else {
                // A phone that predates the shown-code protocol expects the code to be typed.
                phoneErrorCode = "version"
                fail("version")
                return
            }
            armPairingDeadline()
            emit(.pairCodeShown(deviceId: knownDeviceId, code: code))
        case "pair.ok":
            if let hex = message.string("key") { pendingPairKey = Data(hexString: hex) }
            emit(.pairApproved)
        case "welcome":
            guard let device = message.object("device"), let info = PhoneInfo(device: device) else {
                Log.session.error("welcome without device")
                return
            }
            if let key = pendingPairKey {
                keyStore.store(key: key, deviceId: info.id)
                pendingPairKey = nil
            }
            if authedWithQRKey, let key = qrKey {
                // Scanning is the consent: the phone already stored the same key.
                keyStore.store(key: key, deviceId: info.id)
                qrKey = nil
                authedWithQRKey = false
                emit(.qrPaired(deviceId: info.id))
            }
            knownDeviceId = info.id
            phone = info
            authAttempts = 0
            authInFlight = false
            connectWatchdog?.cancel()
            connectWatchdog = nil
            pairingDeadline?.cancel()
            pairingDeadline = nil
            startPing()
            let isReconnect = everReady
            everReady = true
            let address = currentConnection?.currentPath?.remoteEndpoint?.resolvedIPv4Address
            transition(.ready, nil)
            emit(.ready(info, isReconnect: isReconnect, address: address))
        case "apps":
            let apps = (message.array("apps") ?? []).compactMap { AppInfo(json: $0) }
            emit(.apps(apps))
        case "icon":
            if let pkg = message.string("pkg"), let b64 = message.string("png"), let png = Data(base64Encoded: b64) {
                emit(.icon(pkg: pkg, png: png))
            }
        case "window.opened":
            emit(.windowOpened(stream: UInt32(message.int("stream") ?? 0),
                               displayId: message.int("displayId") ?? 0,
                               width: message.int("w") ?? 0,
                               height: message.int("h") ?? 0))
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
        case "pong":
            break
        case "error":
            let code = message.string("code") ?? "unknown"
            if code == "auth_failed", !authedWithQRKey {
                forgetAuthKey()
            }
            // Errors about one stream leave the session up; the rest end it.
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

    // MARK: Ping

    private func startPing() {
        pingTimer?.invalidate()
        let timer = Timer(timeInterval: Self.pingInterval, repeats: true) { [weak self] _ in
            self?.sendJSON(["t": "ping", "ts": Int(Date().timeIntervalSince1970 * 1000)])
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    // MARK: Pairing

    /// The key currently shown in a QR sheet. While set, the handshake
    /// authenticates with it and never asks the phone to show a code.
    func usePairingKey(_ key: Data) { qrKey = key }

    func clearPairingKey() {
        qrKey = nil
        authedWithQRKey = false
    }

    /// Drop the key we tried so the next handshake pairs instead of looping.
    private func forgetAuthKey() {
        guard !authedWithQRKey else { return }
        if let id = authDeviceId ?? knownDeviceId { keyStore.forget(deviceId: id) }
        authDeviceId = nil
        knownDeviceId = nil
        authInFlight = false
        authAttempts = 0
    }

    // MARK: Send

    private func emit(_ event: SessionEvent) {
        if Thread.isMainThread {
            onEvent?(event)
        } else {
            DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
        }
    }

    func sendBytes(_ bytes: [UInt8]) {
        guard let connection = currentConnection else { return }
        connection.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    func sendJSON(_ object: [String: Any]) {
        sendBytes(JSONFrame.encode(object))
    }

    func requestApps() { sendJSON(["t": "apps.list"]) }

    func requestIcon(pkg: String) { sendJSON(["t": "apps.icon", "pkg": pkg]) }

    func openApp(stream: UInt32, pkg: String, activity: String?, width: Int, height: Int, dpi: Double) {
        var message: [String: Any] = ["t": "window.open", "stream": Int(stream),
                                      "w": width, "h": height, "dpi": Int(dpi.rounded()),
                                      "pkg": pkg]
        if let activity { message["activity"] = activity }
        sendJSON(message)
    }

    func openPhone(stream: UInt32, width: Int, height: Int, dpi: Double) {
        sendJSON(["t": "window.open", "stream": Int(stream), "w": width, "h": height,
                  "dpi": Int(dpi.rounded()), "mode": "phone"])
    }

    func resizeWindow(stream: UInt32, width: Int, height: Int, dpi: Double) {
        sendJSON(["t": "window.resize", "stream": Int(stream), "w": width, "h": height,
                  "dpi": Int(dpi.rounded())])
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

    func nav(stream: UInt32, action: String) {
        sendJSON(["t": "nav", "stream": Int(stream), "action": action])
    }

    func text(stream: UInt32, text: String) {
        sendJSON(["t": "text", "stream": Int(stream), "text": text])
    }

    func touch(_ event: TouchEvent, stream: UInt32) {
        sendBytes(Frame(type: .touch, stream: stream, payload: event.payload).encoded)
    }

    func scroll(_ event: ScrollEvent, stream: UInt32) {
        sendBytes(Frame(type: .scroll, stream: stream, payload: event.payload).encoded)
    }

    func key(_ event: KeyEvent, stream: UInt32) {
        sendBytes(Frame(type: .key, stream: stream, payload: event.payload).encoded)
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
}
