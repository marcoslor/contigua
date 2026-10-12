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

    var onChange: (() -> Void)?
    var onPairCodeSheet: (() -> Void)?

    private var didAutoOpen = false
    private var lastConnection: (endpoint: Session.Endpoint, deviceId: String?)?

    init(options: LaunchOptions) { self.options = options }

    // MARK: Lifecycle

    func start() {
        discovery.onChange = { [weak self] phones in
            self?.phones = phones
            self?.onChange?()
        }
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

    func retry() {
        guard let last = lastConnection else { return }
        begin(endpoint: last.endpoint, deviceId: last.deviceId)
    }

    func submitPairCode(_ code: String) {
        session?.providePairCode(code)
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
