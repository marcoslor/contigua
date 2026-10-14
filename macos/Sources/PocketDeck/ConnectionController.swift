// Owns everything between the phone and the UI: discovery, the one live
// session, retries, pairing and the app list. The UI reads `link`, `banner`
// and the lists, and calls the few intent methods; it never sees sessions.
//
// Rules (docs/design/mac-redesign.md §4):
// - One owner of the live connection; every attempt that ends is cancelled.
// - Automatic attempts never send `pair.request`; only a user-driven pairing may.
// - A remembered phone is reconnected silently; the UI shows a chip, not a screen.

import AppKit
import UniformTypeIdentifiers
import Observation

/// What an attempt connects to. Pure so the choice is unit-tested.
enum EndpointChoice: Equatable {
    case service
    case cached(CachedAddress)
    case wait(TimeInterval)
    case none
}

struct EndpointPlanner {
    /// How long mDNS gets at launch before the remembered address is tried.
    static let cachedGrace: TimeInterval = 1.5

    func choose(discovered: Bool, cached: CachedAddress?, lastAttemptWasService: Bool,
                lastAttemptFailed: Bool, sinceLaunch: TimeInterval) -> EndpointChoice {
        if discovered {
            // A service attempt that failed (a bridge interface that goes nowhere)
            // is followed by the remembered IPv4 address, if there is one.
            if lastAttemptFailed, lastAttemptWasService, let cached { return .cached(cached) }
            return .service
        }
        guard let cached else { return .none }
        if sinceLaunch < Self.cachedGrace { return .wait(Self.cachedGrace - sinceLaunch) }
        return .cached(cached)
    }
}

struct NearbyPhone: Equatable, Identifiable {
    var ref: PhoneRef
    var id: String { ref.id }
    /// Remembered by this Mac (a key may or may not still exist).
    var remembered: Bool
    /// Remembered, but the key is gone or was rejected: offer "Pair again".
    var needsPairing: Bool
}

struct PhoneStatus: Equatable {
    var locked: Bool
    var battery: Int?
    var charging: Bool
}

struct QRPairingState: Equatable {
    var payload: PairingQRPayload
    var succeeded = false
    var expired = false
}

/// Which phones a QR sheet probes right now: only phones that are not already
/// paired with this Mac (a paired phone is reconnected with its own key), not
/// already being probed, not probed in the last 4 s and not known to be busy.
enum QRProbePlanner {
    static let probeInterval: TimeInterval = 4
    static let busyBackoff: TimeInterval = 15

    static func candidates(phones: [DiscoveredPhone], paired: Set<String>, active: Set<String>,
                           lastProbe: [String: Date], busyUntil: [String: Date],
                           now: Date) -> [DiscoveredPhone] {
        phones.filter { phone in
            if paired.contains(phone.deviceId) || active.contains(phone.deviceId) { return false }
            if let until = busyUntil[phone.deviceId], until > now { return false }
            if let last = lastProbe[phone.deviceId], now.timeIntervalSince(last) < probeInterval { return false }
            return true
        }
    }
}

enum DeckMode: Equatable { case welcome, nearby, phone }

enum DeckSheet: Equatable { case code, qr, manual, addPhone }

@MainActor
@Observable
final class ConnectionController {
    let options: LaunchOptions
    let profile: Profile
    let clientId: String
    let keyStore: PairKeyStore
    let cache: CachedDeviceStore
    let remembered: RememberedPhones
    let appsCache: AppsCache
    let spotlight: SpotlightIndex
    let windows: WindowManager
    private let discovery = Discovery()

    // MARK: Published state

    private(set) var machine = LinkMachine()
    var link: Link { machine.link }
    private(set) var transientBanner: Banner?
    /// APK installs (docs/design/apk.md); the Deck shows its phase.
    let apkInstaller = ApkInstaller()
    var banner: Banner? { transientBanner ?? link.banner }

    private(set) var discovered: [DiscoveredPhone] = []
    private(set) var rememberedPhones: [RememberedPhone] = []
    private(set) var apps: [AppInfo] = []
    private(set) var appsLoaded = false
    private(set) var icons: [String: NSImage] = [:]
    /// Packages the phone answered with no icon at all.
    private(set) var missingIcons: Set<String> = []
    private(set) var status: PhoneStatus?
    private(set) var pairingSucceeded = false
    private(set) var qr: QRPairingState?
    private(set) var welcomeSeen: Bool
    private(set) var searchedLong = false
    private(set) var browseDenied = false

    var sheet: DeckSheet?
    /// A sheet requested before the Deck window exists (launch hooks, previews).
    private(set) var pendingSheet: DeckSheet?

    func presentPendingSheet() {
        guard let pending = pendingSheet else { return }
        pendingSheet = nil
        sheet = pending
    }
    /// Window and menu actions reach the Deck through this (focus the search field).
    var searchFocusRequest = 0

    var deckMode: DeckMode {
        if !rememberedPhones.isEmpty { return .phone }
        return welcomeSeen ? .nearby : .welcome
    }

    /// The phone the Deck shows.
    var activePhone: PhoneRef? { link.phone ?? remembered.active?.ref }

    var nearby: [NearbyPhone] {
        discovered.map { phone in
            let known = rememberedPhones.contains { $0.id == phone.deviceId }
            return NearbyPhone(ref: phone.ref, remembered: known,
                               needsPairing: known && keyStore.key(forDeviceId: phone.deviceId) == nil)
        }
    }

    // MARK: Private state

    private var session: Session?
    private var clipboardSync: ClipboardSync?
    private var attemptTimer: DispatchWorkItem?
    private var tickTimer: Timer?
    private var launchAt = Date()
    private var lastAttemptWasService = false
    private var lastAttemptFailed = false
    private var pinInterface = true
    private var didAutoOpen = false
    private var everOnline = false
    private var pendingOpen: SpotlightOpenRequest?
    /// A link waiting for its phone to become ready (nil phone = whichever comes first).
    private var pendingLink: (request: OpenLinkRequest, until: Date)?
    /// An app file waiting for its phone to become ready (nil phone = whichever comes first).
    private var pendingApk: (file: URL, deviceId: String?, until: Date)?
    private var debugInput: DebugInputDriver?
    private var pairingTarget: PairingTarget?
    private var qrTimer: Timer?
    private var qrProbes: [QRProbe] = []
    private var qrLastProbe: [String: Date] = [:]
    private var qrBusyUntil: [String: Date] = [:]
    private var transientTimer: DispatchWorkItem?
    private var searchTimer: DispatchWorkItem?
    private(set) var isPreview = false
    /// Per-attempt limits for user-driven sessions; tests shorten them.
    var connectTimeout = Session.defaultConnectTimeout
    var pairingTimeout = Session.defaultPairingTimeout

    private enum PairingTarget {
        case discovered(DiscoveredPhone)
        case manual(host: String, port: UInt16)
    }

    private struct QRProbe {
        let session: Session
        let id: String
        let startedAt: Date
    }

    init(options: LaunchOptions, profile: Profile) {
        self.options = options
        self.profile = profile
        clientId = ClientIdentity.clientId(in: profile)
        keyStore = PairKeyStore(profile: profile)
        cache = CachedDeviceStore(profile: profile)
        remembered = RememberedPhones(profile: profile)
        appsCache = AppsCache(profile: profile)
        spotlight = SpotlightIndex(domainPrefix: profile.spotlightDomainPrefix)
        windows = WindowManager(session: Session(endpoint: .hostPort(host: "127.0.0.1", port: 1),
                                                 knownDeviceId: nil, clientId: "", keyStore: keyStore),
                                defaults: profile.defaults)
        welcomeSeen = remembered.welcomeSeen
        remembered.adoptExistingPairings(keyAccounts: PairKeyStore(profile: profile).accounts()) { [cache] in cache.name(forDeviceId: $0) }
        rememberedPhones = remembered.all
    }

    // MARK: Lifecycle

    func start() {
        launchAt = Date()
        if let directory = options.dumpVideoDirectory { windows.videoDump = VideoDump(directory: directory) }
        windows.floatWindows = options.floatWindows
        if let path = options.debugInputScript {
            do {
                debugInput = try DebugInputDriver(scriptPath: path)
                debugInput?.arm()
            } catch {
                FileHandle.standardError.write(Data("debug-input-script \(path): \(error)\n".utf8))
                exit(2)
            }
        }
        if let preview = options.preview {
            applyPreview(preview)
            return
        }
        discovery.onChange = { [weak self] phones in self?.discoveryChanged(phones) }
        discovery.onDenied = { [weak self] denied in self?.discoveryDenied(denied) }
        discovery.start()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
        observeSystem()

        if options.qrSheet { startQRPairing(presentAfterLaunch: true) }
        if let connect = options.connect {
            beginManualLaunch(host: connect.host, port: connect.port)
        } else {
            if let active = remembered.active { resetPhoneData(for: active.ref) }
            send(.launch(remembered.active?.ref))
        }
        if let quitAfter = options.quitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + quitAfter) { [weak self] in
                MainActor.assumeIsolated { self?.shutdownAndExit() }
            }
        }
    }

    /// Test hook: a modal sheet can defer -[NSApplication terminate:], so exit
    /// explicitly to make sure `--quit-after` never leaves an orphan process.
    private func shutdownAndExit() {
        shutdown()
        exit(0)
    }

    func shutdown() {
        windows.beginShutdown()
        stopQR()
        attemptTimer?.cancel()
        stopClipboardSync()
        session?.close()
        session = nil
    }

    private func tick() {
        send(.tick)
        if let qr, !qr.expired, !qr.succeeded, qr.payload.isExpired() { expireQR() }
    }

    private func observeSystem() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reachabilityHint() }
        }
    }

    // MARK: Intents (the UI calls these)

    func tryNow() {
        send(.tryNow)
    }

    func markWelcomeSeen() {
        welcomeSeen = true
        remembered.welcomeSeen = true
    }

    func requestSearchFocus() { searchFocusRequest += 1 }

    /// Pair a discovered phone (the code flow, docs/UX.md "Automatic").
    func pair(_ phone: NearbyPhone) {
        guard let found = discovered.first(where: { $0.deviceId == phone.id }) else { return }
        beginPairing(PairingTarget.discovered(found), ref: found.ref)
    }

    /// "Pair again" on the banner: the remembered phone, if it is in range.
    func pairAgain() {
        guard let ref = link.phone else { return }
        if let found = discovered.first(where: { $0.deviceId == ref.id }) {
            beginPairing(.discovered(found), ref: ref)
        } else {
            sheet = .addPhone
        }
    }

    func connectManually(host: String, port: UInt16) {
        sheet = nil
        beginPairing(.manual(host: host, port: port),
                     ref: PhoneRef(id: "", name: host, model: ""))
    }

    func retryPairing() {
        guard case .pairing(let ref, _) = link, let target = pairingTarget else { return }
        beginPairing(target, ref: ref)
    }

    func cancelPairing() {
        guard isPairing else { return }
        pairingTarget = nil
        pairingSucceeded = false
        if sheet == .code { sheet = nil }
        closeSession()
        send(.cancelPairing)
    }

    /// A sheet went away (Esc, Cancel, or programmatically): stop what it was running.
    func sheetDismissed() {
        cancelPairing()
        if let qr, !qr.succeeded { stopQR() }
    }

    /// Settings → Devices → Use.
    func use(_ phone: RememberedPhone) {
        guard link.phone?.id != phone.id else { return }
        remembered.setActive(id: phone.id)
        windows.closeAll()
        closeSession()
        resetPhoneData(for: phone.ref)
        send(.activate(phone.ref))
    }

    func forget(_ phone: RememberedPhone) {
        let wasActive = link.phone?.id == phone.id || remembered.active?.id == phone.id
        keyStore.forget(deviceId: phone.id)
        cache.forget(deviceId: phone.id)
        remembered.forget(id: phone.id)
        appsCache.remove(deviceId: phone.id)
        spotlight.remove(deviceId: phone.id)
        rememberedPhones = remembered.all
        if link.phone?.id == phone.id {
            windows.closeAll()
            closeSession()
            apps = []
            appsLoaded = false
            status = nil
        }
        send(.forget(deviceId: phone.id))
        if wasActive, let next = remembered.active {
            resetPhoneData(for: next.ref)
            send(.activate(next.ref))
        }
    }

    func openApp(_ app: AppInfo) {
        guard link.isOnline else { return }
        windows.openApp(pkg: app.pkg, activity: app.activity)
    }

    func openPhoneWindow() {
        guard link.isOnline else { return }
        windows.openPhoneWindow()
    }

    func openFromSpotlight(_ request: SpotlightOpenRequest) {
        if link.isOnline, link.phone?.id == request.deviceId {
            windows.openApp(pkg: request.pkg)
            return
        }
        guard let phone = remembered.phone(id: request.deviceId) else {
            showTransient("That phone isn't paired.")
            return
        }
        pendingOpen = request
        use(phone)
    }

    // MARK: Links (docs/design/links.md)

    /// Opens a link from the URL scheme, Services or a drop in a new window on a phone.
    func openLink(_ request: OpenLinkRequest) {
        let ids = rememberedPhones.map(\.id)
        let online = link.isOnline ? link.phone?.id : nil
        switch LinkRoute.route(requested: request.deviceId, remembered: ids, online: online) {
        case .open(let id):
            openLink(request.url, on: id)
        case .pick(let candidates):
            let phones = candidates.compactMap { remembered.phone(id: $0) }
            guard let id = PhonePicker.choose(phones, title: "Open on which phone?",
                                              detail: request.url) else { return }
            openLink(request.url, on: id)
        case .wait:
            pendingLink = (request, Date().addingTimeInterval(Self.pendingLinkLifetime))
            if !link.isOnline { showTransient("Pair a phone to open links on it.") }
        }
    }

    /// A link that waits for a phone is dropped after this long rather than
    /// popping up much later.
    private static let pendingLinkLifetime: TimeInterval = 120

    private func openLink(_ url: String, on deviceId: String) {
        Log.app.info("open link on \(deviceId, privacy: .public)")
        if link.isOnline, link.phone?.id == deviceId {
            windows.openLink(url)
            return
        }
        pendingLink = (OpenLinkRequest(url: url, deviceId: deviceId), Date().addingTimeInterval(Self.pendingLinkLifetime))
        if let phone = remembered.phone(id: deviceId), link.phone?.id != deviceId { use(phone) }
    }

    private func openPendingLink(readyPhone id: String) {
        guard let pending = pendingLink else { return }
        guard pending.until > Date() else { pendingLink = nil; return }
        guard pending.request.deviceId == nil || pending.request.deviceId == id else { return }
        pendingLink = nil
        windows.openLink(pending.request.url)
    }

    // MARK: APK install (docs/design/apk.md)

    /// Installs an .apk / .apks / .xapk on a phone (drop, Open With, Services, menu bar).
    func installApk(_ file: URL, deviceId requested: String? = nil) {
        guard ApkBundle.kind(of: file) != nil else {
            showTransient(ApkBundleError.notAnApp.message)
            return
        }
        let ids = rememberedPhones.map(\.id)
        let online = link.isOnline ? link.phone?.id : nil
        switch LinkRoute.route(requested: requested, remembered: ids, online: online) {
        case .open(let id):
            installApk(file, on: id)
        case .pick(let candidates):
            let phones = candidates.compactMap { remembered.phone(id: $0) }
            guard let id = PhonePicker.choose(phones, title: "Install on which phone?", detail: file.lastPathComponent,
                                              confirm: "Install") else { return }
            installApk(file, on: id)
        case .wait:
            pendingApk = (file, nil, Date().addingTimeInterval(Self.pendingLinkLifetime))
            if !link.isOnline { showTransient("Pair a phone to install apps on it.") }
        }
    }

    /// Lets the person pick an app file (menu bar "Install APK…").
    func chooseApk() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ApkBundle.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.message = "Choose an Android app (.apk, .apks or .xapk) to install on the phone."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        installApk(url)
    }

    private func installApk(_ file: URL, on deviceId: String) {
        Log.app.info("install app file on \(deviceId, privacy: .public)")
        if link.isOnline, link.phone?.id == deviceId, let session {
            apkInstaller.onInstalled = { [weak self] in self?.session?.requestApps() }
            apkInstaller.install(file, session: session)
            return
        }
        pendingApk = (file, deviceId, Date().addingTimeInterval(Self.pendingLinkLifetime))
        if let phone = remembered.phone(id: deviceId), link.phone?.id != deviceId { use(phone) }
    }

    private func installPendingApk(readyPhone id: String) {
        guard let pending = pendingApk else { return }
        guard pending.until > Date() else { pendingApk = nil; return }
        guard pending.deviceId == nil || pending.deviceId == id else { return }
        pendingApk = nil
        installApk(pending.file, on: id)
    }

    // MARK: Phone data

    private func resetPhoneData(for ref: PhoneRef) {
        apps = appsCache.load(deviceId: ref.id)
        appsLoaded = !apps.isEmpty
        status = nil
        icons = [:]
        missingIcons = []
        for app in apps {
            if let image = IconCache.shared.load(pkg: app.pkg, deviceId: ref.id) { icons[app.pkg] = image }
        }
    }

    // MARK: Discovery

    private func discoveryChanged(_ phones: [DiscoveredPhone]) {
        let before = Set(discovered.map(\.deviceId))
        discovered = phones
        searchedLong = false
        scheduleSearchedLong()
        if let ref = link.phone, !ref.id.isEmpty,
           phones.contains(where: { $0.deviceId == ref.id }), !before.contains(ref.id) {
            reachabilityHint()
        }
        if qr != nil { qrRound() }
    }

    private func discoveryDenied(_ denied: Bool) {
        browseDenied = denied
        if denied { send(.localNetworkDenied) }
        else { tryNowIfDenied() }
    }

    private func tryNowIfDenied() {
        if case .offline(let phone, .localNetworkDenied) = link { send(.activate(phone)) }
    }

    private func scheduleSearchedLong() {
        searchTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.discovered.isEmpty else { return }
                self.searchedLong = true
            }
        }
        searchTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    private func reachabilityHint() {
        send(.reachabilityHint)
    }

    // MARK: Link plumbing

    /// The only way the machine is driven: runs its actions, then reacts to the
    /// new link (sheet, window pills).
    private func send(_ event: LinkEvent) {
        let before = link
        let actions = machine.handle(event, at: Date())
        for action in actions {
            switch action {
            case .attempt(let delay): scheduleAttempt(after: delay)
            case .stopAttempts:
                attemptTimer?.cancel()
                attemptTimer = nil
            case .startPairing: break
            }
        }
        if case .pairing = link, qr == nil { sheet = .code }
        if before.isOnline, !link.isOnline { windows.linkLost() }
        if !before.isOnline, link.isOnline { windows.linkRestored() }
    }

    private func scheduleAttempt(after delay: TimeInterval) {
        attemptTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.runAttempt() }
        }
        attemptTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func closeSession() {
        attemptTimer?.cancel()
        attemptTimer = nil
        stopClipboardSync()
        session?.close()
        session = nil
    }

    private func runAttempt() {
        attemptTimer = nil
        guard let ref = link.phone, !isPairing else { return }
        // A preempted attempt that has not authenticated is cancelled, never leaked.
        if let session, session.state != .ready { session.close() }
        if session?.state == .ready { return }
        let found = discovered.first { $0.deviceId == ref.id }
        if found == nil, let connect = options.connect {
            lastAttemptWasService = false
            start(Session(endpoint: .hostPort(host: connect.host, port: connect.port),
                          knownDeviceId: ref.id.isEmpty ? nil : ref.id, clientId: clientId, keyStore: keyStore),
                  policy: .never)
            return
        }
        let cached = cache.address(forDeviceId: ref.id)
        let choice = EndpointPlanner().choose(discovered: found != nil, cached: cached,
                                              lastAttemptWasService: lastAttemptWasService,
                                              lastAttemptFailed: lastAttemptFailed,
                                              sinceLaunch: Date().timeIntervalSince(launchAt))
        let endpoint: Session.Endpoint
        var strict: String?
        switch choice {
        case .service:
            guard let found else { return }
            // After a failed service attempt, try the other interface policy.
            if lastAttemptFailed, lastAttemptWasService { pinInterface.toggle() }
            endpoint = .service(found.endpoint, pinnedTo: pinInterface ? found.interface : nil)
            lastAttemptWasService = true
        case .cached(let address):
            endpoint = .hostPort(host: address.host, port: address.port)
            strict = ref.id
            lastAttemptWasService = false
        case .wait(let seconds):
            scheduleAttempt(after: seconds)
            return
        case .none:
            noEndpoint()
            return
        }
        start(Session(endpoint: endpoint, knownDeviceId: ref.id, strictDeviceId: strict,
                      clientId: clientId, keyStore: keyStore), policy: .never)
    }

    /// Nothing to connect to (not discovered, no remembered address): count it as
    /// a failed attempt so the backoff and the 15 s offline rule still run.
    private func noEndpoint() {
        lastAttemptFailed = true
        send(.attemptFailed(reason: "timeout"))
    }

    private var isPairing: Bool {
        if case .pairing = link { return true }
        return false
    }

    private func start(_ newSession: Session, policy: Session.PairingPolicy) {
        stopClipboardSync()
        session?.close()
        session = newSession
        newSession.pairingPolicy = policy
        windows.attach(newSession)
        if let key = qr?.payload.key, policy == .allowed { newSession.usePairingKey(key) }
        newSession.onEvent = { [weak self, weak newSession] event in
            MainActor.assumeIsolated {
                guard let self, let newSession, newSession === self.session else { return }
                self.handle(event)
            }
        }
        newSession.onVideoEvent = { [weak self, weak newSession] event in
            guard let self, let newSession else { return }
            self.windows.handleVideo(event, from: newSession)
        }
        newSession.start()
    }

    // MARK: Pairing

    private func beginPairing(_ target: PairingTarget, ref: PhoneRef) {
        pairingTarget = target
        pairingSucceeded = false
        windows.closeAll()
        closeSession()
        sheet = .code
        send(.beginPairing(ref))
        let endpoint: Session.Endpoint
        switch target {
        case .discovered(let phone): endpoint = .service(phone.endpoint, pinnedTo: phone.interface)
        case .manual(let host, let port): endpoint = .hostPort(host: host, port: port)
        }
        let known: String? = { if case .discovered(let phone) = target { return phone.deviceId } else { return nil } }()
        start(Session(endpoint: endpoint, knownDeviceId: known, clientId: clientId, keyStore: keyStore,
                      connectTimeout: connectTimeout, pairingTimeout: pairingTimeout),
              policy: .allowed)
    }

    /// `--connect host:port`: the test entry point. The session may pair (the
    /// phone's Allow is the only step) or reconnect with a key.
    private func beginManualLaunch(host: String, port: UInt16) {
        let ref = remembered.active?.ref ?? PhoneRef(id: "", name: host, model: "")
        send(.launch(ref))
        attemptTimer?.cancel()
        attemptTimer = nil
        if qr != nil { return } // the QR probes own the first handshake
        startManual(host: host, port: port, ref: ref)
    }

    private func startManual(host: String, port: UInt16, ref: PhoneRef) {
        start(Session(endpoint: .hostPort(host: host, port: port), knownDeviceId: ref.id.isEmpty ? nil : ref.id,
                      clientId: clientId, keyStore: keyStore,
                      connectTimeout: connectTimeout, pairingTimeout: pairingTimeout), policy: .allowed)
    }

    // MARK: Session events

    private func handle(_ event: SessionEvent) {
        switch event {
        case .state(let state, let detail):
            switch state {
            case .failed:
                stopClipboardSync()
                apkInstaller.connectionLost()
                attemptEnded(reason: detail ?? "closed")
            case .closed:
                stopClipboardSync()
                apkInstaller.connectionLost()
            default:
                break
            }
        case .clipboard(let text):
            clipboardSync?.receive(text)
        case .apkProgress(let id, let bytes):
            apkInstaller.progress(id: id, bytes: bytes)
        case .apkResult(let result):
            apkInstaller.result(result)
        case .ready(let info, _, let address):
            ready(info, address: address)
        case .apps(let list):
            appsReceived(list)
        case .icon(let pkg, let png):
            if let image = NSImage(data: png) {
                icons[pkg] = image
                windows.setIcon(image, pkg: pkg)
                if let id = link.phone?.id { IconCache.shared.store(png, pkg: pkg, deviceId: id) }
            } else {
                missingIcons.insert(pkg)
            }
        case .phoneState(let locked, let battery, let charging):
            status = PhoneStatus(locked: locked, battery: battery, charging: charging)
        case .pairCodeShown(let deviceId, let code):
            codeShown(deviceId: deviceId, code: code)
        case .pairApproved:
            send(.pairApproved)
        case .qrPaired(let deviceId):
            finishQRPairing(deviceId: deviceId, name: session?.phone?.name)
        case .identityMismatch(let expected, let actual):
            Log.session.notice("dropping cached address for \(expected, privacy: .public) (answers as \(actual, privacy: .public))")
            cache.forget(deviceId: expected)
        case .phoneError(let code, _, let stream):
            if code == "launch_failed" || (stream != 0 && code == "no_stream") {
                showTransient(ConnectionFailure.message(for: code) ?? "Something went wrong.")
            }
        default:
            break
        }
        windows.handle(event)
    }

    private func attemptEnded(reason: String) {
        lastAttemptFailed = true
        send(.attemptFailed(reason: reason))
    }

    /// Plain-text clipboard sync for the session that just became ready. The
    /// send path is bound to that session, so a later session never gets its text.
    private func startClipboardSync(on session: Session) {
        stopClipboardSync()
        let defaults = profile.defaults
        let sync = ClipboardSync(pasteboard: SystemPasteboard(),
                                 isEnabled: { ClipboardSync.isEnabled(in: defaults) },
                                 send: { [weak session] text in session?.sendClipboard(text) },
                                 clock: ClipboardSync.timerClock)
        sync.start()
        clipboardSync = sync
    }

    private func stopClipboardSync() {
        clipboardSync?.stop()
        clipboardSync = nil
    }

    private func ready(_ info: PhoneInfo, address: CachedAddress?) {
        let ref = PhoneRef(id: info.id, name: info.name, model: info.model)
        let wasPairing = isPairing
        remembered.remember(ref)
        rememberedPhones = remembered.all
        markWelcomeSeen()
        if let address {
            cache.store(address, deviceId: info.id)
            cache.store(name: info.name, deviceId: info.id)
        }
        lastAttemptFailed = false
        let hadWindows = !windows.openStreams.isEmpty
        windows.phone = info
        status = PhoneStatus(locked: info.locked, battery: info.battery, charging: info.charging ?? false)
        if apps.isEmpty || link.phone?.id != info.id { resetPhoneData(for: ref) }
        send(.welcome(ref))
        everOnline = true
        if let session { startClipboardSync(on: session) }
        session?.requestApps()
        if hadWindows { windows.reopenAll() }
        if wasPairing {
            pairingSucceeded = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pairingSucceeded = false
                    if self.sheet == .code { self.sheet = nil }
                }
            }
        }
        if !didAutoOpen {
            didAutoOpen = true
            applyAutoOpen()
        }
        if let request = pendingOpen, request.deviceId == info.id {
            pendingOpen = nil
            windows.openApp(pkg: request.pkg)
        }
        openPendingLink(readyPhone: info.id)
        installPendingApk(readyPhone: info.id)
        transientBanner = nil
    }

    private func appsReceived(_ list: [AppInfo]) {
        apps = list
        appsLoaded = true
        windows.appsByPkg = Dictionary(list.map { ($0.pkg, $0) }, uniquingKeysWith: { first, _ in first })
        windows.applyLabels()
        if let id = link.phone?.id { appsCache.store(list, deviceId: id) }
        for app in list where icons[app.pkg] == nil {
            if let id = link.phone?.id, let cached = IconCache.shared.load(pkg: app.pkg, deviceId: id) {
                icons[app.pkg] = cached
                windows.setIcon(cached, pkg: app.pkg)
            } else {
                session?.requestIcon(pkg: app.pkg)
            }
        }
        if let ref = link.phone {
            spotlight.index(apps: list, deviceId: ref.id, phoneName: ref.name,
                            iconData: { IconCache.shared.loadData(pkg: $0, deviceId: ref.id) })
        }
    }

    private func codeShown(deviceId: String?, code: String) {
        let ref = link.phone ?? PhoneRef(id: deviceId ?? "", name: "your phone", model: "")
        send(.codeShown(ref, code: code))
        sheet = .code
    }

    private func showTransient(_ text: String) {
        transientBanner = Banner(text: text, action: nil)
        transientTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.transientBanner = nil }
        }
        transientTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    // MARK: Test hooks

    private func applyAutoOpen() {
        for pkg in options.openPackages { windows.openApp(pkg: pkg) }
        if options.openPhone { windows.openPhoneWindow() }
        for resize in options.resizes {
            DispatchQueue.main.asyncAfter(deadline: .now() + resize.after) { [weak self] in
                MainActor.assumeIsolated { self?.windows.resize(stream: resize.stream, to: resize.size) }
            }
        }
        for minimize in options.minimizes {
            DispatchQueue.main.asyncAfter(deadline: .now() + minimize.after) { [weak self] in
                MainActor.assumeIsolated { self?.windows.controller(for: minimize.stream)?.window?.miniaturize(nil) }
            }
        }
        for deminimize in options.deminimizes {
            DispatchQueue.main.asyncAfter(deadline: .now() + deminimize.after) { [weak self] in
                MainActor.assumeIsolated { self?.windows.controller(for: deminimize.stream)?.window?.deminiaturize(nil) }
            }
        }
    }

    // MARK: QR pairing

    /// Show a fresh key as a QR and probe the phones we can see for it (every 2 s
    /// round, each phone at most every 4 s, for 5 minutes).
    func startQRPairing(presentAfterLaunch: Bool = false) {
        if let qr, !qr.expired { sheet = .qr; return }
        stopQR()
        guard let payload = PairingQRPayload.random(clientId: clientId, name: ClientIdentity.name) else {
            showTransient("Couldn't create a pairing code.")
            return
        }
        qr = QRPairingState(payload: payload)
        if presentAfterLaunch { pendingSheet = .qr } else { sheet = .qr }
        if let path = options.qrPayloadFile {
            try? payload.uri.write(toFile: path, atomically: true, encoding: .utf8)
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.qrRound() }
        }
        RunLoop.main.add(timer, forMode: .common)
        qrTimer = timer
        qrRound()
    }

    func cancelQRPairing() {
        stopQR()
        if sheet == .qr { sheet = nil }
    }

    private func stopQR() {
        qrTimer?.invalidate()
        qrTimer = nil
        for probe in qrProbes { probe.session.close() }
        qrProbes.removeAll()
        qrLastProbe.removeAll()
        qrBusyUntil.removeAll()
        qr = nil
    }

    private func expireQR() {
        guard var state = qr else { return }
        state.expired = true
        qr = state
        qrTimer?.invalidate()
        qrTimer = nil
        for probe in qrProbes { probe.session.close() }
        qrProbes.removeAll()
    }

    private func qrRound() {
        guard let state = qr, !state.expired, !state.succeeded else { return }
        if state.payload.isExpired() { expireQR(); return }
        let now = Date()
        for probe in qrProbes where now.timeIntervalSince(probe.startedAt) > QRProbePlanner.probeInterval {
            probe.session.close()
        }
        let paired = Set(rememberedPhones.map(\.id).filter { keyStore.key(forDeviceId: $0) != nil })
        let busy = Set(qrProbes.map(\.id))
        for phone in QRProbePlanner.candidates(phones: discovered, paired: paired, active: busy,
                                                lastProbe: qrLastProbe, busyUntil: qrBusyUntil, now: now) {
            startProbe(id: phone.deviceId, endpoint: .service(phone.endpoint, pinnedTo: phone.interface), deviceId: phone.deviceId,
                       key: state.payload.key, now: now)
        }
        if let connect = options.connect {
            let id = "\(connect.host):\(connect.port)"
            let due = qrLastProbe[id].map { now.timeIntervalSince($0) >= QRProbePlanner.probeInterval } ?? true
            if !busy.contains(id), due {
                startProbe(id: id, endpoint: .hostPort(host: connect.host, port: connect.port), deviceId: nil,
                           key: state.payload.key, now: now)
            }
        }
    }

    private func startProbe(id: String, endpoint: Session.Endpoint, deviceId: String?, key: Data, now: Date) {
        let probe = Session(endpoint: endpoint, knownDeviceId: deviceId, clientId: clientId, keyStore: keyStore)
        probe.pairingPolicy = .never
        probe.usePairingKey(key)
        probe.onEvent = { [weak self, weak probe] event in
            MainActor.assumeIsolated {
                guard let self, let probe else { return }
                self.handleProbe(event, id: id, probe: probe)
            }
        }
        qrLastProbe[id] = now
        qrProbes.append(QRProbe(session: probe, id: id, startedAt: now))
        probe.start()
    }

    private func handleProbe(_ event: SessionEvent, id: String, probe: Session) {
        switch event {
        case .qrPaired(let deviceId):
            finishQRPairing(deviceId: deviceId, name: probe.phone?.name)
        case .state(.failed(let reason), _):
            if reason == "busy" { qrBusyUntil[id] = Date().addingTimeInterval(QRProbePlanner.busyBackoff) }
            qrProbes.removeAll { $0.session === probe }
        case .state(.closed, _):
            qrProbes.removeAll { $0.session === probe }
        default:
            break
        }
    }

    /// The phone scanned the QR and accepted the key (already stored by the probe).
    private func finishQRPairing(deviceId: String, name: String?) {
        guard var state = qr, !state.succeeded else { return }
        state.succeeded = true
        qr = state
        qrTimer?.invalidate()
        qrTimer = nil
        let found = discovered.first { $0.deviceId == deviceId }
        let ref = PhoneRef(id: deviceId, name: name ?? found?.name ?? "Phone", model: found?.model ?? "")
        for probe in qrProbes { probe.session.close() }
        qrProbes.removeAll()
        remembered.remember(ref)
        rememberedPhones = remembered.all
        markWelcomeSeen()
        windows.closeAll()
        closeSession()
        // The probe's socket has to be gone first: the phone serves one session.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.resetPhoneData(for: ref)
                self.send(.activate(ref))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.qr?.succeeded == true else { return }
                self.qr = nil
                if self.sheet == .qr { self.sheet = nil }
            }
        }
    }

    // MARK: Preview states (screenshots only)

    /// `--preview NAME`: drives the UI with a scripted state, without sockets,
    /// the pair keys or the profile. Used for the screenshots of states that
    /// cannot be staged against a fake phone.
    private func applyPreview(_ name: String) {
        isPreview = true
        let ref = PhoneRef(id: "preview", name: "Galaxy S25+", model: "SM-S936B")
        let phone = RememberedPhone(id: ref.id, name: ref.name, model: ref.model, lastSeen: Date())
        let other = PhoneRef(id: "preview-2", name: "Pixel 9", model: "Pixel 9")
        func deck(_ link: Link, loaded: Bool = true, battery: Int = 87, charging: Bool = false, locked: Bool = true) {
            rememberedPhones = [phone]
            welcomeSeen = true
            apps = loaded ? PreviewData.apps : []
            appsLoaded = loaded
            icons = PreviewData.icons
            missingIcons = PreviewData.iconless
            machine = LinkMachine(link: link)
            if case .online = link { status = PhoneStatus(locked: locked, battery: battery, charging: charging) }
        }
        func pairingSheet(_ state: Pairing) {
            rememberedPhones = []
            welcomeSeen = true
            discovered = []
            machine = LinkMachine(link: .pairing(ref, state))
            pendingSheet = .code
        }
        switch name {
        case "welcome":
            rememberedPhones = []
            welcomeSeen = false
        case "nearby", "nearby-empty":
            rememberedPhones = []
            welcomeSeen = true
        case "nearby-phones":
            rememberedPhones = []
            welcomeSeen = true
            discovered = PreviewData.nearby
        case "code-contacting": pairingSheet(.contacting)
        case "code": pairingSheet(.comparing(code: "482913"))
        case "code-verifying": pairingSheet(.verifying)
        case "code-denied": pairingSheet(.denied)
        case "code-timedout": pairingSheet(.timedOut)
        case "qr", "qr-success", "qr-expired":
            rememberedPhones = []
            welcomeSeen = true
            if let payload = PairingQRPayload.random(clientId: clientId, name: ClientIdentity.name) {
                qr = QRPairingState(payload: payload, succeeded: name == "qr-success", expired: name == "qr-expired")
            }
            pendingSheet = .qr
        case "manual":
            rememberedPhones = []
            welcomeSeen = true
            pendingSheet = .manual
        case "loading": deck(.online(ref), loaded: false)
        case "deck": deck(.online(ref))
        case "deck-5": deck(.online(ref), battery: 5)
        case "deck-24": deck(.online(ref), battery: 24, locked: false)
        case "deck-100": deck(.online(ref), battery: 100, charging: true)
        case "connecting": deck(.connecting(ref))
        case "reconnecting": deck(.reconnecting(ref))
        case "offline": deck(.offline(ref, .unreachable))
        case "busy": deck(.offline(ref, .busy))
        case "needspairing": deck(.needsPairing(ref))
        case "add-phone":
            deck(.online(ref))
            discovered = PreviewData.nearby
            pendingSheet = .addPhone
        case "devices":
            deck(.online(ref))
            rememberedPhones = [phone, RememberedPhone(id: other.id, name: other.name, model: other.model,
                                                       lastSeen: Date().addingTimeInterval(-86_400 * 2))]
        default:
            FileHandle.standardError.write(Data("--preview \(name): unknown state\n".utf8))
            exit(2)
        }
    }
}
