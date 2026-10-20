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
    /// The v2 identity + pin store (docs/design/e2ee.md §3): identity.json is
    /// the Mac's TLS identity, pins.json holds one record per phone; identity's
    /// `pin` mirrors the current phone's fingerprint.
    /// The live §3 identity; the pin mirror changes in memory and on disk
    /// together (sessions started later read this copy, not the file).
    private(set) var identity: DeviceIdentityV2
    let identityFile: IdentityFileV2
    let pins: PhonePinStoreV2
    let cache: CachedDeviceStore
    let remembered: RememberedPhones
    let appsCache: AppsCache
    let spotlight: SpotlightIndex
    /// The last battery each phone reported, for the battery intent while the
    /// phone is away (docs/design/intents.md).
    let batteryMemory: BatteryMemory
    /// Dock and Launchpad apps (docs/design/dock.md).
    let dockApps: DockApps
    let windows: WindowManager
    /// The automation server (docs/design/mcp.md); off unless the profile's
    /// setting says otherwise.
    @ObservationIgnored let mcp = MCPAutomation()
    let audio = AudioEngine()
    private let discovery = Discovery()
    private var audioStarted = false
    /// Phone notifications on the Mac (docs/design/notify.md).
    @ObservationIgnored let notifyCenter = NotifyCenter()
    /// The phone's media session in macOS Now Playing.
    @ObservationIgnored let nowPlaying = NowPlayingController()

    // MARK: Published state

    private(set) var machine = LinkMachine()
    var link: Link { machine.link }
    private(set) var transientBanner: Banner?
    /// APK installs (docs/design/apk.md); the Deck shows its phase.
    let apkInstaller = ApkInstaller()
    /// Files dropped on a window (docs/design/dragdrop.md); windows show the pill.
    let dropSender = FileDropSender()
    /// The phone's clipboard image assembly (docs/design/dragdrop.md).
    private let clipImageBuffer = ClipImageBuffer()
    /// Shares from the phone (docs/design/sharein.md).
    @ObservationIgnored private lazy var shareActions: SystemShareActions = {
        SystemShareActions(log: options.shareLog.map { URL(fileURLWithPath: $0) }) { [weak self] text in
            // Through the clipboard sync, so the shared text is not sent back as clip.set.
            if let sync = self?.clipboardSync { sync.adopt(text) } else { SystemPasteboard().write(text: text) }
        }
    }()
    @ObservationIgnored private lazy var shareInbox: ShareInbox = {
        let directory = options.shareDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? ShareInbox.defaultDirectory
        return ShareInbox(directory: directory, actions: shareActions)
    }()
    var banner: Banner? { transientBanner ?? link.banner(naming: { displayName(for: $0) }) }
    private(set) var audioOn = false

    // MARK: Nicknames (docs/ROADMAP.md #1)

    /// Bumped on every nickname change; the views read it (through
    /// `displayName`) so a rename re-renders every name-bearing string.
    private(set) var nicknamesRevision = 0

    /// The one name for a phone: its nickname, else its own name.
    func displayName(for phone: PhoneRef, fallback: String = "Phone") -> String {
        _ = nicknamesRevision
        return remembered.displayName(for: phone, fallback: fallback)
    }

    /// The stored nickname for a device ("" when none, which shows its own name).
    func nickname(for deviceId: String) -> String {
        PhoneNicknames.read(from: profile.defaults, deviceId: deviceId)
    }

    /// Settings → Devices → Rename: store the trimmed nickname (empty clears
    /// it) and refresh everything that names the phone — the views (via the
    /// revision), open window titles, the Spotlight entries and the Dock shims
    /// (the same rebuild a renamed phone gets from `reconcile`).
    func setNickname(_ raw: String, for deviceId: String) {
        guard !deviceId.isEmpty else { return }
        PhoneNicknames.write(raw, for: deviceId, to: profile.defaults)
        refreshNickname(deviceId: deviceId)
    }

    private func refreshNickname(deviceId: String) {
        nicknamesRevision += 1
        rememberedPhones = remembered.all
        guard let phone = remembered.phone(id: deviceId)?.ref else { return }
        let name = displayName(for: phone)
        if link.phone?.id == deviceId { windows.setPhoneName(name) }
        // The app list this Mac has for the phone: live for the current
        // session's phone, the cached one otherwise.
        let apps = link.phone?.id == deviceId && appsLoaded ? self.apps : appsCache.load(deviceId: deviceId)
        guard !apps.isEmpty else { return }
        spotlight.index(apps: apps, deviceId: deviceId, phoneName: name,
                        iconData: { IconCache.shared.loadData(pkg: $0, deviceId: deviceId) })
        dockApps.reconcile(deviceId: deviceId, apps: apps, phoneName: name,
                           keep: deviceId == link.phone?.id ? dockPkgsOfOpenWindows : [])
        dockRevision += 1
    }

    /// The name for a notification about the session's phone ("Copied from
    /// Nicky"); before `welcome` keeps ShareInbox's neutral default.
    private func shareName() -> String {
        guard let phone = session?.phone else { return "your phone" }
        return displayName(for: PhoneRef(id: phone.id, name: phone.name, model: phone.model), fallback: "your phone")
    }

    private(set) var discovered: [DiscoveredPhone] = []
    private(set) var rememberedPhones: [RememberedPhone] = []
    private(set) var apps: [AppInfo] = []
    private(set) var appsLoaded = false
    private(set) var icons: [String: NSImage] = [:]
    /// The adaptive layers of the icons that have them (`deck.glassIcons`).
    private(set) var iconLayers: [String: AppIconLayers] = [:]
    /// Packages the phone answered with no icon at all.
    private(set) var missingIcons: Set<String> = []
    /// The one re-request a flat cached icon gets per connection.
    private let layerRefresh = IconLayerRefresh()
    private(set) var status: PhoneStatus?
    private(set) var pairingSucceeded = false
    private(set) var qr: QRPairingState?
    private(set) var welcomeSeen: Bool
    private(set) var searchedLong = false
    private(set) var browseDenied = false

    var sheet: DeckSheet?
    /// A sheet requested before the Deck window exists (launch hooks, previews).
    private(set) var pendingSheet: DeckSheet?

    /// Bumped to open the Settings window (previews stage the Devices
    /// screenshot; the gear and ⌘, are the real entry points). Read by DeckRoot.
    private(set) var settingsRequest = 0
    /// The phone being renamed right now: Settings → Devices → Rename… presents
    /// its dialog for this device; a preview stages the whole state.
    private(set) var renamingDeviceId: String?
    /// Preview only: the rename field's staged text (screenshots, never stored).
    private(set) var previewRenameText: String?

    func presentPendingSheet() {
        guard let pending = pendingSheet else { return }
        pendingSheet = nil
        sheet = pending
    }

    /// Settings → Devices → Rename…: the dialog for this phone is presented
    /// (and dismissed) in DevicesSettings.
    func beginRename(_ phone: RememberedPhone) {
        renamingDeviceId = phone.id
        previewRenameText = nil
    }

    func endRename() {
        renamingDeviceId = nil
        previewRenameText = nil
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
                               needsPairing: known && pins.record(for: phone.deviceId) == nil)
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
    /// A Dock app asked for its window before its phone was ready.
    private var pendingDockOpen: (deviceId: String, pkg: String, pid: Int)?
    /// `--dock-add` / `--dock-remove` still to run (e2e).
    private var dockHooksPending = true
    /// Bumped when Dock apps are added or removed, so menus re-read the folder.
    private(set) var dockRevision = 0
    /// A link waiting for its phone to become ready (nil phone = whichever comes first).
    private var pendingLink: (request: OpenLinkRequest, until: Date)?
    /// An app file waiting for its phone to become ready (nil phone = whichever comes first).
    private var pendingApk: (file: URL, deviceId: String?, until: Date)?
    /// An intent's whole-phone window waiting for its phone (docs/design/intents.md).
    private var pendingPhoneWindow: (deviceId: String, until: Date)?
    /// An intent's files waiting for their phone.
    private var pendingDrop: (urls: [URL], deviceId: String, until: Date)?
    /// `--debug-intent`: parsed lines still to run, in flag order.
    private var pendingDebugIntents: [DebugIntent] = []
    private var debugInput: DebugInputDriver?
    private var debugControl: DebugControl?
    /// `--debug-fs-script` (FsDebug.swift): pending phone-file steps and the
    /// client that carries them.
    private var fsScriptActions: [FsScriptAction]?
    private var fsClient: FsClient?
    private var fsDebug: FsDebugDriver?
    /// `--debug-livetext`: the script runs once the first stream window has a
    /// video size (DebugLiveText.swift, e2e `livetext`).
    private var liveTextDebug: LiveTextDebugDriver?
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
        // The first v2 run deletes the v1 pair keys (one forced re-pair, §7);
        // identity.json is created when missing — no reverse path.
        identityFile = IdentityFileV2(url: IdentityFileV2.fileUrl(in: profile))
        if let existing = identityFile.load() {
            identity = existing
        } else {
            let generated = IdentityGeneratorV2.make(deviceId: clientId)
            identityFile.save(generated.identity)
            identity = generated.identity
        }
        IdentityMigrationV2.wipePairKeys(at: profile.pairKeysFileUrl)
        pins = PhonePinStoreV2(fileUrl: PhonePinStoreV2.fileUrl(in: profile))
        cache = CachedDeviceStore(profile: profile)
        remembered = RememberedPhones(profile: profile)
        appsCache = AppsCache(profile: profile)
        spotlight = SpotlightIndex(domainPrefix: profile.spotlightDomainPrefix)
        batteryMemory = BatteryMemory(profile: profile)
        dockApps = DockApps(folder: DockApps.defaultFolder(profile: profile, override: options.dockDirectory),
                            profile: profile)
        windows = WindowManager(session: Session(endpoint: .hostPort(host: "127.0.0.1", port: 1),
                                                 knownDeviceId: nil, clientId: ""),
                                defaults: profile.defaults)
        welcomeSeen = remembered.welcomeSeen
        rememberedPhones = remembered.all
        audio.statsFile = options.audioStatsFile
        windows.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.syncAudio() }
        }
        windows.onDensityOverridesChanged = { [weak self] in
            MainActor.assumeIsolated { self?.refreshDensityOverrides() }
        }
        densityOverrides = windows.densityOverrides
        // Notification sharing (docs/design/notify.md): the router owns the UN
        // delegate and clicks; share notifications still route to their actions.
        // The same `--share-log` file records what both halves would have shown.
        let shareLog = options.shareLog.map { URL(fileURLWithPath: $0) }
        notifyCenter.log = shareLog
        notifyCenter.onOpen = { [weak self] click in
            MainActor.assumeIsolated { self?.notificationClicked(click) }
        }
        nowPlaying.log = shareLog
        nowPlaying.onCommand = { [weak self] action in
            MainActor.assumeIsolated { self?.session?.mediaCommand(action) }
        }
        mcp.configure(profile: profile, forced: options.mcpEnable)
        mcp.hostProvider = { [weak self] in self.map { MCPToolHost(controller: $0) } }
    }

    var audioVolume: Float {
        get { audio.volume }
        set { audio.volume = newValue }
    }

    var audioMuted: Bool {
        get { audio.muted }
        set { audio.muted = newValue }
    }

    /// Start device audio when online with ≥1 window; stop otherwise.
    /// Mac-side gain only — the phone is silenced by its submix routing.
    func syncAudio() {
        guard link.isOnline, !windows.openStreams.isEmpty else {
            if audioStarted {
                audioStarted = false
                session?.stopAudio()
                audio.stop()
                audioOn = false
            }
            return
        }
        if !audioStarted {
            audioStarted = true
            session?.startAudio()
        }
    }

    // MARK: Lifecycle

    func start() {
        launchAt = Date()
        if let directory = options.dumpVideoDirectory { windows.videoDump = VideoDump(directory: directory) }
        windows.floatWindows = options.floatWindows
        windows.chromeStateFile = options.debugChromeState.map { URL(fileURLWithPath: $0) }
        if let path = options.debugInputScript, let error = armDebugInput(path) {
            FileHandle.standardError.write(Data((error + "\n").utf8))
            exit(2)
        }
        if let path = options.debugFsScript {
            do {
                fsScriptActions = try FsDebugScript.parse(String(contentsOfFile: path, encoding: .utf8))
            } catch {
                FileHandle.standardError.write(Data("debug-fs-script \(path): \(error)\n".utf8))
                exit(2)
            }
        }
        if let path = options.debugLiveText {
            do {
                let driver = try LiveTextDebugDriver(scriptPath: path, windows: windows)
                liveTextDebug = driver
                driver.arm()
            } catch {
                FileHandle.standardError.write(Data("debug-livetext \(path): \(error)\n".utf8))
                exit(2)
            }
        }
        if let directory = options.debugControl {
            debugControl = DebugControl(directory: directory) { [weak self] command, arguments in
                MainActor.assumeIsolated {
                    // nil is "ran": `self?.…` would read a run command as a missing self.
                    guard let self else { return "no controller" }
                    return self.performDebugControl(command, arguments)
                }
            }
            debugControl?.start()
        }
        armDebugIntents()
        if let preview = options.preview {
            applyPreview(preview)
            return
        }
        mcp.start()
        windows.onStreamClosed = { [weak self] stream in
            DispatchQueue.main.async { self?.dockFollowWindowClosed(stream) }
        }
        windows.onFilesDropped = { [weak self] urls in
            MainActor.assumeIsolated { self?.dropFiles(urls) }
        }
        windows.onAppWindowOpened = { [weak self] pkg, stream in
            MainActor.assumeIsolated { self?.establishDockFollow(pkg: pkg, stream: stream) }
        }
        dockApps.onOpen = { [weak self] deviceId, pkg, pid in self?.openFromDock(deviceId: deviceId, pkg: pkg, pid: pid) }
        dockApps.onShimQuit = { [weak self] stream in self?.windows.controller(for: stream)?.window?.close() }
        dockApps.start()
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
        // The UN delegate is installed eagerly, before any notification from
        // either side (share or phone); share responses route back to their
        // actions through it.
        notifyCenter.router.shareActions = shareActions
        notifyCenter.install()
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
        mcp.stop()
        windows.beginShutdown()
        stopQR()
        attemptTimer?.cancel()
        stopClipboardSync()
        dropSender.connectionLost()
        clipImageBuffer.discard()
        if audioStarted {
            audioStarted = false
            session?.stopAudio()
        }
        audio.stop()
        audioOn = false
        nowPlaying.clear()
        // Quit path only: give the teardown a bounded moment so the process
        // does not exit with a half-closed channel (arch H4).
        session?.closeAndWait()
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
        pins.forget(deviceId: phone.id)
        syncIdentityPinMirrorAfterForget(deviceId: phone.id)
        cache.forget(deviceId: phone.id)
        remembered.forget(id: phone.id)
        appsCache.remove(deviceId: phone.id)
        spotlight.remove(deviceId: phone.id)
        dockApps.forget(deviceId: phone.id)
        dockRevision += 1
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

    /// When no record in the store holds the §3 mirror fingerprint, empty the
    /// mirror (identity.json must never name a phone the store forgot).
    private func syncIdentityPinMirrorAfterForget(deviceId: String) {
        guard !identity.pin.isEmpty else { return }
        if let holder = pins.all.first(where: { $0.phoneFingerprintHex == identity.pin }), holder.deviceId != deviceId {
            return
        }
        identity.pin = ""
        identityFile.save(identity)
    }

    func openApp(_ app: AppInfo) {
        guard link.isOnline else { return }
        windows.openApp(pkg: app.pkg, activity: app.activity)
    }

    func openPhoneWindow() {
        guard link.isOnline else { return }
        windows.openPhoneWindow()
    }

    /// "Continue on Mac" (docs/ROADMAP.md #9): a window for the app in the
    /// foreground on the phone's screen. The phone answers with `window.opened`
    /// (and the video) for the stream, or `nothing_to_continue` — which shows
    /// as the transient banner.
    func continueOnMac() {
        guard link.isOnline else { return }
        windows.openHandoffWindow()
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

    // MARK: Dock apps (docs/design/dock.md)

    func isInDock(_ app: AppInfo) -> Bool {
        _ = dockRevision
        guard let id = link.phone?.id else { return false }
        return dockApps.hasShim(deviceId: id, pkg: app.pkg)
    }

    var canAddToDock: Bool { dockApps.isAvailable && link.phone != nil }

    func addToDock(_ app: AppInfo) {
        guard let phone = link.phone else { return }
        if dockApps.add(deviceId: phone.id, pkg: app.pkg, label: app.label, phoneName: displayName(for: phone),
                        launch: true, pinned: true) == nil {
            showTransient("Couldn't add \(app.label) to the Dock.")
        }
        dockRevision += 1
    }

    func removeFromDock(_ app: AppInfo) {
        guard let id = link.phone?.id else { return }
        dockApps.remove(deviceId: id, pkg: app.pkg)
        dockRevision += 1
    }

    /// A Dock app was launched, clicked or ⌘-Tabbed to: its window opens or comes forward.
    private func openFromDock(deviceId: String, pkg: String, pid: Int) {
        if let stream = dockApps.stream(forPid: pid), let window = windows.controller(for: stream)?.window {
            dockApps.acknowledge(pid: pid)
            focusWindow(stream: stream)
            return
        }
        if link.isOnline, link.phone?.id == deviceId {
            // The window this shim stood for can already be open (it was opened
            // from the Deck or Spotlight while the shim was being built, or a
            // kept identity was launched by hand): it takes that window instead
            // of a second one.
            let bound = dockApps.boundStreams
            if let stream = windows.openAppWindows.first(where: { $0.pkg == pkg && !bound.contains($0.stream) })?.stream {
                dockApps.bind(pid: pid, stream: stream, pkg: pkg)
                focusWindow(stream: stream)
                return
            }
            dockApps.bind(pid: pid, stream: windows.openApp(pkg: pkg).stream, pkg: pkg)
            return
        }
        guard let phone = remembered.phone(id: deviceId) else {
            dockApps.acknowledge(pid: pid)
            showTransient("That phone isn't paired.")
            return
        }
        dockApps.acknowledge(pid: pid)
        pendingDockOpen = (deviceId, pkg, pid)
        if link.phone?.id != deviceId { use(phone) }
    }

    private func focusWindow(stream: UInt32) {
        BackgroundMode.activateApp()
        guard let window = windows.controller(for: stream)?.window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    private func openPendingDock(readyPhone id: String) {
        guard let pending = pendingDockOpen, pending.deviceId == id else { return }
        pendingDockOpen = nil
        dockApps.bind(pid: pending.pid, stream: windows.openApp(pkg: pending.pkg).stream, pkg: pending.pkg)
    }

    /// Test hooks: once the app list (and the app's icon) is in.
    private func runDockHooks() {
        guard dockHooksPending, let phone = link.phone, appsLoaded else { return }
        if let pkg = options.dockAdd {
            guard IconCache.shared.loadData(pkg: pkg, deviceId: phone.id) != nil || missingIcons.contains(pkg) else { return }
            let label = apps.first { $0.pkg == pkg }?.label ?? pkg
            dockApps.add(deviceId: phone.id, pkg: pkg, label: label, phoneName: displayName(for: phone),
                         launch: false, pinned: true)
        }
        if let pkg = options.dockRemove { dockApps.remove(deviceId: phone.id, pkg: pkg) }
        // `--set-nickname`: the rename a person does in Settings → Devices →
        // Rename, driven as a hook so the check runs the real code path.
        if let name = options.setNickname { setNickname(name, for: phone.id) }
        dockHooksPending = false
        dockRevision += 1
    }

    // MARK: The Dock identity of open app windows (docs/design/dock.md §Lifecycle)

    /// Keys of `{deviceId}/{pkg}` the automatic path is currently working on, so
    /// one app identity is built at most once per moment.
    private var dockEstablishing: Set<String> = []

    /// Settings → General "Show phone apps in the Dock": on unless it is off.
    var showAppsInDock: Bool { DockAutoSetting.isEnabled(in: profile.defaults) }

    /// The setting changed: open windows follow immediately. Off stops the
    /// running automatic identities too (their windows stay); manually added
    /// ones follow the existing rule and keep running.
    func showAppsInDockChanged() {
        if !showAppsInDock { dockApps.quitUnpinnedShims() }
        recheckOpenWindows()
    }

    /// Settings → General "Reveal controls after": open immersive windows take
    /// the new delay at once.
    func setRevealDelay(_ delay: RevealDelay) {
        windows.setRevealDelay(delay)
    }

    /// Settings → General "Default window density": every window of an app
    /// without an override takes it at once.
    func setDefaultDensity(_ value: Double) {
        profile.defaults.set(value, forKey: WindowDensity.key)
        windows.defaultDensityChanged()
    }

    /// Settings → General "App overrides": the list, refreshed whenever one
    /// changes (the menu, the keyboard, Settings itself).
    private(set) var densityOverrides: [DensityOverride] = []

    private func refreshDensityOverrides() {
        densityOverrides = windows.densityOverrides
    }

    func clearDensityOverride(forPackage pkg: String) {
        windows.setDensity(nil, forPackage: pkg)
    }

    func clearAllDensityOverrides() {
        windows.clearAllDensityOverrides()
    }

    /// The name the Deck shows for a package (the launcher and Dock lookup),
    /// else the package itself (Settings → General "App overrides").
    func displayName(forPackage pkg: String) -> String {
        appLabel(pkg) ?? pkg
    }

    /// Debug input "dockapps on|off": the setting the Settings toggle writes,
    /// then the same handler its onChange runs (e2e).
    func setShowAppsInDock(_ on: Bool) {
        profile.defaults.set(on, forKey: DockAutoSetting.key)
        showAppsInDockChanged()
    }

    /// Pkgs of open windows — shims standing for one are neither removed nor
    /// rebuilt by the app-list reconciliation until their window is gone.
    private var dockPkgsOfOpenWindows: Set<String> {
        Set(windows.openAppWindows.compactMap(\.pkg))
    }

    /// A window closed: its shim exits — unless another window of the same app
    /// is still open, which the identity moves to instead (docs/design/dock.md).
    private func dockFollowWindowClosed(_ stream: UInt32) {
        if let (pid, pkg) = dockApps.binding(stream: stream),
           let next = windows.openAppWindows.first(where: { $0.pkg == pkg && $0.stream != stream })?.stream {
            dockApps.rebind(pid: pid, to: next)
            return
        }
        dockApps.streamClosed(stream)
    }

    /// An open app window has no Dock identity bound to it: decide what happens.
    /// Cheap reads on the main thread; the file work is off it.
    private func establishDockFollow(pkg: String, stream: UInt32) {
        guard showAppsInDock, dockApps.isAvailable, let phone = link.phone else { return }
        guard let label = appLabel(pkg), !dockEstablishing.contains("\(phone.id)/\(pkg)") else { return }
        if dockApps.boundStreams.contains(stream) { return }
        let decision = DockFollow.decide(
            settingOn: showAppsInDock, shimBinary: dockApps.isAvailable, phoneKnown: true,
            shimExists: dockApps.hasShim(deviceId: phone.id, pkg: pkg),
            shimRunning: dockApps.isRunning(deviceId: phone.id, pkg: pkg),
            shimHasIcon: dockApps.shimHasIcon(deviceId: phone.id, pkg: pkg),
            icon: iconState(pkg: pkg, deviceId: phone.id))
        switch decision {
        case .skip, .wait:
            return
        case .launchExisting:
            bindWhenDockCleared(deviceId: phone.id, pkg: pkg, stream: stream) { launched in
                self.dockApps.relaunch(deviceId: phone.id, pkg: pkg, bind: stream, launched: launched)
            }
        case .createAndLaunch:
            bindWhenDockCleared(deviceId: phone.id, pkg: pkg, stream: stream) { launched in
                self.dockApps.buildAndLaunch(
                    DockShimSpec(deviceId: phone.id, pkg: pkg, label: label, phoneName: self.displayName(for: phone),
                                 profile: profile, hostPath: Bundle.main.bundleURL.path),
                    bind: stream, launched: launched)
            }
        }
    }

    /// Runs the launch and clears the in-flight key and binds the pid when it is up.
    private func bindWhenDockCleared(deviceId: String, pkg: String, stream: UInt32,
                                     work: (_ launched: @escaping (Int?) -> Void) -> Void) {
        let key = "\(deviceId)/\(pkg)"
        dockEstablishing.insert(key)
        work { [weak self] pid in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dockEstablishing.remove(key)
                if let pid {
                    // The setting can turn off while the bundle is being built:
                    // the fresh identity must not outlive it (only manual ones
                    // do), so it is stopped instead of bound.
                    if self.showAppsInDock || self.dockApps.isPinned(deviceId: deviceId, pkg: pkg) {
                        self.dockApps.bind(pid: pid, stream: stream, pkg: pkg)
                    } else {
                        self.dockApps.quit(pid: pid)
                    }
                }
                self.recheckOpenWindows()
            }
        }
    }

    /// The automatic path reconsiders every open app window: after the app list,
    /// the icons and the setting (a window may have waited for one of them).
    private func recheckOpenWindows() {
        for window in windows.openAppWindows {
            guard let pkg = window.pkg else { continue }
            establishDockFollow(pkg: pkg, stream: window.stream)
        }
    }

    private func appLabel(_ pkg: String) -> String? {
        windows.appsByPkg[pkg]?.label ?? apps.first { $0.pkg == pkg }?.label
    }

    private func iconState(pkg: String, deviceId: String) -> DockFollow.IconState {
        if IconCache.shared.loadData(pkg: pkg, deviceId: deviceId) != nil { return .cached }
        return missingIcons.contains(pkg) ? .reportedMissing : .unknown
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

    // MARK: Intents (docs/design/intents.md)

    /// The intent layer resolves the phone (IntentsCore); these take a device id
    /// and reuse the Deck's paths: an open window, the pending-open queue that
    /// Spotlight clicks use, the link route and the drop sender.

    func intentsOpenApp(_ pkg: String, on deviceId: String) {
        if link.isOnline, link.phone?.id == deviceId {
            windows.openApp(pkg: pkg)
            return
        }
        pendingOpen = SpotlightOpenRequest(deviceId: deviceId, pkg: pkg)
        if link.phone?.id != deviceId, let phone = remembered.phone(id: deviceId) { use(phone) }
    }

    func intentsOpenPhoneWindow(on deviceId: String) {
        if link.isOnline, link.phone?.id == deviceId {
            windows.openPhoneWindow()
            return
        }
        pendingPhoneWindow = (deviceId, Date().addingTimeInterval(Self.pendingLinkLifetime))
        if link.phone?.id != deviceId, let phone = remembered.phone(id: deviceId) { use(phone) }
    }

    func intentsSendLink(_ url: String, on deviceId: String) {
        openLink(url, on: deviceId)
    }

    func intentsSendFiles(_ urls: [URL], on deviceId: String) {
        guard !urls.isEmpty else { return }
        if link.isOnline, link.phone?.id == deviceId, let session {
            dropSender.send(urls, session: session)
            syncDropPill()
            return
        }
        pendingDrop = (urls, deviceId, Date().addingTimeInterval(Self.pendingLinkLifetime))
        if link.phone?.id != deviceId, let phone = remembered.phone(id: deviceId) { use(phone) }
    }

    /// `phone.ring` (docs/PROTOCOL.md "Ring"): the phone rings itself, so this
    /// only works on a live session.
    func ringPhone(seconds: Int = 30) {
        guard link.isOnline, let session else {
            showTransient("Connect a phone to ring it.")
            return
        }
        session.ring(seconds: seconds)
        showTransient("Ringing your phone.")
    }

    func stopRingingPhone() {
        guard link.isOnline, let session else { return }
        session.stopRing()
    }

    private func openPendingPhoneWindow(readyPhone id: String) {
        guard let pending = pendingPhoneWindow, pending.deviceId == id else { return }
        pendingPhoneWindow = nil
        guard pending.until > Date() else { return }
        windows.openPhoneWindow()
    }

    private func dropPendingFiles(readyPhone id: String) {
        guard let pending = pendingDrop, pending.deviceId == id else { return }
        pendingDrop = nil
        guard pending.until > Date(), let session else { return }
        dropSender.send(pending.urls, session: session)
        syncDropPill()
    }

    /// `--debug-intent` (e2e, docs/design/intents.md): battery needs no session
    /// and runs at launch; the others run when a phone is ready, or after 25 s
    /// so a check gets the intent's own failure instead of waiting forever.
    private func armDebugIntents() {
        guard !options.debugIntents.isEmpty else { return }
        for line in options.debugIntents {
            do {
                pendingDebugIntents.append(try DebugIntent.parse(line))
            } catch {
                IntentDebugLog.write(intent: line, ok: false,
                                     fields: ["error": "usage", "message": "\(error)"])
            }
        }
        runPendingDebugIntents(immediateOnly: true)
        guard !pendingDebugIntents.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            MainActor.assumeIsolated { self?.runPendingDebugIntents(immediateOnly: false) }
        }
    }

    private func runPendingDebugIntents(immediateOnly: Bool) {
        // Battery needs no session, but a launch that is about to pair has no
        // remembered phone yet: then it waits like the rest instead of saying
        // "pair a phone" a second before one arrives.
        let runnable = pendingDebugIntents.filter {
            !immediateOnly || ($0.isImmediate && !rememberedPhones.isEmpty)
        }
        guard !runnable.isEmpty else { return }
        pendingDebugIntents.removeAll { runnable.contains($0) }
        for intent in runnable { IntentDebugRunner.run(intent) }
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
        BackgroundMode.activateApp()
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

    // MARK: File drops (docs/design/dragdrop.md)

    /// A Finder drag onto a stream window (or `dropfile` scripting): a lone .apk
    /// keeps the install route, the rest stream to Downloads/PocketDeck one by
    /// one. Phone abroad → a banner; the phone was the point of the drag.
    func dropFiles(_ urls: [URL]) {
        guard !isPreview else { return }
        let files = urls.filter { $0.isFileURL }
        guard !files.isEmpty else { return }
        if files.count == 1, let app = files.first(where: { ApkBundle.kind(of: $0) != nil }) {
            installApk(app)
            return
        }
        guard link.isOnline, let session else {
            showTransient("Connect a phone to send files to it.")
            return
        }
        dropSender.send(files, session: session)
        syncDropPill()
    }

    /// The stream windows' pill mouth: the phase rendered as a line.
    private func syncDropPill() {
        switch dropSender.phase {
        case .idle:
            windows.setDropPill(nil)
        case .sending(let name, let fraction):
            windows.setDropPill(name.isEmpty
                ? ("Sending…", true)
                : ("Sending \(name)… \(Int((fraction * 100).rounded())) %", true))
        case .finished(let text, _):
            windows.setDropPill((text, false))
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.dropSender.phase == .finished(text, ok: true) || self.dropSender.phase == .finished(text, ok: false) else { return }
                    self.windows.setDropPill(nil)
                }
            }
        }
    }

    // MARK: Phone data

    private func resetPhoneData(for ref: PhoneRef) {
        windows.setPhoneName(displayName(for: ref))
        apps = appsCache.load(deviceId: ref.id)
        appsLoaded = !apps.isEmpty
        status = nil
        icons = [:]
        iconLayers = [:]
        missingIcons = []
        for app in apps {
            if let image = IconCache.shared.load(pkg: app.pkg, deviceId: ref.id) { icons[app.pkg] = image }
            loadCachedLayers(app.pkg, deviceId: ref.id)
        }
    }

    /// A cache entry that has layers goes straight into the grid (no
    /// re-request); a flat one stays flat until the connection checks.
    private func loadCachedLayers(_ pkg: String, deviceId: String) {
        guard iconLayers[pkg] == nil, let data = IconCache.shared.loadLayerData(pkg: pkg, deviceId: deviceId) else { return }
        iconLayers[pkg] = Self.glassLayers(fg: data.fg, bg: data.bg, mono: data.mono)
    }

    /// Decode the `icon` message's layer fields; incomplete or undecodable
    /// layers mean none.
    static func glassLayers(fg: Data?, bg: Data?, mono: Data?) -> AppIconLayers? {
        guard let fg, let bg else { return nil }
        return AppIconLayers(fg: NSImage(data: fg), bg: NSImage(data: bg),
                             mono: mono == nil ? nil : NSImage(data: mono!))
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
        if before.isOnline, !link.isOnline {
            windows.linkLost()
            dropSender.connectionLost()
            clipImageBuffer.discard()
        }
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
        // A test profile never dials a Bonjour-discovered phone on its own:
        // discovery would find the real phones on this Mac's LAN (DialPolicy).
        let found = DialPolicy.mayDialDiscovered(profile)
            ? discovered.first { $0.deviceId == ref.id } : nil
        if found == nil, let connect = options.connect {
            lastAttemptWasService = false
            start(Session(endpoint: .hostPort(host: connect.host, port: connect.port),
                          knownDeviceId: ref.id.isEmpty ? nil : ref.id, clientId: clientId,
                          identity: identity, pinnedPhone: pins.record(for: ref.id),
                          pinStore: pins,
                          onPinEstablished: { [weak self] record in self?.mirrorIdentityPin(record: record) }),
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
                      clientId: clientId, identity: identity, pinnedPhone: pins.record(for: ref.id),
                      pinStore: pins,
                      onPinEstablished: { [weak self] record in self?.mirrorIdentityPin(record: record) }),
              policy: .never)
    }

    /// identity.json's §3 `pin` mirrors the fingerprint of the phone this
    /// session just paired; re-saved after every successful pairing.
    private func mirrorIdentityPin(record: PinnedPhoneV2) {
        guard pins.record(for: record.deviceId)?.phoneFingerprintHex == record.phoneFingerprintHex else { return }
        identity.pin = record.phoneFingerprintHex
        identityFile.save(identity)
    }

    /// The Mac's own point fingerprint (the `f` param of the QR URI, R2).
    private func macFingerprintHex(in identity: DeviceIdentityV2) -> String {
        PairingQRPayload.selfFingerprintHex(identity: identity)
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
        newSession.onAudioEvent = { [weak self, weak newSession] event in
            guard let self, let newSession else { return }
            guard newSession === self.session else { return }
            switch event {
            case .config(let config): self.audio.configure(config)
            case .frame(let frame): self.audio.receive(frame)
            }
        }
        newSession.start()
    }

    // MARK: Pairing

    private func beginPairing(_ target: PairingTarget, ref: PhoneRef) {
        pairingTarget = target
        pairingSucceeded = false
        windows.closeAll()
        closeSession()
        // A person re-running the pairing revokes the old pin here (§7): the
        // next connect lands in pairing mode (no record, no §3 mirror).
        if case .discovered(let phone) = target {
            pins.forget(deviceId: phone.deviceId)
            syncIdentityPinMirrorAfterForget(deviceId: phone.deviceId)
        }
        sheet = .code
        send(.beginPairing(ref))
        let endpoint: Session.Endpoint
        switch target {
        case .discovered(let phone): endpoint = .service(phone.endpoint, pinnedTo: phone.interface)
        case .manual(let host, let port): endpoint = .hostPort(host: host, port: port)
        }
        let known: String? = { if case .discovered(let phone) = target { return phone.deviceId } else { return nil } }()
        start(Session(endpoint: endpoint, knownDeviceId: known, clientId: clientId,
                      identity: identity, pinnedPhone: nil, pinStore: pins,
                      onPinEstablished: { [weak self] record in self?.mirrorIdentityPin(record: record) },
                      connectTimeout: connectTimeout, pairingTimeout: pairingTimeout),
              policy: .allowed)
    }

    /// `--connect host:port`: the test entry point. The session may pair (the
    /// phone's Allow is the only step) or reconnect with a pin.
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
                      clientId: clientId, identity: identity, pinnedPhone: pins.record(for: ref.id),
                      pinStore: pins,
                      onPinEstablished: { [weak self] record in self?.mirrorIdentityPin(record: record) },
                      connectTimeout: connectTimeout, pairingTimeout: pairingTimeout), policy: .allowed)
    }

    // MARK: Session events

    private func handle(_ event: SessionEvent) {
        switch event {
        case .state(let state, let detail):
            switch state {
            case .failed(let reason):
                stopClipboardSync()
                apkInstaller.connectionLost()
                dropSender.connectionLost()
                fsClient?.connectionLost()
                clipImageBuffer.discard()
                shareInbox.connectionLost()
                nowPlaying.clear()
                // The TLS pin said the dialed phone is not the one this Mac
                // pinned (a foreign phone took the cached address): keep the
                // pin record — re-pair overturns it (§7) — and drop the stale
                // cache entry, as v1's identity mismatch did (C10).
                if reason == "pin-mismatch", let id = session?.knownDeviceId, !id.isEmpty {
                    Log.session.notice("dropping cached address for \(id, privacy: .public) (the TLS pin refuses it)")
                    cache.forget(deviceId: id)
                }
                attemptEnded(reason: detail ?? "closed")
            case .closed:
                stopClipboardSync()
                apkInstaller.connectionLost()
                dropSender.connectionLost()
                fsClient?.connectionLost()
                clipImageBuffer.discard()
                shareInbox.connectionLost()
                nowPlaying.clear()
            default:
                break
            }
        case .clipboard(let text):
            clipboardSync?.receive(text)
        case .dropProgress(let id, let bytes):
            dropSender.progress(id: id, bytes: bytes)
            syncDropPill()
        case .dropResult(let result):
            dropSender.result(result)
            syncDropPill()
        case .clipImageBegin(let id, let mime, let size):
            clipImageBuffer.begin(id: id, mime: mime, size: size)
        case .clipImageData(let id, let bytes):
            clipImageBuffer.data(id: id, bytes: bytes)
        case .clipImageEnd(let id, let size, let sha256):
            if let (data, mime) = clipImageBuffer.end(id: id, size: size, sha256: sha256) {
                Log.app.notice("clip.image: image from phone (\(data.count) bytes, \(mime, privacy: .public))")
                clipboardSync?.receiveImage(data, mime: mime)
            }
        case .clipImageAbort(let id):
            clipImageBuffer.discard()
        case .apkProgress(let id, let bytes):
            apkInstaller.progress(id: id, bytes: bytes)
        case .apkResult(let result):
            apkInstaller.result(result)
        case .shareText(let text):
            shareInbox.phoneName = shareName()
            shareInbox.phoneId = session?.phone?.id ?? ""
            shareInbox.text(text)
        case .shareFileBegin(let id, let name, let mime):
            shareInbox.phoneName = shareName()
            shareInbox.phoneId = session?.phone?.id ?? ""
            shareInbox.fileBegin(id: id, name: name, mime: mime)
        case .shareFileData(let id, let bytes):
            shareInbox.fileData(id: id, bytes: bytes)
        case .shareFileEnd(let id, let size, let sha256):
            shareInbox.fileEnd(id: id, size: size, sha256: sha256)
        case .shareFileAbort(let id):
            shareInbox.fileAbort(id: id)        case .ready(let info, _, let address):
            ready(info, address: address)
        case .fsItems(let id, let page, let items):
            fsClient?.items(id: id, page: page, items: items)
        case .fsItem(let id, let item):
            fsClient?.item(id: id, item: item)
        case .fsData(let id, let bytes):
            fsClient?.data(id: id, bytes: bytes)
        case .fsReadEnd(let id, let size, let sha256):
            fsClient?.readEnd(id: id, size: size, sha256: sha256)
        case .fsError(let id, let code, let message):
            fsClient?.failure(id: id, code: code, message: message)
        case .notifyState(let on):
            Log.app.notice("phone notify \(on ? "on" : "off", privacy: .public)")
            if !on { nowPlaying.clear() }
        case .notifyPosted(let id, let pkg, let when, let title, let text):
            let ref = link.phone?.id.isEmpty == false ? link.phone
                : session?.phone.map { PhoneRef(id: $0.id, name: $0.name, model: $0.model) }
            guard let phone = ref, !phone.id.isEmpty else { break }
            notifyCenter.post(
                PhoneNotification(id: id, pkg: pkg, when: when, title: title, text: text),
                phoneId: phone.id,
                phoneName: displayName(for: phone, fallback: "your phone"),
                labelFor: { [weak self] in self?.labelFor($0) ?? nil },
            )
        case .notifyRemoved(let id):
            notifyCenter.remove(id: id)
        case .mediaState(let media):
            nowPlaying.apply(media)
        case .apps(let list):
            appsReceived(list)
        case .icon(let pkg, let png, let fg, let bg, let mono):
            if let image = NSImage(data: png) {
                icons[pkg] = image
                windows.setIcon(image, pkg: pkg)
                if let id = link.phone?.id { IconCache.shared.store(png, fg: fg, bg: bg, mono: mono, pkg: pkg, deviceId: id) }
                // A layered icon lands only when it decodes whole; without
                // layers the entry is cleared, so a flat icon from a phone
                // that predates layers replaces a stale one.
                iconLayers[pkg] = Self.glassLayers(fg: fg, bg: bg, mono: mono)
            } else {
                missingIcons.insert(pkg)
            }
            runDockHooks()
            recheckOpenWindows()
        case .phoneState(let locked, let battery, let charging):
            status = PhoneStatus(locked: locked, battery: battery, charging: charging)
            if let id = link.phone?.id { batteryMemory.record(deviceId: id, level: battery, charging: charging) }
        case .audioState(let on, _):
            audioOn = on
        case .windowClosed:
            syncAudio()
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
            if code == "nothing_to_continue" {
                // The window never opened: it goes away, the notice is what stays.
                windows.closeFailedHandoff(stream: stream)
                showTransient("Nothing to continue.")
            } else if code == "launch_failed" || (stream != 0 && code == "no_stream") {
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

    /// Plain-text clipboard sync for the session that just became ready — plus
    /// the clipboard-image direction (docs/design/dragdrop.md). The send paths
    /// are bound to that session, so a later session never gets its text.
    private func startClipboardSync(on session: Session) {
        stopClipboardSync()
        let defaults = profile.defaults
        let sync = ClipboardSync(pasteboard: SystemPasteboard(),
                                 isEnabled: { ClipboardSync.isEnabled(in: defaults) },
                                 send: { [weak session] text in session?.sendClipboard(text) },
                                 sendImage: { [weak self, weak session] data, mime in
            guard let session else { return }
            // The poll runs on the main run loop; the frame encodes stay off it.
            Task.detached(priority: .userInitiated) {
                ClipImageSend.run(data, mime: mime, session: session)
            }
        },
                                 clock: ClipboardSync.timerClock)
        sync.start()
        clipboardSync = sync
    }

    private func stopClipboardSync() {
        clipboardSync?.stop()
        clipboardSync = nil
    }

    // MARK: Notification share (docs/design/notify.md)

    /// A Mac banner click (ROADMAP D2): the per-phone "When I click a phone
    /// notification" choice decides where the notification's own action runs.
    /// Open on Mac raises (or opens) the app's window and runs the action on
    /// that display; Open on phone runs it on display 0 with no Mac window; Do
    /// nothing only dismisses the banner. Unknown packages are refused politely
    /// (the phone's app list is the source of truth).
    func notificationClicked(_ click: NotifyClick) {
        guard link.isOnline else { return }
        let target = NotifyClickTarget.stored(deviceId: click.phoneId, defaults: profile.defaults)
        var stream: UInt32?
        for step in NotifyClickPlan.steps(for: target) {
            switch step {
            case .openWindow:
                guard let app = windows.appsByPkg[click.pkg] ?? apps.first(where: { $0.pkg == click.pkg }) else {
                    showTransient("That app isn't openable from the Mac.")
                    return
                }
                stream = windows.openOrRaiseApp(pkg: app.pkg, activity: app.activity)
            case .send(let destination):
                // The window is already open: an older phone that ignores
                // notify.open keeps today's behaviour there.
                session?.openNotification(id: click.id, target: destination,
                                          stream: destination == .window ? stream : nil)
            }
        }
    }

    /// The per-device opt-in toggle changed (Settings → Devices).
    func notifySettingChanged(deviceId: String, on: Bool) {
        profile.defaults.set(on, forKey: NotifyToggle.key(deviceId: deviceId))
        if link.phone?.id == deviceId { session?.enableNotifications(on) }
        if !on, link.phone?.id == deviceId { nowPlaying.clear() }
    }

    /// The click choice changed; it is read on every click, so a live session
    /// needs no message (docs/design/notify.md).
    func notifyClickSettingChanged(deviceId: String, target: NotifyClickTarget) {
        profile.defaults.set(target.rawValue, forKey: NotifyClickTarget.key(deviceId: deviceId))
    }

    private func labelFor(_ pkg: String) -> String? {
        windows.appsByPkg[pkg]?.label ?? apps.first { $0.pkg == pkg }?.label
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
        layerRefresh.reset()
        let hadWindows = !windows.openStreams.isEmpty
        windows.phone = info
        // Every window title carries the display name from here on.
        windows.setPhoneName(displayName(for: ref))
        status = PhoneStatus(locked: info.locked, battery: info.battery, charging: info.charging ?? false)
        if let battery = info.battery {
            batteryMemory.record(deviceId: info.id, level: battery, charging: info.charging ?? false)
        }
        if apps.isEmpty || link.phone?.id != info.id { resetPhoneData(for: ref) }
        send(.welcome(ref))
        everOnline = true
        if let session { startClipboardSync(on: session) }
        session?.requestApps()
        // The per-phone toggle: a freshly ready session learns the opt-in now
        // (and after every reconnect, since the phone starts with gates off).
        if let id = info.id.isEmpty ? nil : info.id, NotifyToggle.isEnabled(deviceId: id, defaults: profile.defaults) {
            session?.enableNotifications(true)
        }
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
            applyAutoOpen(options)
        }
        if let request = pendingOpen, request.deviceId == info.id {
            pendingOpen = nil
            windows.openApp(pkg: request.pkg)
        }
        openPendingLink(readyPhone: info.id)
        openPendingDock(readyPhone: info.id)
        installPendingApk(readyPhone: info.id)
        openPendingPhoneWindow(readyPhone: info.id)
        dropPendingFiles(readyPhone: info.id)
        transientBanner = nil
        syncAudio()
        startFsDebug()
    }

    /// `--debug-fs-script`: once the session is ready, run the script's
    /// list/stat/read steps in order (results on stderr, see FsDebug.swift).
    private func startFsDebug() {
        guard fsDebug == nil, let actions = fsScriptActions, let session else { return }
        let client = FsClient(channel: session)
        fsClient = client
        let driver = FsDebugDriver(actions: actions, client: client)
        fsDebug = driver
        driver.run()
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
                loadCachedLayers(app.pkg, deviceId: id)
            } else {
                session?.requestIcon(pkg: app.pkg)
            }
        }
        // A cached icon without layers may predate them: ask once per
        // connection, so a phone that has layers catches the glass look up.
        if GlassIconsSetting.isEnabled(in: profile.defaults), let id = link.phone?.id {
            for app in list where iconLayers[app.pkg] == nil && icons[app.pkg] != nil && IconCache.shared.hasLayers(pkg: app.pkg, deviceId: id) == false {
                if layerRefresh.allow(pkg: app.pkg) { session?.requestIcon(pkg: app.pkg) }
            }
        }
        if let ref = link.phone {
            spotlight.index(apps: list, deviceId: ref.id, phoneName: displayName(for: ref),
                            iconData: { IconCache.shared.loadData(pkg: $0, deviceId: ref.id) })
            dockApps.reconcile(deviceId: ref.id, apps: list, phoneName: displayName(for: ref),
                               keep: dockPkgsOfOpenWindows)
        }
        runDockHooks()
        recheckOpenWindows()
        // An open-app intent needs the live list (a fresh profile has no cache).
        runPendingDebugIntents(immediateOnly: false)
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

    /// Arms a `--debug-input-script`; the error text when the script is unusable.
    private func armDebugInput(_ path: String, phoneOnly: Bool = false) -> String? {
        debugInput?.cancel()
        do {
            debugInput = try DebugInputDriver(scriptPath: path)
        } catch {
            debugInput = nil
            return "debug-input-script \(path): \(error)"
        }
        // The notify/media actions reach the same handlers a banner click
        // and a Now Playing control do. The driver runs on the main thread.
        debugInput?.notifyClick = { [weak self] id in
            MainActor.assumeIsolated { self?.notifyCenter.performOpen(id: id) ?? false }
        }
        debugInput?.mediaCommand = { [weak self] action in
            MainActor.assumeIsolated { self?.nowPlaying.perform(action) }
        }
        // The dockapps action writes the setting the way Settings'
        // @AppStorage does, then calls the same handler its onChange does.
        debugInput?.dockApps = { [weak self] on in
            MainActor.assumeIsolated { self?.setShowAppsInDock(on) }
        }
        debugInput?.arm(phoneOnly: phoneOnly)
        return nil
    }

    /// `--debug-control` (DebugControl.swift): the e2e checks that share this
    /// running app reset it between them and open their windows through it.
    /// Returns nil when the command ran, else why not.
    private func performDebugControl(_ command: String, _ arguments: [String]) -> String? {
        switch command {
        case "reset":
            debugInput?.cancel()
            debugInput = nil
            windows.resetForNextCheck(forgetPrefs: arguments == ["prefs"])
            audio.statsFile = nil
            return nil
        case "open":
            guard link.isOnline else { return "not online" }
            let check = LaunchOptions.parse(["PocketDeck"] + arguments)
            windows.floatWindows = check.floatWindows
            windows.chromeStateFile = check.debugChromeState.map { URL(fileURLWithPath: $0) }
            audio.statsFile = check.audioStatsFile
            // A phone-mode phase's script belongs to the phone window: the
            // shared app can reopen an app window in the same breath, and that
            // window's video size may arrive first (it did in the VM).
            let phoneOnly = check.openPhone && check.openPackages.isEmpty
            if let path = check.debugInputScript, let error = armDebugInput(path, phoneOnly: phoneOnly) { return error }
            applyAutoOpen(check)
            return nil
        default:
            return "unknown command \(command)"
        }
    }

    private func applyAutoOpen(_ options: LaunchOptions) {
        for pkg in options.openPackages { windows.openApp(pkg: pkg) }
        if options.openPhone { windows.openPhoneWindow() }
        if options.continueOnMac { windows.openHandoffWindow() }
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
        // Closing a stream window like the person does (⌘W or the close button):
        // the window goes through windowWillClose, so the Dock identity follows.
        for close in options.closeStreams {
            DispatchQueue.main.asyncAfter(deadline: .now() + close.after) { [weak self] in
                MainActor.assumeIsolated { self?.windows.controller(for: close.stream)?.window?.performClose(nil) }
            }
        }
    }

    // MARK: QR pairing

    /// Show a fresh one-time secret as a QR (c/n/f/s) and probe the phones we
    /// can see for it (every 2 s round, each phone at most every 4 s, for
    /// 5 minutes; review R2).
    func startQRPairing(presentAfterLaunch: Bool = false) {
        if let qr, !qr.expired { sheet = .qr; return }
        stopQR()
        guard let payload = PairingQRPayload.random(clientId: clientId, name: ClientIdentity.name,
                                                    macFingerprintHex: macFingerprintHex(in: identity)) else {
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
        let paired = Set(rememberedPhones.map(\.id).filter { pins.record(for: $0) != nil })
        let busy = Set(qrProbes.map(\.id))
        let probeable = DialPolicy.mayDialDiscovered(profile) ? discovered : []
        for phone in QRProbePlanner.candidates(phones: probeable, paired: paired, active: busy,
                                                lastProbe: qrLastProbe, busyUntil: qrBusyUntil, now: now) {
            startProbe(id: phone.deviceId, endpoint: .service(phone.endpoint, pinnedTo: phone.interface), deviceId: phone.deviceId,
                       secret: state.payload.secret, now: now)
        }
        if let connect = options.connect {
            let id = "\(connect.host):\(connect.port)"
            let due = qrLastProbe[id].map { now.timeIntervalSince($0) >= QRProbePlanner.probeInterval } ?? true
            if !busy.contains(id), due {
                startProbe(id: id, endpoint: .hostPort(host: connect.host, port: connect.port), deviceId: nil,
                           secret: state.payload.secret, now: now)
            }
        }
    }

    private func startProbe(id: String, endpoint: Session.Endpoint, deviceId: String?, secret: Data, now: Date) {
        // R2: the QR probe opens the TLS pairing channel and carries the
        // sheet's one-time secret; a phone that scanned the QR pins us by `f`
        // and proves `s` with `pair.qr`.
        let probe = Session(endpoint: endpoint, knownDeviceId: deviceId, clientId: clientId,
                            identity: identity, pinnedPhone: nil, pinStore: pins,
                            onPinEstablished: { [weak self] record in self?.mirrorIdentityPin(record: record) })
        probe.pairingPolicy = .probe
        probe.useQRSecret(secret)
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
            if let payload = PairingQRPayload.random(clientId: clientId, name: ClientIdentity.name,
                                                     macFingerprintHex: macFingerprintHex(in: identity)) {
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
        case "devices-rename":
            // The Settings → Devices → Rename dialog, staged for the screenshot.
            deck(.online(ref))
            renamingDeviceId = ref.id
            previewRenameText = "Multipass"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                MainActor.assumeIsolated { self?.settingsRequest += 1 }
            }
        default:
            FileHandle.standardError.write(Data("--preview \(name): unknown state\n".utf8))
            exit(2)
        }
    }
}
