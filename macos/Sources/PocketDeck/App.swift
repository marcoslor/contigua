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
    case failed(String)
}

final class AppModel {
    let options: LaunchOptions
    let keyStore = PairKeyStore()
    let discovery = Discovery()

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

    private var didAutoOpen = false
    private var didAutoConnect = false
    private var lastConnection: (endpoint: Session.Endpoint, deviceId: String?)?
    private var qrProbes: [QRProbe] = []
    private var qrTimer: Timer?

    private struct QRProbe {
        let session: Session
        /// Device id, or "host:port" for the `--connect` endpoint.
        let id: String
        let startedAt: Date
    }

    init(options: LaunchOptions) { self.options = options }

    // MARK: Lifecycle

    func start() {
        discovery.onChange = { [weak self] phones in
            self?.phones = phones
            self?.autoConnectIfPaired()
            self?.onChange?()
        }
        // Before any connection: a QR sheet must own the first handshake, so
        // the phone never sees a `pair.request` for a Mac that is showing a QR.
        if options.qrSheet { startQRPairing() }
        if let connect = options.connect {
            begin(endpoint: .hostPort(host: connect.host, port: connect.port), deviceId: nil)
        } else {
            discovery.start()
            uiState = .discovering
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
        begin(endpoint: .service(phone.endpoint), deviceId: phone.deviceId)
    }

    /// docs/UX.md: "Pairings are remembered; reconnection is automatic and
    /// silent." One silent connect per launch, to the first remembered phone.
    private func autoConnectIfPaired() {
        guard session == nil, !didAutoConnect, qrPayload == nil, options.connect == nil else { return }
        guard let phone = phones.first(where: { keyStore.key(forDeviceId: $0.deviceId) != nil }) else { return }
        didAutoConnect = true
        connect(phone: phone)
    }

    func retry() {
        guard let last = lastConnection else { return }
        begin(endpoint: last.endpoint, deviceId: last.deviceId)
    }

    func submitPairCode(_ code: String) {
        session?.providePairCode(code)
    }

    // MARK: QR pairing

    /// Show a fresh key as a QR and start trying it against every phone we can
    /// see (every 2 s, for 5 minutes).
    func startQRPairing() {
        guard qrPayload == nil else { return }
        guard let payload = PairingQRPayload.random(clientId: ClientIdentity.clientId,
                                                    name: ClientIdentity.name) else {
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
        let probe = Session(endpoint: endpoint, knownDeviceId: deviceId, keyStore: keyStore)
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
                self.begin(endpoint: .hostPort(host: connect.host, port: connect.port), deviceId: deviceId)
            }
        }
    }

    private func begin(endpoint: Session.Endpoint, deviceId: String?) {
        lastConnection = (endpoint, deviceId)
        session?.close()
        let newSession = Session(endpoint: endpoint, knownDeviceId: deviceId, keyStore: keyStore)
        let manager = WindowManager(session: newSession)
        session = newSession
        windows = manager
        didAutoOpen = false
        errorText = nil
        uiState = .connecting
        if let key = qrPayload?.key { newSession.usePairingKey(key) }
        newSession.onEvent = { [weak self] event in self?.handle(event) }
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
            case .connecting, .handshaking:
                if uiState != .awaitingCode { uiState = .connecting }
            case .failed:
                uiState = .failed(detail ?? "connection failed")
                errorText = detail
            case .closed, .idle:
                uiState = .discovering
            }
        case .ready(let info, _):
            phone = info
            windows?.phone = info
            locked = info.locked
            battery = info.battery
            charging = info.charging ?? false
            uiState = .connected
            session?.requestApps()
            if !didAutoOpen {
                didAutoOpen = true
                applyAutoOpen()
            }
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
        case .phoneError(let code, let message, _):
            errorText = message ?? code
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
        if options.resetPairing {
            Keychain.deleteAll()
            UserDefaults.standard.removeObject(forKey: "lastDeviceId")
        }
        let model = AppModel(options: options)
        let launcher = LauncherWindowController(model: model)
        self.model = model
        self.launcher = launcher
        NSApp.mainMenu = Self.buildMenu(launcher: launcher)
        launcher.showWindow(nil)
        launcher.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.start()
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
