// App entry point: launch-option parsing, the app-wide model that ties
// Discovery + Session + WindowManager together, and the test hooks.

import AppKit

// MARK: - Launch options (see macos/README.md)

struct LaunchOptions {
    var connect: (host: String, port: UInt16)?
    var pairCodeFile: String?
    var openPackages: [String] = []
    var openPhone = false
    var resizes: [(stream: UInt32, size: NSSize, after: TimeInterval)] = []
    var minimizes: [(stream: UInt32, after: TimeInterval)] = []
    var deminimizes: [(stream: UInt32, after: TimeInterval)] = []
    var quitAfter: TimeInterval?
    var resetPairing = false
    var qrSheet = false
    var qrPayloadFile: String?
    var debugInputScript: String?
    var profileName = Profile.defaultName

    /// nil when `--profile` was missing or not a usable name.
    var profile: Profile? { Profile(name: profileName) }

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var index = 1
        func next() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--connect":
                if let value = next(), let colon = value.lastIndex(of: ":"),
                   let port = UInt16(value[value.index(after: colon)...]) {
                    options.connect = (String(value[..<colon]), port)
                }
            case "--pair-code-file":
                options.pairCodeFile = next()
            case "--open":
                if let value = next() {
                    options.openPackages += value.split(separator: ",").map(String.init)
                }
            case "--open-phone":
                options.openPhone = true
            case "--resize-stream":
                if let value = next() { options.resizes.append(Self.parseResize(value, defaultDelay: 2)) }
            case "--minimize-stream":
                if let value = next() { options.minimizes.append(Self.parseTimedStream(value)) }
            case "--deminimize-stream":
                if let value = next() { options.deminimizes.append(Self.parseTimedStream(value)) }
            case "--quit-after":
                if let value = next(), let seconds = Double(value) { options.quitAfter = seconds }
            case "--reset-pairing":
                options.resetPairing = true
            case "--qr-sheet":
                options.qrSheet = true
            case "--qr-payload-file":
                options.qrPayloadFile = next()
            case "--debug-input-script":
                options.debugInputScript = next()
            case "--profile":
                options.profileName = next() ?? ""
            default:
                break
            }
            index += 1
        }
        return options
    }

    /// `N:WxH-pt` — the `-pt` suffix is optional.
    private static func parseResize(_ value: String, defaultDelay: TimeInterval) -> (UInt32, NSSize, TimeInterval) {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        let stream = UInt32(parts.first ?? "") ?? 0
        var rest = parts.count > 1 ? parts[1] : ""
        if rest.hasSuffix("-pt") { rest = String(rest.dropLast(3)) }
        let dims = rest.lowercased().split(separator: "x").map(String.init)
        let width = Double(dims.first ?? "") ?? 0
        let height = dims.count > 1 ? (Double(dims[1]) ?? 0) : 0
        return (stream, NSSize(width: width, height: height), defaultDelay)
    }

    /// `N:SECONDS`.
    private static func parseTimedStream(_ value: String) -> (UInt32, TimeInterval) {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        return (UInt32(parts.first ?? "") ?? 0, parts.count > 1 ? (Double(parts[1]) ?? 0) : 0)
    }
}

// MARK: - App model

enum UIState: Equatable {
    case discovering
    case connecting
    case awaitingCode
    case connected
    /// The session is backing off before its next attempt; one line, no retries shown.
    case reconnecting
    /// Stopped trying; the user presses Retry. The text is `errorText`.
    case failed
}

/// One row of the Devices list: a discovered phone, a paired phone we only
/// remember through its cached address, or both.
struct DeviceRow: Equatable {
    var deviceId: String
    var name: String
    var model: String
    var paired: Bool
    var status: String
}

final class AppModel {
    let options: LaunchOptions
    let profile: Profile
    /// Our id toward the phone, from this profile's defaults.
    let clientId: String
    let keyStore: PairKeyStore
    let cache: CachedDeviceStore
    let discovery = Discovery()
    let spotlight: SpotlightIndex

    private(set) var session: Session?
    private(set) var windows: WindowManager?
    private(set) var phones: [DiscoveredPhone] = []
    private(set) var apps: [AppInfo] = []
    private(set) var icons: [String: NSImage] = [:]
    private(set) var uiState: UIState = .discovering
    private(set) var errorText: String?
    private(set) var phone: PhoneInfo?
    private(set) var locked = false
    private(set) var battery: Int?
    private(set) var charging = false

    /// Non-nil while the QR sheet is open (docs/UX.md "Pairing model").
    private(set) var qrPayload: PairingQRPayload?

    var onChange: (() -> Void)?
    var onPairCodeSheet: (() -> Void)?
    /// Sheet shown/hidden, or its status line changed.
    var onQRSheetChange: (() -> Void)?

    private enum SessionSource {
        /// Connected through the mDNS service endpoint.
        case discovery
        /// Connected straight to a remembered address.
        case cached
        /// `--connect` or a user action with no discovery involved.
        case manual
    }

    private var didAutoOpen = false
    private var lastConnection: (endpoint: Session.Endpoint, deviceId: String?, source: SessionSource)?
    private var sessionSource: SessionSource = .manual
    /// Device id of the current session; set at `begin` and confirmed on welcome.
    private var activeDeviceId: String?
    /// Device ids whose cached address proved to be another phone ("Offline").
    private(set) var offlineDeviceIds: Set<String> = []
    private var launchAt = Date()
    private var directWait: DispatchWorkItem?
    private var directFallback: DispatchWorkItem?
    private var directAttempts = 0
    private var pendingOpen: SpotlightOpenRequest?
    private var qrProbes: [QRProbe] = []
    private var qrTimer: Timer?
    private var debugInput: DebugInputDriver?

    private struct QRProbe {
        let session: Session
        /// Device id, or "host:port" for the `--connect` endpoint.
        let id: String
        let startedAt: Date
    }

    init(options: LaunchOptions, profile: Profile) {
        self.options = options
        self.profile = profile
        clientId = ClientIdentity.clientId(in: profile)
        keyStore = PairKeyStore(profile: profile)
        cache = CachedDeviceStore(profile: profile)
        spotlight = SpotlightIndex(domainPrefix: profile.spotlightDomainPrefix)
    }

    // MARK: Lifecycle

    func start() {
        discovery.onChange = { [weak self] phones in
            self?.phones = phones
            self?.autoConnectIfPaired()
            self?.onChange?()
        }
        launchAt = Date()
        if let path = options.debugInputScript {
            do {
                debugInput = try DebugInputDriver(scriptPath: path)
                debugInput?.arm()
            } catch {
                FileHandle.standardError.write(Data("debug-input-script \(path): \(error)\n".utf8))
                exit(2)
            }
        }
        // Before any connection: a QR sheet must own the first handshake, so
        // the phone never sees a `pair.request` for a Mac that is showing a QR.
        if options.qrSheet { startQRPairing() }
        if let connect = options.connect {
            begin(endpoint: .hostPort(host: connect.host, port: connect.port), deviceId: nil, source: .manual)
        } else {
            discovery.start()
            uiState = .discovering
            scheduleDirectWait()
        }
        if let quitAfter = options.quitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + quitAfter) { [weak self] in
                self?.shutdownAndExit()
            }
        }
    }

    /// Test hook: a modal sheet can defer -[NSApplication terminate:], so exit
    /// explicitly to make sure `--quit-after` never leaves an orphan process.
    private func shutdownAndExit() {
        windows?.beginShutdown()
        session?.close()
        exit(0)
    }

    func connect(phone: DiscoveredPhone) {
        begin(endpoint: .service(phone.endpoint), deviceId: phone.deviceId, source: .discovery)
    }

    /// A row from the Devices list (discovered phone or a remember-only one).
    func connect(row: DeviceRow) {
        if let phone = phones.first(where: { $0.deviceId == row.deviceId }) {
            connect(phone: phone)
            return
        }
        guard let address = cache.address(forDeviceId: row.deviceId) else { return }
        offlineDeviceIds.remove(row.deviceId)
        begin(endpoint: .hostPort(host: address.host, port: address.port),
              deviceId: row.deviceId, source: .cached)
    }

    /// Forget a phone completely: key, remembered address, Spotlight results.
    func forget(deviceId: String) {
        keyStore.forget(deviceId: deviceId)
        cache.forget(deviceId: deviceId)
        offlineDeviceIds.remove(deviceId)
        spotlight.remove(deviceId: deviceId)
        if activeDeviceId == deviceId {
            windows?.closeAll()
            session?.close()
            session = nil
            windows = nil
            activeDeviceId = nil
            uiState = .discovering
        }
        onChange?()
    }

    /// docs/UX.md: "Pairings are remembered; reconnection is automatic and
    /// silent." Whenever a paired phone shows up and we are not already on it,
    /// connect through its service endpoint. Discovery always beats the cache.
    private func autoConnectIfPaired() {
        guard options.connect == nil, qrPayload == nil else { return }
        guard let phone = phones.first(where: { keyStore.key(forDeviceId: $0.deviceId) != nil }) else { return }
        if sessionWantsDevice(phone.deviceId) { return }
        // Never hijack a working session to another phone.
        if let session, session.state == .ready, activeDeviceId != phone.deviceId { return }
        directWait?.cancel()
        directWait = nil
        begin(endpoint: .service(phone.endpoint), deviceId: phone.deviceId, source: .discovery)
    }

    /// True while the current session is connecting to (or ready with) `deviceId`.
    private func sessionWantsDevice(_ deviceId: String) -> Bool {
        guard let session, activeDeviceId == deviceId else { return false }
        switch session.state {
        case .idle, .closed: return false
        case .failed: return false
        case .connecting, .handshaking, .ready: return true
        }
    }

    func retry() {
        guard let last = lastConnection else { return }
        begin(endpoint: last.endpoint, deviceId: last.deviceId, source: last.source)
    }

    // MARK: Cached addresses (a dozing phone that stopped answering mDNS)

    /// After the discovery grace, connect straight to the last known address of
    /// a paired phone (only when nothing was discovered).
    private func scheduleDirectWait() {
        directWait?.cancel()
        let elapsed = Date().timeIntervalSince(launchAt)
        let delay = max(0, DirectConnectPolicy().discoveryGrace - elapsed)
        let work = DispatchWorkItem { [weak self] in self?.directConnectIfNeeded() }
        directWait = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func directConnectIfNeeded() {
        guard options.connect == nil, qrPayload == nil else { return }
        let decision = policy.decide(discoveredPaired: pairedDiscoveredIds,
                                     cached: cachedEntries,
                                     activeDeviceId: activeDeviceId,
                                     activeReady: session?.state == .ready,
                                     elapsedSinceLaunch: Date().timeIntervalSince(launchAt))
        apply(decision)
    }

    /// A discovery session failed: its phone may still be listening on the
    /// cached address even though mDNS is gone. Same backoff as a reconnect.
    private func scheduleCachedFallback() {
        guard options.connect == nil, qrPayload == nil, sessionSource == .discovery else { return }
        let decision = policy.failureDecision(deviceId: activeDeviceId,
                                              cached: cachedEntries,
                                              discoveredPaired: pairedDiscoveredIds)
        guard case .useCached(let device) = decision else { return }
        let delay = Session.backoff[min(directAttempts, Session.backoff.count - 1)]
        directAttempts += 1
        directFallback?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.sessionSource == .discovery else { return }
            guard let state = self.session?.state, case .failed = state else { return }
            Log.session.notice("falling back to the cached address for \(device.deviceId, privacy: .public)")
            self.begin(endpoint: .hostPort(host: device.address.host, port: device.address.port),
                       deviceId: device.deviceId, source: .cached)
        }
        directFallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func apply(_ decision: DirectConnectPolicy.Decision) {
        switch decision {
        case .useDiscovery(let deviceId):
            guard let phone = phones.first(where: { $0.deviceId == deviceId }) else { return }
            begin(endpoint: .service(phone.endpoint), deviceId: deviceId, source: .discovery)
        case .useCached(let device):
            offlineDeviceIds.remove(device.deviceId)
            begin(endpoint: .hostPort(host: device.address.host, port: device.address.port),
                  deviceId: device.deviceId, source: .cached)
        case .none:
            break
        }
    }

    private var policy: DirectConnectPolicy { DirectConnectPolicy() }

    private var pairedDiscoveredIds: [String] {
        phones.filter { keyStore.key(forDeviceId: $0.deviceId) != nil }.map(\.deviceId)
    }

    /// Remembered devices, most recently paired first.
    private var cachedEntries: [CachedDevice] {
        var ids = cache.deviceIds
        if let last = keyStore.lastDeviceId, let index = ids.firstIndex(of: last) {
            ids.remove(at: index)
            ids.insert(last, at: 0)
        }
        return ids.compactMap { id in cache.address(forDeviceId: id).map { CachedDevice(deviceId: id, address: $0) } }
    }

    // MARK: Devices list

    /// Discovered phones plus paired phones we only know from their cached
    /// address. A paired phone stays "Paired" (not "Offline") while the direct
    /// connection works; "Offline" only after its address proved to be another
    /// phone.
    var deviceRows: [DeviceRow] {
        let discoveredIds = Set(phones.map(\.deviceId))
        var rows = phones.map { phone -> DeviceRow in
            let paired = keyStore.key(forDeviceId: phone.deviceId) != nil
            return DeviceRow(deviceId: phone.deviceId, name: phone.name, model: phone.model,
                             paired: paired, status: paired ? "Paired" : "Nearby")
        }
        for id in cache.deviceIds where !discoveredIds.contains(id) {
            let paired = keyStore.key(forDeviceId: id) != nil
            let status: String
            if offlineDeviceIds.contains(id) {
                status = "Offline"
            } else if !paired {
                status = "Pair again" // the phone no longer accepts our key
            } else if activeDeviceId == id, uiState == .connecting {
                status = "Connecting…"
            } else {
                status = "Paired"
            }
            let name = cache.name(forDeviceId: id) ?? phone.flatMap { $0.id == id ? $0.name : nil } ?? id
            rows.append(DeviceRow(deviceId: id, name: name, model: "",
                                  paired: paired, status: status))
        }
        return rows
    }

    // MARK: Spotlight

    /// Open an app from a Spotlight result, connecting to its phone first when
    /// that phone is not the one we are already on.
    func openFromSpotlight(_ request: SpotlightOpenRequest) {
        if uiState == .connected, phone?.id == request.deviceId {
            windows?.openApp(pkg: request.pkg)
            return
        }
        pendingOpen = request
        if uiState == .connecting || uiState == .awaitingCode { return } // opened on welcome
        if let discovered = phones.first(where: { $0.deviceId == request.deviceId }) {
            connect(phone: discovered)
            return
        }
        if let address = cache.address(forDeviceId: request.deviceId) {
            offlineDeviceIds.remove(request.deviceId)
            begin(endpoint: .hostPort(host: address.host, port: address.port),
                  deviceId: request.deviceId, source: .cached)
            return
        }
        pendingOpen = nil
        errorText = "That phone is not available."
        onChange?()
    }

    private func openPendingAppIfPossible() {
        guard let request = pendingOpen, let info = phone, info.id == request.deviceId else { return }
        pendingOpen = nil
        windows?.openApp(pkg: request.pkg)
    }

    func submitPairCode(_ code: String) {
        session?.providePairCode(code)
    }

    // MARK: QR pairing

    /// Show a fresh key as a QR and start trying it against every phone we can
    /// see (every 2 s, for 5 minutes).
    func startQRPairing() {
        guard qrPayload == nil else { return }
        guard let payload = PairingQRPayload.random(clientId: clientId, name: ClientIdentity.name) else {
            errorText = "Could not generate a pairing key"
            onChange?()
            return
        }
        qrPayload = payload
        session?.usePairingKey(payload.key)
        if let path = options.qrPayloadFile {
            try? payload.uri.write(toFile: path, atomically: true, encoding: .utf8)
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.qrRound() }
        RunLoop.main.add(timer, forMode: .common)
        qrTimer = timer
        qrRound()
        onQRSheetChange?()
        onChange?()
    }

    func cancelQRPairing() {
        stopQRPairing()
        onChange?()
    }

    private func stopQRPairing() {
        qrTimer?.invalidate()
        qrTimer = nil
        for probe in qrProbes { probe.session.close() }
        qrProbes.removeAll()
        qrPayload = nil
        session?.clearPairingKey()
        onQRSheetChange?()
    }

    /// One round: probe every discovered phone (plus the `--connect` endpoint,
    /// which has no discovery) that has no live probe.
    private func qrRound() {
        guard let payload = qrPayload else { return }
        if payload.isExpired() {
            stopQRPairing()
            errorText = "The QR code expired. Press “Pair with QR” for a new one."
            onChange?()
            return
        }
        let now = Date()
        for probe in qrProbes where now.timeIntervalSince(probe.startedAt) > 6 {
            probe.session.close()
        }

        var candidates: [(id: String, endpoint: Session.Endpoint, deviceId: String?)] = phones.map {
            ($0.deviceId, .service($0.endpoint), $0.deviceId)
        }
        if let connect = options.connect {
            candidates.append(("\(connect.host):\(connect.port)",
                               .hostPort(host: connect.host, port: connect.port), nil))
        }
        for candidate in candidates where !qrProbes.contains(where: { $0.id == candidate.id }) {
            startProbe(id: candidate.id, endpoint: candidate.endpoint,
                       deviceId: candidate.deviceId, key: payload.key)
        }
    }

    private func startProbe(id: String, endpoint: Session.Endpoint, deviceId: String?, key: Data) {
        let probe = Session(endpoint: endpoint, knownDeviceId: deviceId, clientId: clientId, keyStore: keyStore)
        probe.autoReconnect = false
        probe.usePairingKey(key)
        probe.onEvent = { [weak self, weak probe] event in
            guard let probe else { return }
            self?.handleProbe(event, id: id, probe: probe)
        }
        qrProbes.append(QRProbe(session: probe, id: id, startedAt: Date()))
        probe.start()
    }

    private func handleProbe(_ event: SessionEvent, id: String, probe: Session) {
        switch event {
        case .qrPaired(let deviceId):
            finishQRPairing(deviceId: deviceId)
        case .state(.failed, _), .state(.closed, _):
            qrProbes.removeAll { $0.session === probe }
        default:
            break
        }
    }

    /// The phone scanned the QR and accepted the key (already stored).
    private func finishQRPairing(deviceId: String) {
        stopQRPairing()
        onChange?()
        // The probe's socket has to be gone first: the phone serves one session.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            if let phone = self.phones.first(where: { $0.deviceId == deviceId }) {
                self.connect(phone: phone)
            } else if let connect = self.options.connect {
                self.begin(endpoint: .hostPort(host: connect.host, port: connect.port),
                           deviceId: deviceId, source: .manual)
            }
        }
    }

    private func begin(endpoint: Session.Endpoint, deviceId: String?, source: SessionSource) {
        lastConnection = (endpoint, deviceId, source)
        sessionSource = source
        activeDeviceId = deviceId
        session?.close()
        let strictId = source == .cached ? deviceId : nil
        let newSession = Session(endpoint: endpoint, knownDeviceId: deviceId, strictDeviceId: strictId,
                                 clientId: clientId, keyStore: keyStore)
        let manager = WindowManager(session: newSession)
        session = newSession
        windows = manager
        didAutoOpen = false
        errorText = nil
        uiState = .connecting
        if let key = qrPayload?.key { newSession.usePairingKey(key) }
        // Events of a session that has been replaced (its close, a late failure)
        // must not change the state of the one in charge now.
        newSession.onEvent = { [weak self, weak newSession] event in
            guard let self, let newSession, newSession === self.session else { return }
            self.handle(event)
        }
        newSession.onVideoEvent = { [weak self] event in self?.windows?.handleVideo(event) }
        onChange?()
        newSession.start()
    }

    // MARK: Events

    private func handle(_ event: SessionEvent) {
        switch event {
        case .state(let state, let detail):
            switch state {
            case .ready:
                uiState = .connected
                errorText = nil
            case .connecting, .handshaking:
                // A retry in the background keeps the one "Reconnecting…" line.
                if uiState != .awaitingCode && uiState != .reconnecting { uiState = .connecting }
            case .failed:
                let reason = detail ?? "closed"
                errorText = ConnectionFailure.message(for: reason)
                uiState = ConnectionFailure.retriesAutomatically(reason) ? .reconnecting : .failed
                scheduleCachedFallback()
            case .closed, .idle:
                uiState = .discovering
            }
        case .ready(let info, _, let address):
            phone = info
            windows?.phone = info
            locked = info.locked
            battery = info.battery
            charging = info.charging ?? false
            activeDeviceId = info.id
            directAttempts = 0
            offlineDeviceIds.remove(info.id)
            if let address {
                cache.store(address, deviceId: info.id)
                cache.store(name: info.name, deviceId: info.id)
            }
            uiState = .connected
            errorText = nil
            session?.requestApps()
            if !didAutoOpen {
                didAutoOpen = true
                applyAutoOpen()
            }
            openPendingAppIfPossible()
        case .apps(let list):
            apps = list
            windows?.appsByPkg = Dictionary(list.map { ($0.pkg, $0) }, uniquingKeysWith: { first, _ in first })
            windows?.applyLabels()
            for app in list where icons[app.pkg] == nil {
                if let cached = IconCache.shared.load(pkg: app.pkg) {
                    icons[app.pkg] = cached
                    windows?.setIcon(cached, pkg: app.pkg)
                } else {
                    session?.requestIcon(pkg: app.pkg)
                }
            }
            if let info = phone {
                spotlight.index(apps: list, deviceId: info.id, phoneName: info.name,
                                iconData: { IconCache.shared.loadData(pkg: $0) })
            }
        case .icon(let pkg, let png):
            if let image = NSImage(data: png) {
                icons[pkg] = image
                windows?.setIcon(image, pkg: pkg)
                IconCache.shared.store(png, pkg: pkg)
            }
        case .phoneState(let locked, let battery, let charging):
            self.locked = locked
            self.battery = battery
            self.charging = charging
        case .pairCodeRequired:
            uiState = .awaitingCode
            if options.pairCodeFile != nil {
                readPairCodeFromFile(attempt: 0)
            } else {
                onPairCodeSheet?()
            }
        case .qrPaired(let deviceId):
            finishQRPairing(deviceId: deviceId)
        case .identityMismatch(let expected, let actual):
            // The address no longer belongs to the paired phone: drop it and
            // never connect there again (the session refused already).
            Log.session.notice("dropping cached address for \(expected, privacy: .public) (answers as \(actual, privacy: .public))")
            cache.forget(deviceId: expected)
            offlineDeviceIds.insert(expected)
            errorText = ConnectionFailure.message(for: ConnectionFailure.identityMismatch)
            uiState = .discovering
        case .phoneError(let code, let message, _):
            errorText = ConnectionFailure.message(for: code) ?? message ?? code
            if code == "auth_failed" { uiState = .discovering }
        default:
            break
        }
        windows?.handle(event)
        onChange?()
    }

    // MARK: Test hooks

    private func applyAutoOpen() {
        for pkg in options.openPackages { windows?.openApp(pkg: pkg) }
        if options.openPhone { windows?.openPhoneWindow() }
        for resize in options.resizes {
            DispatchQueue.main.asyncAfter(deadline: .now() + resize.after) { [weak self] in
                self?.windows?.resize(stream: resize.stream, to: resize.size)
            }
        }
        for minimize in options.minimizes {
            DispatchQueue.main.asyncAfter(deadline: .now() + minimize.after) { [weak self] in
                self?.windows?.controller(for: minimize.stream)?.window?.miniaturize(nil)
            }
        }
        for deminimize in options.deminimizes {
            DispatchQueue.main.asyncAfter(deadline: .now() + deminimize.after) { [weak self] in
                self?.windows?.controller(for: deminimize.stream)?.window?.deminiaturize(nil)
            }
        }
    }

    static func readCode(_ path: String) -> String? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? nil : code
    }

    /// The code file is written by the fake phone just before it announces the
    /// code, so retry briefly instead of falling back to the sheet on a miss.
    private func readPairCodeFromFile(attempt: Int) {
        guard let path = options.pairCodeFile else { return }
        if let code = Self.readCode(path) {
            session?.providePairCode(code)
            return
        }
        guard attempt < 20 else {
            onPairCodeSheet?()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.readPairCodeFromFile(attempt: attempt + 1)
        }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var launcher: LauncherWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = LaunchOptions.parse(CommandLine.arguments)
        // A profile name that does not parse must not fall back to the default
        // profile: a test run would then use the user's data.
        guard let profile = options.profile else {
            FileHandle.standardError.write(Data("--profile \(options.profileName): use 1-32 of a-z, 0-9 and -\n".utf8))
            exit(2)
        }
        Profile.active = profile
        Log.app.notice("profile \(profile.name, privacy: .public): keychain \(profile.keychainService, privacy: .public), defaults \(profile.defaultsSuiteName ?? "standard", privacy: .public)")
        if options.resetPairing {
            profile.keychain.deleteAll()
            PairKeyStore(profile: profile).lastDeviceId = nil
            CachedDeviceStore(profile: profile).removeAll()
        }
        let model = AppModel(options: options, profile: profile)
        let launcher = LauncherWindowController(model: model)
        self.model = model
        self.launcher = launcher
        NSApp.mainMenu = Self.buildMenu(launcher: launcher)
        launcher.showWindow(nil)
        launcher.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.start()
    }

    /// Spotlight results for indexed phone apps arrive as an NSUserActivity.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard let model, let request = model.spotlight.continuationRequest(from: userActivity) else { return false }
        model.openFromSpotlight(request)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        model?.windows?.beginShutdown()
        model?.session?.close()
    }

    private static func buildMenu(launcher: LauncherWindowController) -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About PocketDeck",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide PocketDeck",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit PocketDeck",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        let find = NSMenuItem(title: "Find Apps", action: #selector(LauncherWindowController.focusSearch), keyEquivalent: "k")
        find.target = launcher
        viewMenu.addItem(find)
        let phone = NSMenuItem(title: "Phone Window", action: #selector(LauncherWindowController.openPhoneWindow), keyEquivalent: "p")
        phone.target = launcher
        viewMenu.addItem(phone)

        // Nav shortcuts are discoverable here; targets stay nil so the key
        // window's controller (responder chain) handles them.
        let navigateItem = NSMenuItem()
        main.addItem(navigateItem)
        let navigateMenu = NSMenu(title: "Navigate")
        navigateItem.submenu = navigateMenu
        navigateMenu.addItem(withTitle: "Back",
                             action: #selector(StreamWindowController.navigateBack(_:)), keyEquivalent: "[")
        let home = NSMenuItem(title: "Home", action: #selector(PhoneWindowController.navigateHome(_:)), keyEquivalent: "h")
        home.keyEquivalentModifierMask = [.command, .shift]
        navigateMenu.addItem(home)
        let recents = NSMenuItem(title: "Recents", action: #selector(PhoneWindowController.navigateRecents(_:)),
                                 keyEquivalent: "\u{F700}") // NSUpArrowFunctionKey
        recents.keyEquivalentModifierMask = [.command]
        navigateMenu.addItem(recents)

        return main
    }
}

@main
struct PocketDeckMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
