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
    /// nil when the phone's `state` carries no `dnd` (old phone) or none arrived yet.
    var dnd: PhoneDndMode? = nil
    /// nil when the phone's `state` carries no `ringer` (old phone).
    var ringer: PhoneRingerMode? = nil
    /// STREAM_MUSIC's level and maximum; both nil on a phone that cannot read them.
    var volume: Int? = nil
    var volumeMax: Int? = nil
    /// Display 0's power state; nil reads as on (nothing to overlay).
    var screen: PhoneScreen? = nil
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
    /// What the menu bar's media row shows (a mirror of `nowPlaying`, which is
    /// not observed so test hooks can replace it).
    private(set) var mediaNow: MediaState?
    private(set) var mediaSessions: [MediaSessionRow] = []
    private(set) var mediaArt: NSImage?
    /// "Show phone files in Finder" (docs/design/files.md §1): the setting, the
    /// one domain per profile, and its reconnect/disconnect on session changes.
    @ObservationIgnored lazy var filesDomain: FilesDomainController = {
        // The host e2e presents the domain as already added (no File Provider
        // on the person's Mac) and the bundle as carrying its extension: the
        // path a relaunch takes with Finder files already on.
        let seen = options.filesDomainSeen
        let socket = seen.map {
            URL(fileURLWithPath: $0, isDirectory: true)
                .appendingPathComponent(FilesSocket.fileName(profile: profile)).path
        }
        return FilesDomainController(
            profile: profile,
            manager: seen == nil ? nil : FilesDomainSeenManager(identifier: FilesDomain.identifier(profile: profile)),
            socketPath: socket,
            supported: seen == nil ? nil : true)
    }()

    // MARK: Published state

    private(set) var machine = LinkMachine()
    var link: Link { machine.link }
    private(set) var transientBanner: Banner?
    /// Packages each phone's notifications came from this session (Settings ›
    /// Devices "Muted apps"); package names only, never any text.
    private(set) var notifySeen: [String: Set<String>] = [:]
    /// Phones whose listener access the Mac was told is missing
    /// (`notify.state {on:false, reason:"no_access"}`): the Devices row says how
    /// to fix it, and a later grant clears it (docs/design/notify.md).
    private(set) var notifyNoAccessPhones: Set<String> = []
    /// The menu bar's "Live on <phone>" rows (docs/design/notify.md, 2b).
    private(set) var liveNotifications: [NotifyLiveItem] = []
    /// Ticks once a second while a live row exists, so an open menu bar shows a
    /// running chronometer instead of the time it was opened.
    private(set) var liveTick: Date = Date()
    @ObservationIgnored private var liveTicker: Timer?
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

    /// Settings ▸ Phones ▸ Rename: store the trimmed nickname (empty clears
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
        // The Finder location carries the phone's name too (design "Fixes
        // 10-20"); a rename updates the mounted domain in place.
        filesDomain.refreshDisplayName()
        guard let phone = remembered.phone(id: deviceId)?.ref else { return }
        let name = displayName(for: phone)
        if link.phone?.id == deviceId { windows.setPhoneName(name) }
        // The app list this Mac has for the phone: live for the current
        // session's phone, the cached one otherwise.
        let apps = link.phone?.id == deviceId && appsLoaded ? self.apps : appsCache.load(deviceId: deviceId)
        guard !apps.isEmpty else { return }
        spotlight.index(apps: apps, deviceId: deviceId, phoneName: name,
                        iconData: { IconCache.shared.renderedPNG(pkg: $0, deviceId: deviceId, px: 256) })
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
    /// The adaptive layers of the icons that have them.
    private(set) var iconLayers: [String: AppIconLayers] = [:]
    /// The shared renderer's icon for the Deck tile (docs/design/dock.md §Icons).
    private(set) var deckIcons: [String: NSImage] = [:]
    /// Packages the phone answered with no icon at all.
    private(set) var missingIcons: Set<String> = []
    /// The one re-request a flat cached icon gets per connection.
    private let layerRefresh = IconLayerRefresh()
    /// The `px` sizes asked for but not answered yet, per package: a reply does
    /// not echo `px`, so the request order says which size class it fills.
    private var iconRequests: [String: [Int]] = [:]
    /// The Dock's 1296 px icon was asked once this connection (the shim waits
    /// for it the first time, docs/design/dock.md §Icons).
    private var dockIconAsked: Set<String> = []
    /// "Add to Dock" presses waiting for the Dock's 1296 px reply, keyed by
    /// `{deviceId}/{pkg}`.
    private var pendingDockAdds: [String: (deviceId: String, pkg: String, label: String)] = [:]
    private(set) var status: PhoneStatus?
    /// `ring.state` from the phone: a ring this Mac started is still playing.
    private(set) var ringing = false
    /// The stored Focus filter values (docs/design/focus.md).
    private let focusStore: FocusStore
    private(set) var focusValues = FocusFilterValues()
    /// This phone's DND intent memory (docs/specs/controls.md): the value it
    /// received last, so a reconnect only sends what changed while apart.
    private let dndIntent: ControlIntentRecorder
    /// One reconcile per connection: the first `state` applies what is new.
    private var focusReconciled = false
    /// `--debug-dnd on|off`, run when the first state shows the phone's support.
    private var pendingDebugDnd: Bool?
    private(set) var pairingSucceeded = false
    /// When the pairing sheet went up: the 20 s hint counts from here (PAIR-6).
    private(set) var pairingStartedAt: Date?
    private(set) var qr: QRPairingState?
    private(set) var welcomeSeen: Bool
    private(set) var searchedLong = false
    private(set) var browseDenied = false

    var sheet: DeckSheet?
    /// A sheet requested before the Deck window exists (launch hooks, previews).
    private(set) var pendingSheet: DeckSheet?

    /// Bumped to open the Settings window (previews stage the phone screenshots;
    /// the gear, ⌘, and the panel's Settings… row are the real entry points).
    /// Read by DeckRoot.
    private(set) var settingsRequest = 0
    /// The Settings window self-reports what it renders when the e2e asks
    /// (`settings-report`): a debug read of the real view's state.
    private(set) var settingsReportRequest = 0
    var settingsReportPath: String?
    /// Bumped by `settings-add` (setup): the sidebar runs its Add Phone…
    /// action, so the check sees the sheet open and the selection stay put.
    private(set) var settingsAddRequest = 0
    /// `settings-select` (setup): the sidebar runs its choose transition for
    /// this page, as a click on the row does.
    private(set) var settingsRevealRequest: SettingsReveal?
    struct SettingsReveal: Equatable {
        let selection: SettingsSelection
        let token: Int
    }
    private var settingsRevealToken = 0

    /// The panel's Settings… row: the Deck's own scene opener (the responder
    /// action alone does nothing while the app is not active).
    func openSettingsWindow() {
        settingsRequest += 1
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    /// The Deck popover's open request: bumped by the e2e's `deckpanel` verb
    /// (the status pill is a toolbar item, unreachable without a pointer in a
    /// quiet run). PhoneDeckView reads it and presents the popover.
    private(set) var deckPanelRequest = 0

    func openDeckPanel() {
        deckPanelRequest += 1
    }

    /// A rail letter the e2e asked to click (`deck-rail`), with a token so the
    /// same letter can be picked twice. AppGrid reads it and scrolls exactly as
    /// the rail's own click does.
    struct DeckRailRequest: Equatable {
        let letter: String
        let token: Int
    }
    private(set) var deckRailRequest: DeckRailRequest?
    private var deckRailToken = 0

    /// The phone being renamed right now: Settings ▸ Phones ▸ Rename… presents
    /// its dialog for this device; a preview stages the whole state.
    private(set) var renamingDeviceId: String?
    /// The phone whose Forget confirmation is up (one at a time, like Rename).
    private(set) var forgettingDeviceId: String?
    /// Preview only: the rename field's staged text (screenshots, never stored).
    private(set) var previewRenameText: String?

    func presentPendingSheet() {
        guard let pending = pendingSheet else { return }
        pendingSheet = nil
        sheet = pending
    }

    /// Settings ▸ Phones ▸ Rename…: the dialog for this phone is presented
    /// (and dismissed) in DevicesSettings.
    func beginRename(_ phone: RememberedPhone) {
        renamingDeviceId = phone.id
        previewRenameText = nil
    }

    func endRename() {
        renamingDeviceId = nil
        previewRenameText = nil
    }

    /// Settings ▸ Phones ▸ Forget This Phone…: the confirmation names this
    /// phone; nothing is removed until the person confirms.
    func beginForget(_ phone: RememberedPhone) { forgettingDeviceId = phone.id }
    func endForget() { forgettingDeviceId = nil }
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
    /// The 120 s wait's clock (FILES-16).
    private var pendingApkTask: Task<Void, Never>?
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
    /// The FsClient the Finder bridge answers through. Separate from the debug
    /// client, but fed the same session events (ConnectionController routes
    /// every fs.* reply to both).
    private var filesBridgeClient: FsClient?
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
    /// Preview only: what the notification controls draw for a staged phone
    /// (`--preview devices-…`), which has no session and no stored settings.
    struct PreviewNotify {
        var enabled: Bool
        var muted: Set<String>
        var seen: Set<String>
        var click: NotifyClickTarget = .mac
    }
    private(set) var previewNotify: [String: PreviewNotify] = [:]
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
        focusStore = FocusStore(profile: profile)
        focusValues = focusStore.load()
        dndIntent = ControlIntentRecorder(store: ControlIntentStore(defaults: profile.defaults, control: .dnd))
        dockApps = DockApps(folder: DockApps.defaultFolder(profile: profile, override: options.dockDirectory),
                            profile: profile, bindDelay: options.dockBindDelay ?? 0)
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
        // The drop pill has one owner: the sender reports every phase, the
        // timeout included, and the windows only render what they are told.
        dropSender.onPhase = { [weak self] _ in
            MainActor.assumeIsolated { self?.syncDropPill() }
        }
        // The waiting install's Cancel drops the queued file too (FILES-16).
        apkInstaller.onWaitingCancelled = { [weak self] in
            MainActor.assumeIsolated { self?.cancelPendingApk() }
        }
        densityOverrides = windows.densityOverrides
        if options.debugNotifyDenied {
            notifyCenter.debugAuthorization = .denied
            notifyAuthorization = .denied
        } else {
            checkNotificationAuthorization()
        }
        // Notification sharing (docs/design/notify.md): the router owns the UN
        // delegate and clicks; share notifications still route to their actions.
        // The same `--share-log` file records what both halves would have shown.
        let shareLog = options.shareLog.map { URL(fileURLWithPath: $0) }
        notifyCenter.log = shareLog
        notifyCenter.onOpen = { [weak self] click in
            MainActor.assumeIsolated { self?.notificationClicked(click) }
        }
        notifyCenter.onAction = { [weak self] click, index, text in
            MainActor.assumeIsolated { self?.notifyActionPressed(click, index: index, text: text) }
        }
        notifyCenter.onDismiss = { [weak self] click in
            MainActor.assumeIsolated { self?.notifyDismissed(click) }
        }
        notifyCenter.onLiveChange = { [weak self] items in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.liveNotifications = items
                self.updateLiveTicker()
            }
        }
        nowPlaying.log = shareLog
        nowPlaying.onCommand = { [weak self] command in
            MainActor.assumeIsolated { self?.session?.mediaCommand(command, key: self?.nowPlaying.current?.key) }
        }
        nowPlaying.onChoose = { [weak self] key in
            MainActor.assumeIsolated { self?.session?.mediaChoose(key) }
        }
        nowPlaying.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.refreshMedia() }
        }
        mcp.configure(profile: profile, forced: options.mcpEnable)
        mcp.hostProvider = { [weak self] in self.map { MCPToolHost(controller: $0) } }
        // A phone-side change has to reach the Finder UI even when no extension
        // process is running, and a replicated extension may only be signalled
        // through its working set (NSFileProviderManager.h, design "S5 round 3").
        FilesBridge.shared.signalWorkingSet = { [weak self] in
            MainActor.assumeIsolated { self?.filesDomain.signalWorkingSet() }
        }
    }

    /// Start device audio when online with ≥1 window; stop otherwise.
    /// Mac-side gain only — the phone is silenced by its submix routing.
    func syncAudio() {
        guard link.isOnline, !windows.openStreams.isEmpty else {
            if audioStarted {
                audioStarted = false
                session?.stopAudio()
                audio.stop()
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
        armFocusDebug()
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
        nowPlaying.clear()
        notifyCenter.clearAll()
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

    /// Settings ▸ Phones ▸ Use This Phone.
    func use(_ phone: RememberedPhone) {
        guard link.phone?.id != phone.id else { return }
        // The §3 mirror follows the phone in use: it is that phone's record
        // from here on, and the TLS layer checks the record itself.
        mirrorIdentityPin(deviceId: phone.id)
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
        let next = IdentityPinMirror.pinAfterForget(current: identity.pin,
                                                    records: pins.all, forgotten: deviceId)
        guard next != identity.pin else { return }
        identity.pin = next
        identityFile.save(identity)
    }

    func openApp(_ app: AppInfo) {
        guard link.isOnline else { return }
        windows.openOrRaise(pkg: app.pkg, activity: app.activity)
    }

    func openPhoneWindow() {
        guard link.isOnline else { return }
        windows.openPhoneWindow()
    }

    /// "Move Phone App to Mac" (docs/ROADMAP.md #9): a window for the app in the
    /// foreground on the phone's screen. The phone answers with `window.opened`
    /// (and the video) for the stream, or `nothing_to_continue` — which shows
    /// as the transient banner.
    func continueOnMac() {
        guard link.isOnline else { return }
        windows.openHandoffWindow()
    }

    func openFromSpotlight(_ request: SpotlightOpenRequest) {
        if link.isOnline, link.phone?.id == request.deviceId {
            windows.openOrRaise(pkg: request.pkg)
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
        guard dockIconReady(pkg: app.pkg, deviceId: phone.id) else {
            // The shim's icon is drawn once, from the Dock's size class: wait
            // for the phone's 1296 px reply instead of baking the Deck's flat.
            pendingDockAdds["\(phone.id)/\(app.pkg)"] = (phone.id, app.pkg, app.label)
            requestDockIcon(app.pkg)
            return
        }
        if dockApps.add(deviceId: phone.id, pkg: app.pkg, label: app.label, phoneName: displayName(for: phone),
                        launch: true, pinned: true) == nil {
            showTransient("Couldn't add \(app.label) to the Dock.")
        }
        dockRevision += 1
    }

    /// "Add to Dock" presses waiting for the Dock's 1296 px reply.
    private func runPendingDockAdds() {
        guard let phone = link.phone, !pendingDockAdds.isEmpty else { return }
        for key in pendingDockAdds.keys.sorted() {
            guard let add = pendingDockAdds[key], add.deviceId == phone.id,
                  dockIconReady(pkg: add.pkg, deviceId: add.deviceId) else { continue }
            pendingDockAdds[key] = nil
            if dockApps.add(deviceId: add.deviceId, pkg: add.pkg, label: add.label,
                            phoneName: displayName(for: phone), launch: true, pinned: true) == nil {
                showTransient("Couldn't add \(add.label) to the Dock.")
            }
            dockRevision += 1
        }
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
            dockApps.bind(pid: pid, stream: windows.openOrRaise(pkg: pkg).stream, pkg: pkg)
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
        dockApps.bind(pid: pending.pid, stream: windows.openOrRaise(pkg: pending.pkg).stream, pkg: pending.pkg)
    }

    /// Test hooks: once the app list (and the app's icon) is in.
    private func runDockHooks() {
        guard dockHooksPending, let phone = link.phone, appsLoaded else { return }
        if let pkg = options.dockAdd {
            guard IconCache.shared.loadData(pkg: pkg, deviceId: phone.id) != nil || missingIcons.contains(pkg) else { return }
            guard dockIconReady(pkg: pkg, deviceId: phone.id) else {
                requestDockIcon(pkg)
                return
            }
            let label = apps.first { $0.pkg == pkg }?.label ?? pkg
            dockApps.add(deviceId: phone.id, pkg: pkg, label: label, phoneName: displayName(for: phone),
                         launch: false, pinned: true)
        }
        if let pkg = options.dockRemove { dockApps.remove(deviceId: phone.id, pkg: pkg) }
        // `--set-nickname`: the rename a person does in Settings ▸ Phones ▸
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
        if dockApps.isRunning(deviceId: phone.id, pkg: pkg) { return }
        let state = iconState(pkg: pkg, deviceId: phone.id)
        // The Dock draws one 1024 px icon from the phone's 1296 px layers: ask
        // for them once and wait (a flat icon, or a phone that predates `px`,
        // needs no wait). docs/design/dock.md §Icons.
        if state == .cached, !dockIconReady(pkg: pkg, deviceId: phone.id) {
            requestDockIcon(pkg)
            return
        }
        let info = dockApps.shimIconInfo(deviceId: phone.id, pkg: pkg)
        let decision = DockFollow.decide(
            settingOn: showAppsInDock, shimBinary: dockApps.isAvailable, phoneKnown: true,
            shimExists: dockApps.hasShim(deviceId: phone.id, pkg: pkg),
            shimRunning: false,
            shimHasIcon: dockApps.shimHasIcon(deviceId: phone.id, pkg: pkg),
            shimIconVersion: info?.version ?? 0, shimIconLayers: info?.layers ?? false,
            hasLayers: IconCache.shared.hasLayers(pkg: pkg, deviceId: phone.id),
            icon: state)
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
                                 profile: self.profile, hostPath: Bundle.main.bundleURL.path),
                    bind: stream, launched: launched)
            }
        }
    }

    /// Runs the launch and clears the in-flight key and binds the pid when it is up.
    private func bindWhenDockCleared(deviceId: String, pkg: String, stream: UInt32,
                                     work: @escaping (_ launched: @escaping (Int?) -> Void) -> Void) {
        let key = "\(deviceId)/\(pkg)"
        dockEstablishing.insert(key)
        let start = { [weak self] in
            guard let self else { return }
            work { pid in
                MainActor.assumeIsolated {
                    self.dockLaunchFinished(stream: stream, deviceId: deviceId, pkg: pkg, pid: pid)
                }
            }
        }
        // e2e: hold the build and launch back, so it lands after a window that
        // closes in the meantime (the load-dependent race, made deterministic).
        if let delay = options.dockLaunchDelay, delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { start() }
        } else {
            start()
        }
    }

    /// The automatic launch finished. A pid for a window that is no longer open
    /// must quit at once: nothing would ever close that shim again, and it would
    /// outlive its window and the app (docs/design/dock.md §Lifecycle).
    private func dockLaunchFinished(stream: UInt32, deviceId: String, pkg: String, pid: Int?) {
        dockEstablishing.remove("\(deviceId)/\(pkg)")
        let landing = DockLaunch.landing(
            pid: pid,
            windowOpen: windows.openAppWindows.contains { $0.stream == stream },
            settingOn: showAppsInDock, pinned: dockApps.isPinned(deviceId: deviceId, pkg: pkg))
        switch landing {
        case .nothing:
            break
        case .bind:
            if let pid { dockApps.bind(pid: pid, stream: stream, pkg: pkg) }
        case .quitWindowClosed, .quitSettingOff, .quitShuttingDown:
            if let pid { dockApps.quit(pid: pid) }
        }
        recheckOpenWindows()
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

    /// Whether the Dock's size class has an answer. Every shim icon is drawn
    /// from the phone's 1296 px reply — its layers, or the 864 px flat a flat
    /// icon covers its tile with — so a flat-only app asks too: the Deck slot's
    /// 288 px flat would be a 2.9× upscale at 1024 (docs/design/dock.md §Icons).
    /// An app the phone says it has no icon for is ready without one.
    private func dockIconReady(pkg: String, deviceId: String) -> Bool {
        if missingIcons.contains(pkg) { return true }
        return IconCache.shared.layersAnswered(pkg: pkg, deviceId: deviceId, sizeClass: .dock)
    }

    /// Asks for the Dock's 1296 px icon once per connection.
    private func requestDockIcon(_ pkg: String) {
        if dockIconAsked.insert(pkg).inserted { requestIcon(pkg, px: IconSizeClass.dock.layerPx) }
    }

    /// Asks the phone for one icon at `px`, remembering the size so the reply
    /// lands in the right cache slot.
    private func requestIcon(_ pkg: String, px: Int) {
        guard let session else { return }
        iconRequests[pkg, default: []].append(px)
        session.requestIcon(pkg: pkg, px: px)
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
            windows.openOrRaise(pkg: pkg)
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

    // MARK: Focus and Do Not Disturb (docs/design/focus.md)

    /// The mode the phone last reported; nil when it has no `dnd` (old phone)
    /// or no `state` arrived yet.
    var phoneDnd: PhoneDndMode? { status?.dnd }

    /// The menu item is enabled only for a connected phone that sends `dnd`.
    var canSetPhoneDnd: Bool { link.isOnline && phoneDnd != nil }

    /// The ringer mode the phone last reported; nil when it cannot set it.
    var phoneRinger: PhoneRingerMode? { status?.ringer }

    /// A control can change the ringer only on a live phone that reports it and
    /// while DND is off: on API 36 a ringer change can end an "alarms" DND, and
    /// the phone side refuses that write as well (docs/design/controls.md).
    var canSetPhoneRinger: Bool { link.isOnline && phoneRinger != nil && phoneDnd?.isOn != true }

    /// `phone.ringer` (docs/PROTOCOL.md "Ringer"): one mode, never a volume.
    @discardableResult
    func setPhoneRinger(_ mode: PhoneRingerMode) -> Bool {
        guard link.isOnline, phoneRinger != nil, phoneDnd?.isOn != true, let session else { return false }
        session.setRinger(mode)
        return true
    }

    /// The Focus filter's perform() (and the `--debug-focus` hook): store what
    /// it asks for, then apply it as one Mac-side edge (a Focus started or
    /// ended). A phone that connects later gets the stored intent by
    /// [reconcileFocus], and only when it differs from what that phone had.
    func setFocusFilter(_ values: FocusFilterValues) {
        storeFocusValues(values)
        let wanted = focusValues.wanted ?? .off
        let sent = applyDnd(wanted, edge: .intentChanged(wanted.rawValue))
        FocusDebugLog.write(focus: "filter", ok: true,
                            fields: ["enabled": values.enabled, "silence": values.silence,
                                     "allow": values.allow.rawValue,
                                     "wanted": values.wanted?.rawValue ?? "off",
                                     "sent": sent])
    }

    /// Stores the filter values without sending: the system refresh at launch
    /// and before a connection's reconcile must not duplicate its `phone.dnd`.
    func storeFocusValues(_ values: FocusFilterValues) {
        focusStore.save(values)
        focusValues = values
    }

    /// The menu bar item and the manual intent: send one mode now. The phone's
    /// next `state` moves the checkmark, never an optimistic local guess.
    func setPhoneDnd(_ mode: PhoneDndMode) {
        applyDnd(mode, edge: .personAction(mode.rawValue))
    }

    /// The menu item's click: on becomes priority, off becomes off.
    func togglePhoneDnd() {
        guard let command = FocusReconciler.menuCommand(current: phoneDnd) else { return }
        setPhoneDnd(command)
    }

    /// The `--debug-dnd on|off` hook, the menu item's same path. "on" keeps a
    /// mode the phone is already in; otherwise it asks for priority.
    func setPhoneDnd(on: Bool) {
        guard let current = phoneDnd else {
            FocusDebugLog.write(focus: "dnd", ok: false,
                                fields: ["on": on, "supported": false, "error": "no_dnd"])
            return
        }
        let command: PhoneDndMode = on ? (current.isOn ? current : .priority) : .off
        setPhoneDnd(command)
        FocusDebugLog.write(focus: "dnd", ok: true,
                            fields: ["on": on, "supported": true,
                                     "command": command.rawValue,
                                     "current": current.rawValue])
    }

    /// The device the live session belongs to; nil when there is none.
    private var controlDeviceId: String? {
        let id = link.phone?.id ?? session?.phone?.id
        guard let id, !id.isEmpty else { return nil }
        return id
    }

    /// Applies one DND edge for this phone (docs/specs/controls.md): the machine
    /// decides what to send from this phone's memory, so a value the phone has
    /// already received is not sent again. False when no live phone can take it.
    @discardableResult
    private func applyDnd(_ wanted: PhoneDndMode, edge: ControlIntentEvent) -> Bool {
        guard link.isOnline, phoneDnd != nil, let id = controlDeviceId, let session else { return false }
        for action in dndIntent.record(edge, deviceId: id) {
            if case .send(let value) = action, let mode = PhoneDndMode(rawValue: value) {
                session.setDnd(mode)
            }
        }
        return true
    }

    /// Once per connection, on the first `state`: read the system's current
    /// filter first (a Focus that ended while PocketDeck was away is "not
    /// wanted"), then apply only what this phone has not had. The phone's own
    /// `dnd` report has already moved the machine by then. `dnd` is the only
    /// proof the phone supports the command; not wanted sends off, which the
    /// phone's restore rule turns into a no-op unless the DND is ours.
    private func reconcileFocusOnFirstState(_ dnd: PhoneDndMode?) {
        guard !focusReconciled else { return }
        focusReconciled = true
        #if PD_TEST_HOOKS
        reconcileFocus(onConnectWith: dnd)
        #else
        Task { @MainActor in
            await FocusBridge.refreshFromSystem()
            self.reconcileFocus(onConnectWith: dnd)
        }
        #endif
    }

    private func reconcileFocus(onConnectWith dnd: PhoneDndMode?) {
        guard dnd != nil, link.isOnline, let id = controlDeviceId, let session else { return }
        let wanted = focusValues.wanted ?? .off
        for action in dndIntent.record(.connected(wanted.rawValue), deviceId: id) {
            guard case .send(let value) = action, let mode = PhoneDndMode(rawValue: value) else { continue }
            session.setDnd(mode)
            FocusDebugLog.write(focus: "reconcile", ok: true,
                                fields: ["wanted": wanted.rawValue, "sent": mode.rawValue])
        }
    }

    private func runPendingDebugDnd() {
        guard let on = pendingDebugDnd else { return }
        pendingDebugDnd = nil
        setPhoneDnd(on: on)
    }

    // MARK: - The menus check's state changes

    @ObservationIgnored private var menuBurstTimer: Timer?
    @ObservationIgnored private var menuBurstStep = 0

    /// `menu-burst on|off` (e2e `menus`): three kinds of state change a person's
    /// log had while menus were open — a battery report, a Now Playing change
    /// and an occlusion flip — fed through the same handler the phone's own
    /// messages take. None of them is a menu value, so a menu that is open must
    /// not be rebuilt because of them (docs/specs/menus.md MENU-17).
    func debugMenuBurst(_ on: Bool) {
        menuBurstTimer?.invalidate()
        menuBurstTimer = nil
        guard on else { return }
        menuBurstStep = 0
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuBurstStepNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        menuBurstTimer = timer
    }

    private func menuBurstStepNow() {
        menuBurstStep += 1
        let charging = menuBurstStep % 2 == 1
        let status = self.status
        handle(.phoneState(locked: status?.locked ?? true,
                           battery: charging ? 42 : 87,
                           charging: charging,
                           dnd: status?.dnd,
                           ringer: status?.ringer,
                           volume: status?.volume,
                           volumeMax: status?.volumeMax,
                           screen: status?.screen,
                           secure: nil,
                           panel: nil))
        handle(.mediaState(MediaState(playing: charging,
                                      pkg: "com.example.player",
                                      positionMs: Int64(menuBurstStep) * 1000,
                                      receivedAt: Date().timeIntervalSince1970)))
        windows.controller(for: 1)?.setOcclusionVisible(charging)
        MenuTrack.noteStateChange()
    }

    /// `--debug-focus` and `--debug-dnd` (PD_TEST_HOOKS only): the filter's
    /// perform() and the menu item's path, without System Settings or a click.
    private func armFocusDebug() {
        if let raw = options.debugFocus {
            if let values = FocusDebugCommand.parseFilter(raw) {
                setFocusFilter(values)
            } else {
                FocusDebugLog.write(focus: "filter", ok: false, fields: ["error": "usage"])
            }
        }
        if let raw = options.debugDnd {
            if let on = FocusDebugCommand.parseDnd(raw) {
                pendingDebugDnd = on
                if status?.dnd != nil { runPendingDebugDnd() }
            } else {
                FocusDebugLog.write(focus: "dnd", ok: false, fields: ["error": "usage"])
            }
        }
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
            queuePendingApk(file, deviceId: nil)
            if !link.isOnline { showTransient(Self.installWaitingLine(paired: !rememberedPhones.isEmpty)) }
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
        queuePendingApk(file, deviceId: deviceId)
        if !link.isOnline { showTransient(Self.installWaitingLine(paired: !rememberedPhones.isEmpty)) }
        if let phone = remembered.phone(id: deviceId), link.phone?.id != deviceId { use(phone) }
    }

    /// The sentence names the step that can fix it: pairing for no phone,
    /// the connection for a paired phone that is away (FILES-16).
    static func installWaitingLine(paired: Bool) -> String {
        paired ? "Connect your phone to install apps on it."
               : "Pair a phone to install apps on it."
    }

    /// A ROM file waits for its phone (up to 120 s) with the waiting phase on
    /// screen and Cancel available.
    private func queuePendingApk(_ file: URL, deviceId: String?) {
        pendingApk = (file, deviceId, Date().addingTimeInterval(Self.pendingLinkLifetime))
        apkInstaller.wait(for: file)
        pendingApkTask?.cancel()
        pendingApkTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pendingLinkLifetime))
            guard !Task.isCancelled else { return }
            self?.expirePendingApk()
        }
    }

    private func expirePendingApk() {
        guard pendingApk != nil else { return }
        pendingApk = nil
        apkInstaller.waitingExpired()
    }

    /// The waiting phase's Cancel (the pill's own button).
    private func cancelPendingApk() {
        pendingApkTask?.cancel()
        pendingApkTask = nil
        pendingApk = nil
    }

    private func installPendingApk(readyPhone id: String) {
        guard let pending = pendingApk else { return }
        guard pending.until > Date() else {
            Log.app.notice("apk: waiting install expired before the phone returned")
            pendingApk = nil
            apkInstaller.waitingExpired()
            return
        }
        guard pending.deviceId == nil || pending.deviceId == id else {
            Log.app.notice("apk: waiting install is for another phone")
            return
        }
        Log.app.notice("apk: resuming the waiting install on the phone that returned")
        pendingApk = nil
        pendingApkTask?.cancel()
        pendingApkTask = nil
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
    }

    /// The stream windows' pill mouth: the phase rendered as a line. Every
    /// phase arrives through `dropSender.onPhase`, `.idle` included, so the
    /// sender's own timeout is the only hide (a second timer here could never
    /// see the phase it waited for).
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
        deckIcons = [:]
        missingIcons = []
        for app in apps {
            if let image = IconCache.shared.load(pkg: app.pkg, deviceId: ref.id) { icons[app.pkg] = image }
            loadCachedLayers(app.pkg, deviceId: ref.id)
            refreshDeckIcon(app.pkg)
        }
    }

    /// The Deck tile's image: one render of the layers (or the flat icon) at the
    /// size the 56 pt tile needs, so every cell draws the same shaped icon.
    private func refreshDeckIcon(_ pkg: String) {
        deckIcons[pkg] = PhoneAppIcon.image(layers: iconLayers[pkg], flat: icons[pkg], px: 224)
    }

    /// A cache entry that has layers goes straight into the grid (no
    /// re-request); a flat one stays flat until the connection checks.
    private func loadCachedLayers(_ pkg: String, deviceId: String) {
        guard iconLayers[pkg] == nil, let data = IconCache.shared.loadLayerData(pkg: pkg, deviceId: deviceId) else { return }
        iconLayers[pkg] = Self.glassLayers(fg: data.fg, bg: data.bg, mono: data.mono)
        refreshDeckIcon(pkg)
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
        if isPairing {
            if pairingStartedAt == nil { pairingStartedAt = Date() }
        } else {
            pairingStartedAt = nil
        }
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

    /// identity.json's §3 `pin` mirrors the fingerprint of the phone in use.
    /// It follows the dialed phone's own record (on a successful connect, on
    /// use and after pairing) and is never enforced against another phone's
    /// record; the record is the pin the TLS layer checks.
    private func mirrorIdentityPin(record: PinnedPhoneV2) {
        guard pins.record(for: record.deviceId)?.phoneFingerprintHex == record.phoneFingerprintHex else { return }
        mirrorIdentityPin(deviceId: record.deviceId)
    }

    /// The mirror for `deviceId` (the phone in use), from the store.
    private func mirrorIdentityPin(deviceId: String) {
        let next = IdentityPinMirror.pin(for: deviceId, records: pins.all)
        guard next != identity.pin else { return }
        identity.pin = next
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
                filesBridgeClient?.connectionLost()
                filesBridgeClient = nil
                FilesBridge.shared.detach()
                filesDomain.sessionReady(false)
                clipImageBuffer.discard()
                shareInbox.connectionLost()
                nowPlaying.clear()
                notifyCenter.clearAll()
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
                filesBridgeClient?.connectionLost()
                filesBridgeClient = nil
                FilesBridge.shared.detach()
                filesDomain.sessionReady(false)
                clipImageBuffer.discard()
                shareInbox.connectionLost()
                nowPlaying.clear()
                notifyCenter.clearAll()
            default:
                break
            }
        case .clipboard(let text):
            clipboardSync?.receive(text)
        case .dropProgress(let id, let bytes):
            dropSender.progress(id: id, bytes: bytes)
        case .dropResult(let result):
            dropSender.result(result)
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
            filesBridgeClient?.items(id: id, page: page, items: items)
        case .fsItem(let id, let item):
            fsClient?.item(id: id, item: item)
            filesBridgeClient?.item(id: id, item: item)
        case .fsData(let id, let bytes):
            fsClient?.data(id: id, bytes: bytes)
            filesBridgeClient?.data(id: id, bytes: bytes)
        case .fsReadEnd(let id, let size, let sha256):
            fsClient?.readEnd(id: id, size: size, sha256: sha256)
            filesBridgeClient?.readEnd(id: id, size: size, sha256: sha256)
        case .fsProgress(let id, let bytes):
            fsClient?.progress(id: id, bytes: bytes)
            filesBridgeClient?.progress(id: id, bytes: bytes)
        case .fsResult(let id, let ok, let item, let code, let message):
            fsClient?.result(id: id, ok: ok, item: item, code: code, message: message)
            filesBridgeClient?.result(id: id, ok: ok, item: item, code: code, message: message)
        case .fsError(let id, let code, let message):
            fsClient?.failure(id: id, code: code, message: message)
            filesBridgeClient?.failure(id: id, code: code, message: message)
        case .fsChanges(let paths):
            fsClient?.changes(paths: paths)
            filesBridgeClient?.changes(paths: paths)
        case .notifyState(let on, let reason):
            // The reason is the phone's string: log only the closed set we know.
            let reasonState = reason == nil ? "-" : (reason == "no_access" ? "no_access" : "other")
            Log.app.notice("phone notify \(on ? "on" : "off", privacy: .public) reason=\(reasonState, privacy: .public)")
            if let id = link.phone?.id {
                if reason == "no_access" {
                    notifyNoAccessPhones.insert(id)
                } else if on {
                    notifyNoAccessPhones.remove(id)
                }
            }
            if !on {
                nowPlaying.clear()
                notifyCenter.clearAll()
            }
        case .notifyPosted(let id, let pkg, let when, let title, let text, let actions, let ongoing, let live,
                          let alert, let group):
            let ref = link.phone?.id.isEmpty == false ? link.phone
                : session?.phone.map { PhoneRef(id: $0.id, name: $0.name, model: $0.model) }
            guard let phone = ref, !phone.id.isEmpty else { break }
            // Part 2: a muted app's post is dropped here, before it is shown
            // (it still crossed the encrypted link; docs/design/notify.md).
            if NotifyMute.isMuted(pkg, deviceId: phone.id, defaults: profile.defaults) {
                notifyCenter.recordMuted(pkg: pkg, phoneId: phone.id)
                break
            }
            notifySeen[phone.id, default: []].insert(pkg)
            notifyCenter.post(
                PhoneNotification(id: id, pkg: pkg, when: when, title: title, text: text,
                                  ongoing: ongoing, actions: actions, live: live,
                                  alert: alert, group: group),
                phoneId: phone.id,
                phoneName: displayName(for: phone, fallback: "your phone"),
                labelFor: { [weak self] in self?.labelFor($0) ?? nil },
            )
        case .notifyImage(let id, let mime, let w, let h, let data):
            notifyCenter.image(id: id, mime: mime, width: w, height: h, data: data)
        case .notifyRemoved(let id):
            notifyCenter.remove(id: id)
        case .mediaState(let media):
            nowPlaying.apply(media)
        case .mediaSessions(let rows, let chosen):
            nowPlaying.applySessions(rows, chosen: chosen)
        case .mediaArt(let key, let mime, let w, let h, let data):
            nowPlaying.applyArt(key: key, mime: mime, width: w, height: h, data: data)
        case .apps(let list):
            appsReceived(list)
        case .icon(let pkg, let png, let fg, let bg, let mono):
            // The size class the reply fills: what was asked for this package,
            // oldest request first (a reply does not echo `px`).
            let askedPx = iconRequests[pkg]?.isEmpty == false ? iconRequests[pkg]!.removeFirst() : nil
            if let image = NSImage(data: png) {
                icons[pkg] = image
                windows.setIcon(image, pkg: pkg)
                if let id = link.phone?.id {
                    IconCache.shared.store(png, fg: fg, bg: bg, mono: mono, pkg: pkg, deviceId: id,
                                           px: askedPx ?? 216)
                }
                // A layered icon lands only when it decodes whole; without
                // layers the entry is cleared, so a flat icon from a phone
                // that predates layers replaces a stale one.
                if askedPx == nil || IconSizeClass.forRequest(askedPx!) == .deck {
                    iconLayers[pkg] = Self.glassLayers(fg: fg, bg: bg, mono: mono)
                }
                refreshDeckIcon(pkg)
            } else {
                missingIcons.insert(pkg)
            }
            runDockHooks()
            runPendingDockAdds()
            recheckOpenWindows()
        case .phoneState(let locked, let battery, let charging, let dnd, let ringer, let volume,
                         let volumeMax, let screen, let secure, let panel):
            status = PhoneStatus(locked: locked, battery: battery, charging: charging, dnd: dnd, ringer: ringer,
                                 volume: volume, volumeMax: volumeMax, screen: screen)
            windows.setPhoneScreen(screen)
            if let secure { windows.setPhoneSecure(secure) }
            windows.setPhonePanel(panel)
            if let id = link.phone?.id { batteryMemory.record(deviceId: id, level: battery, charging: charging) }
            // The phone's own report moves the DND machine first: it is what
            // says whether the Mac's last value still stands (a person's change
            // on the phone stands until the Mac intent changes again).
            if let dnd, let id = controlDeviceId {
                dndIntent.record(.phoneReported(dnd.rawValue), deviceId: id)
            }
            reconcileFocusOnFirstState(dnd)
            runPendingDebugDnd()
        case .ringState(let playing):
            ringing = playing
        case .powerLocked:
            windows.powerLocked()
        case .audioState:
            break
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
                showTransient("Nothing to move. Your phone is showing its home screen or PocketDeck.")
            } else if code == "launch_failed" || (stream != 0 && code == "no_stream") {
                showTransient(ConnectionFailure.message(for: code) ?? "Something went wrong.")
            } else if stream == 0 && (code == "unavailable" || code == "bad_request") {
                // `phone.panel` refused: the phone never turned its screen off.
                windows.failPhonePanelRequest()
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
                stream = windows.openOrRaise(pkg: app.pkg, activity: app.activity).stream
            case .send(let destination):
                // The window is already open: an older phone that ignores
                // notify.open keeps today's behaviour there.
                session?.openNotification(id: click.id, target: destination,
                                          stream: destination == .window ? stream : nil)
            }
        }
    }

    /// A row of the menu bar's Live section: the same route a banner click runs
    /// (docs/design/notify.md, 2b).
    func openLiveNotification(_ id: String) {
        notifyCenter.performOpen(id: id)
    }

    /// One ticker while live rows exist; none when the last one ends.
    private func updateLiveTicker() {
        if liveNotifications.isEmpty {
            liveTicker?.invalidate()
            liveTicker = nil
            return
        }
        guard liveTicker == nil else { return }
        liveTicker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.liveNotifications.isEmpty else { return }
                self.liveTick = Date()
            }
        }
    }

    /// The menu bar's header, naming the phone the live rows belong to.
    var livePhoneName: String? {        guard !liveNotifications.isEmpty, let phone = activePhone else { return nil }
        return displayName(for: phone, fallback: "your phone")
    }

    /// `livedump PATH` (the e2e reads the menu bar section without opening it).
    /// The menu bar's media row mirrors the controller (it is not observed).
    private func refreshMedia() {
        mediaNow = nowPlaying.current
        mediaSessions = nowPlaying.sessions
        mediaArt = nowPlaying.artwork.flatMap { NSImage(data: $0.data) }
    }

    /// The menu bar's "Playing on phone" pick.
    func chooseMediaSession(_ key: String) {
        guard link.isOnline else { return }
        nowPlaying.choose(key)
    }

    /// The phone panel's volume slider: a fraction of the phone's own music
    /// stream maximum (docs/PROTOCOL.md "Volume"), sent as one integer level.
    func setPhoneVolume(_ fraction: Double) {
        guard link.isOnline, let max = status?.volumeMax, max > 0, let session else { return }
        let level = min(Swift.max(Int((fraction * Double(max)).rounded()), 0), max)
        session.setVolume(level)
    }

    /// The recording line's own path: no volume keys are intercepted.
    func writeLiveDump(_ path: String) -> Bool {
        do {
            try NotifyLiveDump.write(liveNotifications, to: path)
            return true
        } catch {
            return false
        }
    }

    /// "Share clipboard with your phone" changed (Settings ▸ General): the
    /// person's answer is stored, and a live session is told at once so the
    /// phone stops (or resumes) sending and applying clips instead of being
    /// ignored here (SHARE-13).
    func clipboardSettingChanged(_ on: Bool) {
        profile.defaults.set(on, forKey: ClipboardSync.enabledKey)
        session?.enableClipboard(on)
    }

    /// The per-device opt-in toggle changed (Settings ▸ Phones).
    func notifySettingChanged(deviceId: String, on: Bool) {
        if isPreview, previewNotify[deviceId] != nil {
            previewNotify[deviceId]?.enabled = on
            return
        }
        profile.defaults.set(on, forKey: NotifyToggle.key(deviceId: deviceId))
        if !on { notifyNoAccessPhones.remove(deviceId) }
        if link.phone?.id == deviceId { session?.enableNotifications(on) }
        if !on, link.phone?.id == deviceId { nowPlaying.clear() }
    }

    /// The click choice changed; it is read on every click, so a live session
    /// needs no message (docs/design/notify.md).
    func notifyClickSettingChanged(deviceId: String, target: NotifyClickTarget) {
        if isPreview, previewNotify[deviceId] != nil {
            previewNotify[deviceId]?.click = target
            return
        }
        profile.defaults.set(target.rawValue, forKey: NotifyClickTarget.key(deviceId: deviceId))
    }

    /// `notify.action`: a banner button or reply. The id is the phone's; nothing
    /// else crosses the wire.
    func notifyActionPressed(_ click: NotifyClick, index: Int, text: String?) {
        guard link.isOnline else { return }
        session?.notifyAction(id: click.id, index: index, text: text)
    }

    /// A banner clear: dismiss the forward notification on the phone.
    func notifyDismissed(_ click: NotifyClick) {
        guard link.isOnline else { return }
        session?.notifyDismiss(id: click.id)
    }

    /// Settings › Devices "Muted apps": one package toggled for this phone.
    func notifyMuteChanged(deviceId: String, pkg: String, muted: Bool) {
        if isPreview, previewNotify[deviceId] != nil {
            if muted { previewNotify[deviceId]?.muted.insert(pkg) } else { previewNotify[deviceId]?.muted.remove(pkg) }
            return
        }
        NotifyMute.setMuted(muted, pkg: pkg, deviceId: deviceId, defaults: profile.defaults)
    }

    /// Packages to offer in "Muted apps": seen this session plus already muted.
    func notifyMutedAppChoices(deviceId: String) -> [String] {
        if let preview = previewNotify[deviceId] {
            let stored = NotifyMute.muted(deviceId: deviceId, defaults: profile.defaults)
            return Array(preview.seen.union(preview.muted).union(stored)).sorted()
        }
        let seen = notifySeen[deviceId] ?? []
        return Array(seen.union(NotifyMute.muted(deviceId: deviceId, defaults: profile.defaults))).sorted()
    }

    /// The app list this Mac already has for the phone: live for the session's
    /// phone, the cached copy for any other (devices are peers).
    func cachedApps(deviceId: String) -> [AppInfo] {
        if link.phone?.id == deviceId, appsLoaded { return apps }
        return appsCache.load(deviceId: deviceId)
    }

    /// Packages that sent a notification this session for this phone.
    func seenPackages(deviceId: String) -> Set<String> {
        if let preview = previewNotify[deviceId] { return preview.seen }
        return notifySeen[deviceId] ?? []
    }

    /// The macOS notification permission, for the phone page's line.
    private(set) var notifyAuthorization: NotificationAuthorization = .notDetermined

    /// Read the system's answer again (the page's Check Again, and at launch).
    func checkNotificationAuthorization() {
        Task { @MainActor in
            notifyAuthorization = await notifyCenter.authorizationStatus()
        }
    }

    /// Whether the Mac was told the phone's listener access is missing.
    func notifyAccessMissing(deviceId: String) -> Bool {
        notifyNoAccessPhones.contains(deviceId)
    }

    /// The packages muted for this phone (the muted list's switches read it).
    func mutedPackages(deviceId: String) -> Set<String> {
        if let preview = previewNotify[deviceId] { return preview.muted }
        return NotifyMute.muted(deviceId: deviceId, defaults: profile.defaults)
    }

    /// Whether this phone's notification sharing is on (Settings ▸ Phones).
    func notificationsEnabled(deviceId: String) -> Bool {
        if let preview = previewNotify[deviceId] { return preview.enabled }
        return NotifyToggle.isEnabled(deviceId: deviceId, defaults: profile.defaults)
    }

    /// What a click on this phone's notification does.
    func notifyClickTarget(deviceId: String) -> NotifyClickTarget {
        if let preview = previewNotify[deviceId] { return preview.click }
        return NotifyClickTarget.stored(deviceId: deviceId, defaults: profile.defaults)
    }

    /// Whether this Mac still holds the phone's pinned key: a remembered phone
    /// without one reads "Pair again", never "Offline".
    func hasPinnedKey(deviceId: String) -> Bool { pins.record(for: deviceId) != nil }

    /// The app's own name for the package, when the phone's list has it.
    func appLabel(for pkg: String) -> String? { labelFor(pkg) }

    private func labelFor(_ pkg: String) -> String? {
        windows.appsByPkg[pkg]?.label ?? apps.first { $0.pkg == pkg }?.label
    }

    private func ready(_ info: PhoneInfo, address: CachedAddress?) {
        let ref = PhoneRef(id: info.id, name: info.name, model: info.model)
        let wasPairing = isPairing
        remembered.remember(ref)
        rememberedPhones = remembered.all
        // A successful connect (a fresh pairing or an enforced reconnect):
        // the §3 mirror is this phone's record from now on.
        mirrorIdentityPin(deviceId: info.id)
        markWelcomeSeen()
        if let address {
            cache.store(address, deviceId: info.id)
            cache.store(name: info.name, deviceId: info.id)
        }
        lastAttemptFailed = false
        layerRefresh.reset()
        iconRequests = [:]
        dockIconAsked = []
        let hadWindows = !windows.openStreams.isEmpty
        windows.phone = info
        // Every window title carries the display name from here on.
        windows.setPhoneName(displayName(for: ref))
        status = PhoneStatus(locked: info.locked, battery: info.battery, charging: info.charging ?? false,
                             ringer: status?.ringer, volume: status?.volume, volumeMax: status?.volumeMax,
                             screen: status?.screen)
        // A new connection: its first `state` reconciles the Focus once.
        focusReconciled = false
        if let battery = info.battery {
            batteryMemory.record(deviceId: info.id, level: battery, charging: info.charging ?? false)
        }
        if apps.isEmpty || link.phone?.id != info.id { resetPhoneData(for: ref) }
        send(.welcome(ref))
        // The File Provider bridge answers from here on (docs/design/files.md
        // §1): the app owns the session, so the extension asks this socket.
        if let session {
            let client = FsClient(channel: session)
            // The phone's fs.changes go to the app's watcher half, which re-lists
            // the folder and signals the extension (design §5).
            client.onChanges = { paths in FilesBridge.shared.filesChanged(paths: paths) }
            filesBridgeClient = client
            FilesBridge.shared.attach(host: SessionBridgeHost(
                client: client,
                name: displayName(for: ref),
                mapURL: profile.filesIdMapUrl,
                signal: { containers in FilesBridge.shared.signal(containers: containers) }))
            filesDomain.sessionReady(true)
        }
        everOnline = true
        if let session {
            startClipboardSync(on: session)
            // The phone starts with its gate off: every ready session learns
            // the Mac's own choice, as it learns the notify switch below.
            session.enableClipboard(ClipboardSync.isEnabled(in: profile.defaults))
        }
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
            windows.openOrRaise(pkg: request.pkg)
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
                // A cached flat (or a phone that predates layers) still gets a
                // render: the tile never draws the flat image itself, and the
                // phone's answer may take a while or never come.
                if deckIcons[app.pkg] == nil { refreshDeckIcon(app.pkg) }
            } else {
                requestIcon(app.pkg, px: IconSizeClass.deck.layerPx)
            }
        }
        // A cached icon without layers may predate them: ask once per
        // connection, so a phone that has layers catches the rendered look up.
        if let id = link.phone?.id {
            for app in list where iconLayers[app.pkg] == nil && icons[app.pkg] != nil && IconCache.shared.hasLayers(pkg: app.pkg, deviceId: id) == false {
                if layerRefresh.allow(pkg: app.pkg) { requestIcon(app.pkg, px: IconSizeClass.deck.layerPx) }
            }
        }
        if let ref = link.phone {
            spotlight.index(apps: list, deviceId: ref.id, phoneName: displayName(for: ref),
                            iconData: { IconCache.shared.renderedPNG(pkg: $0, deviceId: ref.id, px: 256) })
            dockApps.reconcile(deviceId: ref.id, apps: list, phoneName: displayName(for: ref),
                               keep: dockPkgsOfOpenWindows)
        }
        runDockHooks()
        runPendingDockAdds()
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
        debugInput?.notifyAction = { [weak self] id, index, text in
            MainActor.assumeIsolated { self?.notifyCenter.performAction(id: id, index: index, text: text) ?? false }
        }
        debugInput?.notifyDismiss = { [weak self] id in
            MainActor.assumeIsolated { self?.notifyCenter.performDismiss(id: id) ?? false }
        }
        debugInput?.notifyCopy = { [weak self] id in
            MainActor.assumeIsolated { self?.notifyCenter.performCopy(id: id) ?? false }
        }
        debugInput?.liveDump = { [weak self] path in
            MainActor.assumeIsolated { self?.writeLiveDump(path) ?? false }
        }
        debugInput?.openSettings = { [weak self] in
            MainActor.assumeIsolated {
                self?.settingsRequest += 1
                // Belt and braces: the Deck's scene opener is the route that
                // works in a quiet run, and the responder action costs nothing.
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
        debugInput?.mediaCommand = { [weak self] action in
            MainActor.assumeIsolated { self?.nowPlaying.perform(.transport(action)) }
        }
        debugInput?.mediaSeek = { [weak self] ms in
            MainActor.assumeIsolated { self?.nowPlaying.perform(.seek(ms)) }
        }
        debugInput?.mediaVolume = { [weak self] level in
            MainActor.assumeIsolated { self?.nowPlaying.perform(.volume(level)) }
        }
        debugInput?.mediaChoose = { [weak self] key in
            MainActor.assumeIsolated {
                guard let self, self.link.isOnline else { return }
                self.nowPlaying.choose(key)
            }
        }
        // The dockapps action writes the setting the way Settings'
        // @AppStorage does, then calls the same handler its onChange does.
        debugInput?.dockApps = { [weak self] on in
            MainActor.assumeIsolated { self?.setShowAppsInDock(on) }
        }
        // The panel's debug host and driver: the same SwiftUI content the menu
        // bar shows, and clicks at the controls' own frames.
        debugInput?.panelOpen = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                PanelProbe.open(controller: self)
            }
        }
        debugInput?.panelClose = {
            MainActor.assumeIsolated { PanelProbe.close() }
        }
        debugInput?.panelDump = { host, path in
            MainActor.assumeIsolated { PanelProbe.dump(host: host, to: path) }
        }
        debugInput?.panelClick = { host, id in
            MainActor.assumeIsolated { PanelProbe.click(host: host, id: id) }
        }
        debugInput?.panelDrag = { host, id, fraction in
            MainActor.assumeIsolated { PanelProbe.drag(host: host, id: id, fraction: fraction) }
        }
        debugInput?.panelRinger = { host, mode in
            MainActor.assumeIsolated {
                guard let mode = PhoneRingerMode(rawValue: mode) else { return false }
                return PanelProbe.ringer(host: host, mode: mode)
            }
        }
        debugInput?.deckPanel = { [weak self] in
            MainActor.assumeIsolated { self?.openDeckPanel() }
        }
        debugInput?.arm(phoneOnly: phoneOnly)
        return nil
    }

    /// The forced rail position (`deckrailenter`/`deckrailmove`): a quiet run
    /// cannot move the pointer, so the state machine is fed the same event the
    /// container's hover sends, and the rest of the path (the frozen span, the
    /// help tag, the ease) is the live one.
    private func forceRail(letter: String) -> Bool {
        RailPointerModel.shared.force(letter: letter, reduceMotion: railReduceMotion)
    }

    private var railReduceMotion: Bool {
        Motion.reduce(system: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
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
        case "nav":
            guard let action = arguments.first,
                  ["back", "home", "recents"].contains(action) else {
                return "nav needs back|home|recents"
            }
            guard let window = windows.controller(for: 1) else { return "no first window" }
            switch action {
            case "back":
                window.navigateBack(nil)
            case "home", "recents":
                guard let phone = window as? PhoneWindowController else {
                    return "home/recents need the phone window"
                }
                action == "home" ? phone.navigateHome(nil) : phone.navigateRecents(nil)
            default:
                return "nav needs back|home|recents"
            }
            return nil
        case "occlude":
            // The quiet e2e run may not cover the window (no extra windows):
            // tell the first window what the WindowServer would have said.
            guard let state = arguments.first, ["on", "off"].contains(state) else {
                return "occlude needs on|off"
            }
            guard let window = windows.controller(for: 1) else { return "no first window" }
            window.setOcclusionVisible(state == "off")
            return nil
        case "secondary-click":
            // Settings ▸ Input "Secondary click (two-finger click)", the same
            // store the Settings picker writes.
            guard let raw = arguments.first, let value = SecondaryClick(rawValue: raw) else {
                return "secondary-click needs longPress|back|nothing"
            }
            windows.secondaryClick = value
            return nil
        case "resize-step":
            // One step of a scripted drag on the first window: the same
            // windowWillResize call AppKit makes for a mouse move, then the
            // frame it returns. The chrome state's `frame=` records each step.
            guard arguments.count >= 2, let w = Double(arguments[0]), let h = Double(arguments[1]),
                  w > 0, h > 0 else { return "resize-step needs width height" }
            guard let window = windows.controller(for: 1) else { return "no first window" }
            window.liveResizeStep(to: NSSize(width: w, height: h))
            return nil
        case "wake-phone":
            // The phone window's Wake Screen button, for the e2e (its click is
            // unit-tested; a scripted click would need real pointer input).
            guard let phone = windows.phoneWindow else { return "no phone window" }
            phone.wakeScreen()
            return nil
        case "menudump":
            // The main menu tree at this moment, for the e2e menus check: the
            // debug-input script is gone once the last window closed, and the
            // bar must be read then. update() runs the same validation an
            // opened menu does, which is what makes the enabled flags and the
            // check marks truthful; nothing in the app puts an AppKit item back
            // any more, so it cannot hide a dropped item.
            guard let path = arguments.first, path.hasPrefix("/") else {
                return "menudump needs an absolute PATH"
            }
            NSApp.mainMenu?.update()
            // The marks that opening the menu writes (MenuMarks): the dump stands
            // for what a person reads in the open menu.
            MainActor.assumeIsolated { MenuMarks.apply(to: NSApp.mainMenu) }
            do {
                try MenuDump.write(NSApp.mainMenu, to: path, displayed: true)
            } catch {
                return "menudump failed: \(error.localizedDescription)"
            }
            return nil
        case "key":
            // A real key event through the application's own dispatch: menu key
            // equivalents, local monitors and the key window's responder chain,
            // the same route a person's press takes (no pointer involved).
            guard let spec = arguments.first else { return "key needs SPEC" }
            guard let stroke = DebugInputScript.keyStroke(for: spec) else { return "unknown key '\(spec)'" }
            return sendKey(stroke)
        case "menutrack":
            // The e2e menus check: hold one of the app's real menus open and
            // report what happened while it was up (MenuTrack.swift).
            guard arguments.count == 3, arguments[0].hasPrefix("/"),
                  let seconds = Double(arguments[2]) else {
                return "menutrack needs PATH View/Density SECONDS"
            }
            return MenuTrack.start(path: arguments[0], itemPath: arguments[1], seconds: seconds)
        case "menu-burst":
            // The state changes the check makes while the menu is open: a
            // battery report, a Now Playing change and an occlusion flip.
            guard let on = arguments.first, ["on", "off"].contains(on) else {
                return "menu-burst needs on|off"
            }
            debugMenuBurst(on == "on")
            return nil
        case "decksearch":
            // The Deck search field's state: focused, text, selection, and which
            // window is key (a read; the ⌘F behaviour is a real key event).
            guard let path = arguments.first, path.hasPrefix("/") else {
                return "decksearch needs an absolute PATH"
            }
            return DeckSearch.dump(to: path) ? nil : "decksearch failed"
        case "deckfocus":
            // Setup for the key checks: the Deck key with its search field
            // focused, or with the content (grid) as first responder.
            guard let what = arguments.first, ["search", "grid"].contains(what) else {
                return "deckfocus needs search|grid"
            }
            guard let deck = DeckWindow.window else { return "no deck window" }
            deck.makeKeyAndOrderFront(nil)
            if what == "search" {
                DeckSearch.focusAndSelect(in: deck) { requestSearchFocus() }
            } else {
                deck.makeFirstResponder(deck.contentView)
            }
            return nil
        case "deckquery":
            // Setup for the ⌘F check: the text already in the search field;
            // no argument clears it.
            guard let deck = DeckWindow.window else { return "no deck window" }
            DeckSearch.setText(arguments.first ?? "", in: deck)
            return nil
        case "deckclick":
            // A Deck cell's click: its own drawn place, through the window's
            // event handling (the Deck has no debug route that calls openOrRaise).
            // The label may hold spaces (an app's words are its name).
            guard !arguments.isEmpty else { return "deckclick needs an app label" }
            let label = arguments.joined(separator: " ")
            guard let deck = DeckWindow.window else { return "no deck window" }
            return DeckCellClick.click(label: label, in: deck)
        case "coverclick":
            // A click on the opening cover's own button (Cancel or Close), at
            // its place in the window, through the window's event handling.
            guard let title = arguments.first else { return "coverclick needs a button title" }
            let controllers = NSApp.windows.compactMap { $0.windowController as? StreamWindowController }
            guard let target = controllers.first(where: { $0.opening.isUp }) else {
                return "no cover is up"
            }
            guard target.chrome.openingCover.buttonCentre(title) != nil else {
                return "no cover button \(title)"
            }
            // The press lands after this command answers: closing the window
            // from inside the poll would hold the reply the check waits for.
            Task { @MainActor in target.chrome.openingCover.press(title) }
            return nil
        case "keywindow":
            // Which window a raise actually put in front: a read, for a check
            // that must not infer it from the CG window list's order.
            guard let path = arguments.first, path.hasPrefix("/") else {
                return "keywindow needs an absolute PATH"
            }
            let window = NSApp.keyWindow
            let line = "\(window?.identifier?.rawValue ?? "-")\n\(window?.title ?? "-")\n"
            return (try? line.write(toFile: path, atomically: true, encoding: .utf8)) == nil
                ? "keywindow failed" : nil
        case "phone-mirror":
            // Phone ▸ Phone Mirror's action (the same ConnectionController call the
            // menu, the panel and the Deck make), without a key or a menu: a quiet
            // launch is not the frontmost app, and SwiftUI's menu action does not
            // run from a key event there (the menu reports the key taken, and
            // nothing opens). The check drives it for the one-mirror rule.
            openPhoneWindow()
            return nil
        case "panel-menu":
            // Phone ▸ Turn Off Phone Screen: the same WindowManager call the
            // menu item's binding makes, which sends the phone window's own
            // action (its target, like a menu item's).
            guard windows.phoneWindow != nil else { return "no phone window" }
            windows.togglePhonePanelOff()
            return nil
        case "panel-click":
            // A click on the phone window's bar control, posted at the control's
            // window location and resolved by the window's own hit test (the
            // action alone would prove the action, not the control). The glyph
            // follows the phone's next `state.panel`, never this click.
            guard let phone = windows.phoneWindow else { return "no phone window" }
            guard let window = phone.window, let centre = phone.chrome.headerButtonCentre(.custom) else {
                return "the panel button is not showing"
            }
            DebugInputDriver.clickControl(at: centre, in: window)
            return nil
        case "nav-click":
            // A click on the phone window's Back / Home / Recents button,
            // posted at the button's window location and resolved by the
            // window's own hit test: the v103 capsule regression was invisible
            // to a route that called the action.
            guard let phone = windows.phoneWindow else { return "no phone window" }
            guard let name = arguments.first, let kind = HeaderActionKind(rawValue: name) else {
                return "unknown button \(arguments.first ?? "")"
            }
            guard let window = phone.window, let centre = phone.chrome.headerButtonCentre(kind) else {
                return "the \(name) button is not showing"
            }
            DebugInputDriver.clickControl(at: centre, in: window)
            return nil
        case "panelattach":
            PanelProbe.attach(controller: self)
            return nil
        case "panelopen":
            // The menu bar panel's content in a window of its own: a quiet run
            // cannot open the status item, and the panel is the content.
            PanelProbe.open(controller: self)
            return nil
        case "panelclose":
            PanelProbe.close()
            return nil
        case "deckpanel":
            // The Deck's status pill popover (a toolbar item; opening it is
            // setup for the switch inside).
            PanelProbe.openDeckPopover(controller: self)
            return nil
        case "panelhover":
            guard arguments.count == 2 else { return "panelhover needs HOST and an item ID" }
            return PanelProbe.hover(host: arguments[0], id: arguments[1]) ? nil : "panelhover failed"
        case "panelhoverout":
            return PanelProbe.hoverOut() ? nil : "panelhoverout failed"
        case "panelpoint":
            guard arguments.count == 3 else { return "panelpoint needs HOST, ID and PATH" }
            return PanelProbe.point(host: arguments[0], id: arguments[1], to: arguments[2])
                ? nil : "panelpoint failed"
        case "paneldump":
            guard arguments.count == 2, ["panel", "deck", "real"].contains(arguments[0]) else {
                return "paneldump needs HOST (panel, deck or real) and PATH"
            }
            return PanelProbe.dump(host: arguments[0], to: arguments[1]) ? nil : "paneldump failed"
        case "iconmenu":
            // The status item's menu as the builder makes it, without popping
            // it (a quiet run has no screen to pop it on). e2e `menus`.
            guard let path = arguments.first, path.hasPrefix("/") else { return "iconmenu needs PATH" }
            guard let menuBar = MenuBarController.current else { return "no menu bar item" }
            return menuBar.dumpSecondaryMenu(to: path) ? nil : "iconmenu could not write \(path)"
        case "menubaricon":
            // The item itself: its length, the button's own image, foreign
            // views over it, the link and the agent dot (e2e menubar-shots,
            // PANEL-25). The reply is the line the check reads, not "ok".
            guard let menuBar = MenuBarController.current else { return "no menu bar item" }
            return menuBar.iconDescription()
        case "panelwindows":
            guard let path = arguments.first, path.hasPrefix("/") else { return "panelwindows needs PATH" }
            return PanelProbe.windowsReport(to: path) ? nil : "panelwindows failed"
        case "visibleframe":
            // The visible frame of the screen the key window is on, "W H" in
            // points: the e2e chrome check compares an Accessibility resize
            // against it (CONV-MAC-12).
            guard let path = arguments.first, path.hasPrefix("/") else {
                return "visibleframe needs an absolute PATH"
            }
            let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
            guard let visible = screen?.visibleFrame else { return "no screen" }
            let line = "\(Int(visible.width.rounded())) \(Int(visible.height.rounded()))\n"
            return (try? line.write(toFile: path, atomically: true, encoding: .utf8)) == nil
                ? "visibleframe failed" : nil
        case "panelclick":
            guard arguments.count == 2 else { return "panelclick needs HOST and an item ID" }
            return PanelProbe.click(host: arguments[0], id: arguments[1]) ? nil : "panelclick failed"
        case "paneldrag":
            guard arguments.count == 3, let fraction = Double(arguments[2]) else {
                return "paneldrag needs HOST, an item ID and FRACTION"
            }
            return PanelProbe.drag(host: arguments[0], id: arguments[1], fraction: fraction)
                ? nil : "paneldrag failed"
        case "panelvolumedrag":
            guard arguments.count == 3, let fraction = Double(arguments[1]),
                  arguments[2].hasPrefix("/") else {
                return "panelvolumedrag needs HOST, FRACTION and PATH"
            }
            return PanelProbe.volumeDrag(host: arguments[0], fraction: fraction,
                                         to: arguments[2]) ? nil : "panelvolumedrag failed"
        case "panelringer":
            guard arguments.count == 2, let mode = PhoneRingerMode(rawValue: arguments[1]) else {
                return "panelringer needs HOST and MODE (normal, vibrate, silent)"
            }
            return PanelProbe.ringer(host: arguments[0], mode: mode) ? nil : "panelringer failed"
        case "deck-size":
            // Resize the Deck for the grid checks: the block is centred and
            // capped at a wide size and drops columns as the window narrows.
            guard arguments.count >= 2, let w = Double(arguments[0]), let h = Double(arguments[1]),
                  w > 0, h > 0 else { return "deck-size needs width height" }
            guard let window = DeckWindow.window else { return "no Deck window" }
            window.setContentSize(NSSize(width: w, height: h))
            return nil
        case "deck-frame":
            // The Deck's frame in screen points, "x y w h": the e2e reads it
            // before and after a relaunch (DECK-19/CONV-MAC-12).
            guard let path = arguments.first, path.hasPrefix("/") else { return "deck-frame needs PATH" }
            guard let window = DeckWindow.window else { return "no Deck window" }
            let frame = window.frame
            let line = "\(Int(frame.minX.rounded())) \(Int(frame.minY.rounded()))"
                + " \(Int(frame.width.rounded())) \(Int(frame.height.rounded()))\n"
            return (try? line.write(toFile: path, atomically: true, encoding: .utf8)) == nil
                ? "deck-frame failed" : nil
        case "deck-move":
            // The Deck's origin in screen points: setup for the frame check
            // (a quiet run cannot drag the window), DECK-19.
            guard arguments.count >= 2, let x = Double(arguments[0]), let y = Double(arguments[1])
            else { return "deck-move needs x y" }
            guard let window = DeckWindow.window else { return "no Deck window" }
            window.setFrameOrigin(NSPoint(x: x, y: y))
            return nil
        case "bar-appearance":
            // The first stream window's appearance and the bar's material, for
            // the visible shot run: a capture that should be dark says whether
            // the window and its bar really were (MIRROR-22).
            guard let path = arguments.first, path.hasPrefix("/") else {
                return "bar-appearance needs PATH"
            }
            guard let window = windows.controller(for: 1) else { return "no first window" }
            let darkBar = window.chrome.barMaterial.fill == HeaderBar.material(dark: true).fill
            let darkWindow = window.barAppearanceName == "darkAqua"
            let line = "window=\(darkWindow ? "dark" : "light") bar=\(darkBar ? "dark" : "light")\n"
            return (try? line.write(toFile: path, atomically: true, encoding: .utf8)) == nil
                ? "bar-appearance failed" : nil
        case "screens":
            // Every screen's frame and visible frame, and the Deck's, whole
            // points: the e2e's context for a frame that did not come back.
            guard let path = arguments.first, path.hasPrefix("/") else { return "screens needs PATH" }
            var lines = ""
            for (index, screen) in NSScreen.screens.enumerated() {
                lines += "screen \(index) frame=\(DeckPlacement.summary(screen.frame))"
                    + " visible=\(DeckPlacement.summary(screen.visibleFrame))\n"
            }
            lines += "deck=\(DeckWindow.window.map { DeckPlacement.summary($0.frame) } ?? "none")\n"
            return (try? lines.write(toFile: path, atomically: true, encoding: .utf8)) == nil
                ? "screens failed" : nil
        case "quit":
            // A real quit (⌘Q's own path), so the app's terminate hooks run:
            // the frame test needs what a person's quit leaves behind.
            NSApp.terminate(nil)
            return nil
        case "deck-rail":
            // The rail is pointer-only; the e2e clicks it through this verb,
            // which runs the same scroll the rail's own click runs.
            guard let letter = arguments.first, DeckRail.letters.contains(letter) else {
                return "deck-rail needs A-Z or #"
            }
            deckRailToken += 1
            deckRailRequest = DeckRailRequest(letter: letter, token: deckRailToken)
            return nil
        case "deck-scroll":
            // The rail is pointer-only and a quiet run cannot move the real
            // pointer, so the e2e scrolls the grid by other means (what the
            // scroll bar does) through this verb; the accent's return to the
            // top row's letter is the proof (DECK-7).
            guard let dy = arguments.first.flatMap(Double.init) else { return "deck-scroll needs DY" }
            return DeckGridScroll.scroll(by: CGFloat(dy))
        case "deckrailenter":
            // The pointer enters the rail's rest column at LETTER's band, which
            // freezes the span there.
            guard let letter = arguments.first, DeckRail.letters.contains(letter) else {
                return "deckrailenter needs A-Z or #"
            }
            guard DeckWindow.window != nil else { return "no deck window" }
            guard forceRail(letter: letter) else { return "deckrailenter failed" }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            return nil
        case "deckrailmove":
            // The pointer moves to LETTER's band inside the frozen span; the
            // ends must not move.
            guard let letter = arguments.first, DeckRail.letters.contains(letter) else {
                return "deckrailmove needs A-Z or #"
            }
            guard DeckWindow.window != nil else { return "no deck window" }
            guard forceRail(letter: letter) else { return "deckrailmove failed" }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            return nil
        case "deckrailleave":
            RailPointerModel.shared.leave(reduceMotion: railReduceMotion)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            return nil
        case "deckrailanchor":
            // The rail's top-left in Quartz screen coordinates, for a visible
            // run's real pointer at a place measured from the render.
            guard let path = arguments.first, path.hasPrefix("/") else {
                return "deckrailanchor needs PATH"
            }
            return DeckRailPoint.anchorPoint(to: path) ? nil : "deckrailanchor failed"
        case "deckrailslots":
            // The rail's drawn geometry (DECK-7): the pitch, the rail and
            // container heights, the slots' y/height and their glyph boxes in
            // the rail's own points, plus the tag's letter while it shows.
            guard let path = arguments.first, path.hasPrefix("/") else {
                return "deckrailslots needs PATH"
            }
            let model = RailPointerModel.shared
            guard let fit = model.railFit, !model.slots.isEmpty else { return "no rail" }
            let height = CGFloat(fit.count) * fit.pitch
            let frozen = model.state.frozen
            let scales: [CGFloat]
            let layout: [RailLayout.Slot]
            if let frozen {
                // The centre is solved inside the frozen span.
                let centre = RailLayout.frozenCentre(atY: frozen.y, span: frozen.span,
                                                     count: fit.count)
                scales = RailLayout.scales(count: fit.count, centre: centre,
                                           reduceMotion: railReduceMotion)
                layout = RailLayout.frozenSlots(scales: scales, span: frozen.span)
            } else {
                scales = Array(repeating: 1, count: fit.count)
                layout = (0..<fit.count).map {
                    RailLayout.Slot(y: CGFloat($0) * fit.pitch, height: fit.pitch)
                }
            }
            var items: [[String: Any]] = []
            for (index, box) in layout.enumerated() {
                let glyph = 9 * scales[index]
                items.append(["first": model.slots[index].first,
                              "letters": model.slots[index].count,
                              "scale": Double(scales[index]),
                              "y": Double(box.y),
                              "height": Double(box.height),
                              "glyphTop": Double(box.y + (box.height - glyph) / 2),
                              "glyphBottom": Double(box.y + (box.height + glyph) / 2)])
            }
            let tag: Any = frozen.map {
                RailLayout.letter(atY: $0.y, in: layout, slots: model.slots) ?? NSNull()
            } ?? NSNull()
            let state: String
            switch model.state {
            case .away: state = "away"
            case .hovering: state = "hovering"
            case .dragging: state = "dragging"
            }
            let line: [String: Any] = ["pitch": Double(fit.pitch),
                                       "reduceMotion": railReduceMotion,
                                       "railHeight": Double(height),
                                       "containerHeight": Double(model.containerSize.height),
                                       "state": state,
                                       "y": Double(frozen?.y ?? -1),
                                       "spanTop": Double(frozen?.span.top ?? -1),
                                       "spanBottom": Double(frozen?.span.bottom ?? -1),
                                       "tag": tag,
                                       "slots": items]
            guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
                  var text = String(data: data, encoding: .utf8) else {
                return "deckrailslots failed"
            }
            text += "\n"
            return (try? text.write(toFile: path, atomically: true, encoding: .utf8)) == nil
                ? "deckrailslots failed" : nil
        case "deckrailsweep":
            // N pointer moves in one command, the body-count proof's moves: the
            // first enters at A and the rest sweep down the rail, one runloop
            // turn per move (about 30 ms), as a pointer's moves arrive. A single
            // turn for all of them would coalesce them into one transaction and
            // hide a per-move invalidation.
            guard let steps = Int(arguments.first ?? ""), steps > 0 else {
                return "deckrailsweep needs N"
            }
            guard let fit = RailPointerModel.shared.railFit else { return "no rail" }
            let total = CGFloat(fit.count) * fit.pitch
            for step in 0..<steps {
                let y = steps == 1 ? 0 : total * CGFloat(step) / CGFloat(steps - 1)
                RailPointerModel.shared.track(dx: 0, y: y, reduceMotion: railReduceMotion)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
            }
            return nil
        case "deckbodycount":
            // The grid body's evaluation count: the proof a pointer on the
            // rail does not invalidate the grid.
            guard let path = arguments.first, path.hasPrefix("/") else {
                return "deckbodycount needs PATH"
            }
            #if PD_TEST_HOOKS
            let line = "\(DeckGridProbe.bodyCount)\n"
            return (try? line.write(toFile: path, atomically: true, encoding: .utf8)) == nil
                ? "deckbodycount failed" : nil
            #else
            return "deckbodycount needs a test-hooks build"
            #endif
        case "deckbodyreset":
            #if PD_TEST_HOOKS
            DeckGridProbe.resetBodyCount()
            return nil
            #else
            return "deckbodyreset needs a test-hooks build"
            #endif
        case "deckrailpoint":
            // The letter's centre in Quartz screen coordinates, for a visible
            // VM run's real pointer. An optional DX puts it that many points
            // left of the rail's leading edge.
            guard arguments.count >= 2, arguments.count <= 3,
                  DeckRail.letters.contains(arguments[0]) else {
                return "deckrailpoint needs A-Z or # and PATH [DX]"
            }
            let dx = arguments.count == 3 ? CGFloat(Double(arguments[2]) ?? 0) : 0
            return DeckRailPoint.point(letter: arguments[0], to: arguments[1], dx: dx)
                ? nil : "deckrailpoint failed"
        case "settings-open":
            // The ⌘, route (a setup step for a check that needs Settings open).
            openSettingsWindow()
            return nil
        case "settings-add":
            // Setup for the check: the Add Phone… row's action (the add sheet),
            // so the selection rule around it can be asserted. The row itself is
            // a Button whose action this is; a click cannot be synthesised on a
            // SwiftUI row in a quiet run.
            settingsAddRequest += 1
            return nil
        case "settings-forget":
            // Setup for the check: the same confirmation the page's Forget
            // button opens, for a phone the rows have already selected.
            guard let id = arguments.first,
                  let phone = rememberedPhones.first(where: { $0.id == id }) else { return "unknown phone" }
            beginForget(phone)
            return nil
        case "settings-select":
            // Setup for a check or a screenshot: the sidebar's own choose
            // transition for that page (a row click's path).
            guard let raw = arguments.first, let page = SettingsSelection(storeValue: raw) else {
                return "settings-select needs general|input|automation|phone:ID"
            }
            settingsRevealToken += 1
            settingsRevealRequest = SettingsReveal(selection: page, token: settingsRevealToken)
            return nil
        case "settings-report":
            // What the window renders (the e2e's assertions; a read of the real
            // view, never an action). The view writes the file on the next pass.
            guard let path = arguments.first, path.hasPrefix("/") else {
                return "settings-report needs an absolute PATH"
            }
            settingsReportPath = path
            settingsReportRequest += 1
            return nil
        case "settings-dump":
            // Settings' real window geometry (SettingsProbe) for the host e2e.
            guard let path = arguments.first, path.hasPrefix("/") else { return "missing path" }
            guard let window = SettingsProbe.settingsWindow() else {
                return "no settings window (\(SettingsProbe.windowList()))"
            }
            let label = arguments.count > 1
                ? arguments.dropFirst().joined(separator: " ")
                : "Reveal controls after"
            let report = SettingsProbe.report(window: window, lastRow: label)
            do {
                try report.write(toFile: path, atomically: true, encoding: .utf8)
            } catch {
                return "cannot write \(path)"
            }
            return nil
        default:
            return "unknown command \(command)"
        }
    }

    /// One key stroke through `NSApplication.sendEvent`, as the key window's
    /// dispatch would see a person's press (menu equivalents and local monitors
    /// included). The e2e's key checks use it for both the Deck and a stream
    /// window; the action under test is still the app's own key handling.
    private func sendKey(_ stroke: KeyStroke) -> String? {
        guard let window = NSApp.keyWindow else { return "no key window" }
        var flags: NSEvent.ModifierFlags = []
        if stroke.command { flags.insert(.command) }
        if stroke.shift { flags.insert(.shift) }
        if stroke.control { flags.insert(.control) }
        if stroke.option { flags.insert(.option) }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil,
                                               characters: stroke.characters,
                                               charactersIgnoringModifiers: stroke.characters,
                                               isARepeat: false, keyCode: stroke.keyCode) else {
                return "cannot make a \(type) event"
            }
            NSApp.sendEvent(event)
        }
        return nil
    }

    private func applyAutoOpen(_ options: LaunchOptions) {
        for pkg in options.openPackages { windows.openOrRaise(pkg: pkg) }
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

    /// The screenshot phones for the Devices prototypes (never the person's
    /// devices or names): one offline, one whose key is gone, and the packages
    /// the muted list draws. `--preview` only.
    private enum DevicesFixtures {
        static let others: [RememberedPhone] = [
            RememberedPhone(id: "preview-2", name: "Pixel 9", model: "Pixel 9",
                            lastSeen: Date().addingTimeInterval(-2 * 3600)),
            RememberedPhone(id: "preview-3", name: "Pixel 8", model: "Pixel 8",
                            lastSeen: Date().addingTimeInterval(-3 * 86_400)),
        ]
        static var presence: [String: DevicePresence] {
            ["preview-2": .offline(others[0].lastSeen), "preview-3": .pairAgain]
        }
        static let seen = ["preview.messages", "preview.whatsapp", "preview.camera",
                           "preview.spotify", "com.android.systemui"]
        static let muted = ["preview.whatsapp", "com.android.systemui"]
    }

    /// A preview state's remembered phones, written to this profile so the
    /// window behaves as it does for a paired Mac (pairing, forgetting, a
    /// relaunch). `--preview` only: the profile is the check's own.
    private func stage(_ phones: [RememberedPhone], active: String?) {
        remembered.removeAll()
        for phone in phones { remembered.remember(phone.ref, at: phone.lastSeen, makeActive: false) }
        if let active { remembered.setActive(id: active) }
        rememberedPhones = remembered.all
    }

    /// A staged preview's Settings window opens once the state is in place:
    /// bumping `settingsRequest` is the Deck scene's own route (⌘,).
    private func settingsSoon() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            self?.settingsRequest += 1
        }
    }

    /// `--preview NAME`: drives the UI with a scripted state, without sockets,
    /// the pair keys or the profile. Used for the screenshots of states that
    /// cannot be staged against a fake phone.
    private func applyPreview(_ name: String) {
        isPreview = true
        DevicesPreview.reset()
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
            stage([phone, RememberedPhone(id: other.id, name: other.name, model: other.model,
                                          lastSeen: Date().addingTimeInterval(-86_400 * 2))],
                  active: ref.id)
        // The Settings window's staged phones. They are written to this
        // profile's remembered list too, so forgetting one in a staging run
        // leaves the same state a paired Mac would (the sidebar's next phone)
        // and a relaunch reopens the same list.
        case "devices-zero":
            stage([], active: nil)
            welcomeSeen = true
            machine = LinkMachine(link: .idle)
            settingsSoon()
        case "devices-one":
            deck(.online(ref))
            stage([phone], active: ref.id)
            previewNotify[ref.id] = PreviewNotify(enabled: true, muted: Set(Self.DevicesFixtures.muted),
                                                  seen: Set(Self.DevicesFixtures.seen))
            settingsSoon()
        case "devices-three":
            deck(.online(ref))
            stage([phone] + Self.DevicesFixtures.others, active: ref.id)
            DevicesPreview.stagedPresence = Self.DevicesFixtures.presence
            previewNotify[ref.id] = PreviewNotify(enabled: true, muted: Set(Self.DevicesFixtures.muted),
                                                  seen: Set(Self.DevicesFixtures.seen))
            settingsSoon()
        case "devices-offline":
            deck(.offline(ref, .unreachable))
            stage([RememberedPhone(id: ref.id, name: ref.name, model: ref.model,
                                   lastSeen: Date().addingTimeInterval(-240))], active: ref.id)
            previewNotify[ref.id] = PreviewNotify(enabled: false, muted: [], seen: [])
            settingsSoon()
        case "devices-muted":
            deck(.online(ref))
            stage([phone], active: ref.id)
            previewNotify[ref.id] = PreviewNotify(enabled: true, muted: Set(Self.DevicesFixtures.muted),
                                                  seen: Set(Self.DevicesFixtures.seen))
            DevicesPreview.openMutedList = true
            settingsSoon()
        case "devices-rename":
            // The Settings ▸ Phones ▸ Rename dialog, staged for the screenshot.
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
