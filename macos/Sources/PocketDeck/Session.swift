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
    case pairCodeRequired(deviceId: String?)
    /// The phone accepted the key we were showing in a QR: it is stored now.
    case qrPaired(deviceId: String)
    /// A cached address answered with a different device id: refuse it.
    case identityMismatch(expected: String, actual: String)
    case protocolViolation(String)
}

final class Session {
    enum Endpoint {
        case hostPort(host: String, port: UInt16)
        case service(NWEndpoint)
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
    private var reconnectAttempt = 0
    private var pendingPairKey: Data?
    private var awaitingPairCode = false
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

    /// QR probes connect once and stop; the launcher's session reconnects.
    var autoReconnect = true

    private(set) var state: SessionState = .idle
    private(set) var phone: PhoneInfo?

    /// All events, on the main queue.
    var onEvent: ((SessionEvent) -> Void)?

    /// Video is delivered synchronously on the session queue: frames never hop
    /// through the main thread before reaching their display layer.
    var onVideoEvent: ((VideoEvent) -> Void)?

    static let pingInterval: TimeInterval = 15
    static let backoff: [TimeInterval] = [1, 2, 4, 8, 15]
    /// A Bonjour connection can stay in `waiting` forever when the phone stops
    /// answering mDNS; the caller needs a failure event to fall back to its
    /// cached address.
    static let connectTimeout: TimeInterval = 10

    init(endpoint: Endpoint, knownDeviceId: String?, strictDeviceId: String? = nil,
         clientId: String, keyStore: PairKeyStore) {
        self.endpoint = endpoint
        self.knownDeviceId = knownDeviceId
        self.strictDeviceId = strictDeviceId
        self.clientId = clientId
        self.keyStore = keyStore
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
        let options = Self.tcpParameters()
        let conn: NWConnection
        switch endpoint {
        case .hostPort(let host, let port):
            conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port) ?? 1, using: options)
        case .service(let service):
            conn = NWConnection(to: service, using: options)
        }
        Log.session.info("connecting (\(self.describeEndpoint(), privacy: .public))")
        connection = conn
        decoder = FrameDecoder()
        awaitingPairCode = false
        phoneErrorCode = nil
        authedWithQRKey = false
        conn.stateUpdateHandler = { [weak self] newState in self?.handleConnectionState(newState, on: conn) }
        conn.start(queue: queue)
        receive(on: conn)
        armConnectWatchdog()
    }

    func close() {
        intentionalClose = true
        connectWatchdog?.cancel()
        connectWatchdog = nil
        pingTimer?.invalidate()
        pingTimer = nil
        connection?.cancel()
        connection = nil
        transition(.closed, nil)
    }

    /// A session that has not reached `ready` in time is treated as failed, so
    /// the app can try the cached address; `waiting` alone never fails.
    private func armConnectWatchdog() {
        connectWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.intentionalClose, self.state != .ready else { return }
            Log.session.notice("connect timed out after \(Self.connectTimeout, privacy: .public)s")
            self.fail("timeout")
        }
        connectWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTimeout, execute: work)
    }

    private static func tcpParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 10
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 15
        }
        return parameters
    }

    private func describeEndpoint() -> String {
        switch endpoint {
        case .hostPort(let host, let port): return "\(host):\(port)"
        case .service(let service): return String(describing: service)
        }
    }

    private func transition(_ newState: SessionState, _ detail: String?) {
        state = newState
        emit(.state(newState, detail))
    }

    // MARK: Receive

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for frame in try self.decoder.append(data) { self.handleFrame(frame) }
                } catch {
                    Log.session.error("framing error: \(String(describing: error), privacy: .public)")
                    self.emit(.protocolViolation(String(describing: error)))
                    self.fail("framing")
                    return
                }
            }
            if let error {
                Log.session.error("receive error: \(String(describing: error), privacy: .public)")
                self.fail("receive")
                return
            }
            if isComplete { self.fail("closed-by-peer"); return }
            self.receive(on: conn)
        }
    }

    private func handleConnectionState(_ newState: NWConnection.State, on conn: NWConnection) {
        switch newState {
        case .ready:
            Log.session.info("tcp ready; sending hello")
            transition(.handshaking, nil)
            sendJSON(["t": "hello", "v": 1, "clientId": clientId, "name": ClientIdentity.name])
        case .waiting(let error):
            Log.session.notice("connection waiting: \(String(describing: error), privacy: .public)")
        case .failed(let error):
            Log.session.error("connection failed: \(String(describing: error), privacy: .public)")
            fail("failed")
        case .cancelled:
            if !intentionalClose { fail("cancelled") } else { transition(.closed, nil) }
        default:
            break
        }
    }

    /// `transportReason` says what the socket did; the phone's error frame, or
    /// a close while the code was awaited, says more and wins.
    private func fail(_ transportReason: String) {
        connectWatchdog?.cancel()
        connectWatchdog = nil
        pingTimer?.invalidate()
        pingTimer = nil
        connection?.stateUpdateHandler = nil
        connection = nil
        let reason = phoneErrorCode ?? (awaitingPairCode ? ConnectionFailure.pairingTimeout : transportReason)
        phoneErrorCode = nil
        awaitingPairCode = false
        // Some servers close right after rejecting auth without the error frame
        // surviving the close; two failed auth handshakes mean the key is stale.
        if authInFlight, authAttempts >= 2 {
            Log.session.notice("auth rejected twice; forgetting pairing key")
            forgetAuthKey()
        }
        guard !intentionalClose else { transition(.closed, nil); return }
        transition(.failed(reason), reason)
        guard autoReconnect, ConnectionFailure.retriesAutomatically(reason) else { return }
        let delay = Self.backoff[min(reconnectAttempt, Self.backoff.count - 1)]
        reconnectAttempt += 1
        Log.session.notice("reconnect in \(delay, privacy: .public)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.intentionalClose else { return }
            self.start()
        }
    }

    /// The endpoint belongs to a different phone now: never authenticate and
    /// never reconnect to it. The owner drops the cached address on the event.
    private func refuseIdentityMismatch() {
        intentionalClose = true
        connectWatchdog?.cancel()
        connectWatchdog = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
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
            } else {
                authDeviceId = nil
                authInFlight = false
                authAttempts = 0
                sendJSON(["t": "pair.request"])
            }
        case "pair.code_shown":
            awaitingPairCode = true
            // The phone times the code entry itself (its own 15 s window); the
            // connect watchdog must not cut the user off in the meantime.
            connectWatchdog?.cancel()
            connectWatchdog = nil
            emit(.pairCodeRequired(deviceId: knownDeviceId))
        case "pair.ok":
            if let hex = message.string("key") { pendingPairKey = Data(hexString: hex) }
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
            reconnectAttempt = 0
            authAttempts = 0
            authInFlight = false
            connectWatchdog?.cancel()
            connectWatchdog = nil
            startPing()
            let isReconnect = everReady
            everReady = true
            let address = connection?.currentPath?.remoteEndpoint?.resolvedIPv4Address
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

    /// Called by the UI (or the `--pair-code-file` hook) once a code exists.
    func providePairCode(_ code: String) {
        guard awaitingPairCode else { return }
        awaitingPairCode = false
        sendJSON(["t": "pair.confirm", "code": code])
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
        guard let connection else { return }
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
