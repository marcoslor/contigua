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

    /// One connection record per phone, and the in-memory current id
    /// (docs/design/multi-phone.md §5.1; the persisted choice stays
    /// `RememberedPhones.active`).
    let book = PhoneBook()
    /// Preview runs have no session at all; their staged link lives here.
    private var previewMachine: LinkMachine?
    /// The phone a pairing sheet is driving; it is current while the sheet is
    /// up, so `link` and the code sheet read its record.
    private(set) var pairingDeviceId: String?
    /// Where a cancelled pairing goes back to.
    private var pairingResumeId: String?
    /// PAIR-33: a trust-lost phone that is not in range is the target of the
    /// open add-phone sheet; its row is marked when the phone appears.
    private(set) var addPhoneTarget: PhoneRef?

    /// The LinkMachine of the current phone (previews stage one without a
    /// session). Mutations go through `book`; the setter exists for previews.
    var machine: LinkMachine {
        get { previewMachine ?? book.current?.machine ?? LinkMachine() }
        set {
            if let current = book.current, previewMachine == nil { current.machine = newValue }
            else { previewMachine = newValue }
        }
    }
    /// The link the UI and every action reads: the current phone's record. A
    /// live session with no usable path is not online: requests would queue
    /// into the grace's dead session (PATH-17), so it reads as Reconnecting
    /// until a path joins or the session ends. The machine's own link is
    /// untouched, so no new attempt is started over the session the paths
    /// layer is trying to bring back.
    var link: Link {
        if let previewMachine { return previewMachine.link }
        return book.currentLink
    }
    var currentId: String? { book.currentId }
    /// [DECK-14/15] When the phone in use was last reached: the link machine's
    /// stamp, for the chip's help tag and the offline banner. Nil until this
    /// run has seen the phone and with no remembered sighting.
    var lastSeen: Date? { machine.lastSeen }
    var pathsDown: Bool { book.current?.pathsDown ?? false }
    var pathsOffline: Bool { book.current?.pathsOffline ?? false }
    var pathOutage: PathOutage { book.current?.pathOutage ?? .none }
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
    /// PANEL-26: the app in front, one read at a time. The machine ignores a
    /// reply for an older request; the reply's time is what the Phone menu's
    /// two-second freshness rule reads.
    private(set) var frontApp = FrontAppMachine()
    private(set) var frontAppRepliedAt: Date?
    @ObservationIgnored private var frontSeq = 0
    @ObservationIgnored private var frontWatchCount = 0
    @ObservationIgnored private var frontTimer: Timer?
    /// APK installs (docs/design/apk.md); the Deck shows its phase.
    let apkInstaller = ApkInstaller()
    /// Files dropped on a window (docs/design/dragdrop.md); windows show the pill.
    let dropSender = FileDropSender()
    /// SHARE-18: the one drag being resolved (image data, promise or link), its
    /// state machine and its per-gesture temp folder.
    @ObservationIgnored private lazy var dropFlow = DropSourceFlow()
    @ObservationIgnored private var pendingDropTarget: String?
    @ObservationIgnored private var pendingDropDeck = false
    @ObservationIgnored private var pendingDropRemote: URL?
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
    /// R1: one derivation for the Deck, the menu-bar panel and Settings.
    var presentation: LinkPresentation {
        LinkPresentation(link: link, naming: { self.displayName(for: $0) },
                         lastSeen: lastSeen)
    }

    var banner: Banner? {
        // PAIR-33: trust lost is sticky and cannot be covered by a transient
        // notice (a copy result, a launcher error): it is the one truth until
        // the phone is paired again or forgotten.
        if case .needsPairing = link,
           let trustLost = link.banner(naming: { displayName(for: $0) }, lastSeen: lastSeen) {
            return trustLost
        }
        // R2: a pairing sheet says the cooldown itself; the Deck behind it does
        // not repeat the sentence. With no sheet the banner carries it.
        if sheet != nil, case .pairing = link { return transientBanner }
        return transientBanner ?? link.banner(naming: { displayName(for: $0) },
                                              lastSeen: lastSeen)
    }

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
                        excluding: dockApps.shimPackages(deviceId: deviceId),
                        iconData: { IconCache.shared.renderedPNG(pkg: $0, deviceId: deviceId, px: 256) })
        dockApps.reconcile(deviceId: deviceId, apps: apps, phoneName: name,
                           keep: deviceId == link.phone?.id ? dockPkgsOfOpenWindows : [],
                           saveAll: SaveAllShortcutsSetting.read(from: profile.defaults, deviceId: deviceId))
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
    /// "Add to Applications" presses waiting for the Dock's 1296 px reply.
    private var pendingApplicationAdds: [String: (deviceId: String, pkg: String, label: String)] = [:]
    /// Save all work waiting for the Dock's icon or the one build slot, keyed
    /// by `{deviceId}/{pkg}`.
    private var shortcutWork: [String: ShortcutWork] = [:]
    /// A switch change bumps this; a step queued before it is dropped.
    private var shortcutGeneration: [String: Int] = [:]
    /// Dock-size icon requests in flight. Save all keeps at most four, so a
    /// phone with 230 apps is not asked for 230 icons at once.
    private var dockIconOutstanding: Set<String> = []
    /// Save all bundles being written right now.
    private var shortcutBuilding: Set<String> = []
    /// Phones whose Spotlight list needs one re-index when their builds finish.
    private var spotlightRefreshPending: Set<String> = []
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

    /// The popover's close request (`deckpanelclose`): a quiet run cannot
    /// dismiss it with a click, and a shot of the Deck must not carry it.
    private(set) var deckPanelCloseRequest = 0

    func closeDeckPanel() {
        deckPanelCloseRequest += 1
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

    /// The current phone's live session and timer (the UI's one phone). A
    /// specific phone's code uses its `PhoneSession` instead.
    private var session: Session? {
        get { book.current?.session }
        set { book.current?.session = newValue }
    }
    private var clipboardSync: ClipboardSync?
    private var tickTimer: Timer?
    private var launchAt = Date()
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
                            profile: profile, bindDelay: options.dockBindDelay ?? 0,
                            listenDelay: options.dockDebugListenDelay)
        windows = WindowManager(session: Session(endpoint: .hostPort(host: "127.0.0.1", port: 1),
                                                 knownDeviceId: nil, clientId: ""),
                                defaults: profile.defaults)
        welcomeSeen = remembered.welcomeSeen
        rememberedPhones = remembered.all
        audio.statsFile = options.audioStatsFile
        windows.onChange = { [weak self] in
            MainActor.assumeIsolated {
                self?.syncAudio()
                self?.windowSetChanged()
            }
        }
        windows.onDensityOverridesChanged = { [weak self] in
            MainActor.assumeIsolated { self?.refreshDensityOverrides() }
        }
        // The drop pill has one owner: the sender reports every phase, the
        // timeout included, and the windows only render what they are told.
        dropSender.onPhase = { [weak self] _ in
            MainActor.assumeIsolated { self?.syncDropPill() }
        }
        // SHARE-18: one drag resolves at a time; its folder lives until the
        // gesture's last result, a cancel or a session end.
        dropFlow.onFiles = { [weak self] files, folder in
            MainActor.assumeIsolated { self?.beginResolvedDrop(files, folder: folder) }
        }
        dropFlow.onRefuse = { [weak self] failure in
            MainActor.assumeIsolated { self?.refuseDrop(failure) }
        }
        dropFlow.onHide = { [weak self] in
            MainActor.assumeIsolated { self?.windows.setDropPill(nil) }
        }
        dropSender.onSettled = { [weak self] in
            MainActor.assumeIsolated { self?.dropFlow.settled() }
        }
        DropScratch.sweep()
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
        // NOTIFY-22: the banner's attachment carries the sending app's icon,
        // from the same cache the Deck and Dock draw.
        notifyCenter.iconFor = NotifyCenter.cachedIcon
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
        windows.frameLog = options.debugFrameLog.map(DebugFrameLog.init)
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
        windows.onFilesDropped = { [weak self] urls, target in
            MainActor.assumeIsolated { self?.dropFiles(urls, target: target) }
        }
        windows.onDropDrag = { [weak self] drag, target in
            MainActor.assumeIsolated { self?.dropSources(drag, target: target, deck: false) }
        }
        windows.onAppWindowOpened = { [weak self] pkg, stream in
            MainActor.assumeIsolated { self?.establishDockFollow(pkg: pkg, stream: stream) }
        }
        // The phone refused an extra window at its cap (WIN-32): the Deck says
        // so in the same words the menu item would have.
        windows.onTooManyWindows = { [weak self] sentence in
            MainActor.assumeIsolated { self?.showTransient(sentence) }
        }
        // Every window change re-reads the shim menus and the marks that follow
        // the key app (WIN-26, WIN-29) — see `windowSetChanged`.
        dockApps.onOpen = { [weak self] deviceId, pkg, pid in self?.openFromDock(deviceId: deviceId, pkg: pkg, pid: pid) }
        dockApps.onShimQuit = { [weak self] stream in self?.windows.controller(for: stream)?.window?.close() }
        // The Dock shim's secondary-click menu is the host's rows, rendered by
        // the shim (WIN-26); a pick comes back here.
        dockApps.windowMenu = { [weak self] deviceId, pkg in
            self?.windows.windowMenuRows(pkg: pkg, deviceId: deviceId) ?? []
        }
        dockApps.onPick = { [weak self] _, pkg, row in
            MainActor.assumeIsolated { self?.pickWindowMenuRow(row, pkg: pkg) }
        }
        dockApps.menuDebugDir = options.debugControl
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
            let saved = remembered.active.flatMap { remembered.trustLost(id: $0.id) }
            let seen = remembered.active.flatMap { remembered.phone(id: $0.id)?.lastSeen }
            apply(book.start(active: remembered.active?.ref, at: Date(), trustLost: saved,
                             lastSeen: seen))
            sendReachability()
        }
        // `--connect-phone`: an extra phone connects beside the current one and
        // is kept by the test hook, never by the current choice.
        for hook in options.connectPhones { connectHook(host: hook.host, port: hook.port) }
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
        isShuttingDown = true
        // A launch that has not started yet will never be seen: drop it now, so
        // no shim is built for a window that is going away with the app.
        for (stream, pending) in dockPendingLaunches where !pending.started {
            dockPendingLaunches[stream] = nil
            dockEstablishing.remove(pending.key)
        }
        // One already in flight may still hand us a pid; a launched shim that no
        // window owns is stopped with the app (docs/design/dock.md §Lifecycle).
        dockApps.quitUnboundLaunches()
        let deadline = Date().addingTimeInterval(3)
        while !dockPendingLaunches.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        dockApps.quitUnboundLaunches()
        mcp.stop()
        windows.beginShutdown()
        stopQR()
        for record in book.all {
            record.attemptTask?.cancel()
            record.attemptTask = nil
        }
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
        // Quit path only: give each teardown a bounded moment so the process
        // does not exit with a half-closed channel (arch H4).
        for record in book.all {
            record.session?.closeAndWait()
            record.session = nil
        }
        book.closeAll()
    }

    private func tick() {
        for id in book.records.keys { send(.tick, from: id) }
        if let record = book.current, case .down(let since, let offline) = record.pathOutage {
            let now = Date().timeIntervalSince(since) >= LinkMachine.offlineAfter
            if now != offline { record.pathOutage = .down(since: since, offline: now) }
        }
        if let qr, !qr.expired, !qr.succeeded, qr.payload.isExpired() { expireQR() }
        if audioStarted { audio.logStatsIfDue() }
        writePhonesReport()
    }

    /// `--phones-report FILE`: the e2e's view of the book. One header line and
    /// one row per phone; device ids only, never a name (privacy rule).
    private func writePhonesReport() {
        guard let path = options.phonesReport else { return }
        let all = book.all
        let online = all.filter(\.isOnline).count
        var lines = ["phones=\(all.count) online=\(online) current=\(book.currentId ?? "-")"]
        for record in all {
            let state: String
            switch record.link {
            case .idle: state = "idle"
            case .connecting: state = "connecting"
            case .online: state = "online"
            case .reconnecting: state = "reconnecting"
            case .offline(_, let cause): state = "offline:\(cause)"
            case .needsPairing: state = "needsPairing"
            case .pairing(_, let pairing): state = "pairing:\(pairing.token)"
            }
            lines.append("id=\(record.deviceId) state=\(state) current=\(record.deviceId == book.currentId ? 1 : 0)")
        }
        try? (lines.joined(separator: "\n") + "\n")
            .write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
    }

    /// The session's path layer lost or regained every path (`pathsReconnecting`).
    /// The windows switch at once; the panel follows the same two steps as a
    /// dropped link so a path outage is never shown as Connected (PANEL-12).
    private func setPathsDown(_ down: Bool, from record: PhoneSession) {
        if down {
            guard record.pathOutage == .none else { return }
            record.pathOutage = .down(since: Date(), offline: false)
        } else {
            record.pathOutage = .none
        }
        guard record.deviceId == book.currentId else { return }
        if down {
            windows.linkLost()
            // No banner, live row or attachment outlives the phone (the same
            // rule as a session close): the grace keeps the session for a
            // join, never the person's data.
            notifyCenter.clearAll()
        } else {
            windows.linkRestored()
        }
    }

    private func clearPathOutage() {
        book.current?.pathOutage = .none
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
        if let id = book.currentId { send(.tryNow, from: id) }
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

    /// R4: where a Pair Again came from, for the one ui log line.
    enum PairAgainSource: String { case deck, settings, menubar }

    /// "Pair again" on the banner: the remembered phone, if it is in range.
    func pairAgain(source: PairAgainSource = .deck) {
        guard let ref = link.phone else { return }
        pairAgain(for: ref, source: source)
    }

    /// PAIR-14/33/34: one route for the banner, the panel and the Settings page.
    /// A discovered phone runs the code flow (which forgets the old pin); a
    /// phone at its last welcome address is dialled there (R3: a trust-lost
    /// phone must be reachable again without a dead end); with neither, the one
    /// add-phone sheet opens with that phone as its target.
    func pairAgain(for ref: PhoneRef, source: PairAgainSource = .deck) {
        Log.app.notice("ui: pair-again source=\(source.rawValue, privacy: .public)")
        if let found = discovered.first(where: { $0.deviceId == ref.id }) {
            addPhoneTarget = nil
            beginPairing(.discovered(found), ref: ref)
        } else if let cached = cache.address(forDeviceId: ref.id) {
            forgetPinForPairAgain(ref)
            addPhoneTarget = nil
            beginPairing(.manual(host: cached.host, port: cached.port), ref: ref)
        } else {
            addPhoneTarget = ref
            sheet = .addPhone
        }
    }

    /// PAIR-14: a re-pair forgets the old pin, whether the phone was discovered
    /// or dialled at its last address.
    private func forgetPinForPairAgain(_ ref: PhoneRef) {
        guard !ref.id.isEmpty else { return }
        pins.forget(deviceId: ref.id)
        syncIdentityPinMirrorAfterForget(deviceId: ref.id)
    }

    func pairAgain(for phone: RememberedPhone, source: PairAgainSource = .settings) {
        pairAgain(for: phone.ref, source: source)
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
        guard isPairing, let id = pairingDeviceId ?? book.currentId,
              let record = book.record(for: id) else { return }
        // R4: the one ui line for a sheet the person closed (Cancel or Esc);
        // `sheetDismissed` re-enters here, and the guard makes it once.
        Log.app.notice("ui: pairing-sheet cancel")
        pairingTarget = nil
        pairingSucceeded = false
        if sheet == .code { sheet = nil }
        send(.cancelPairing, from: record)
        closeSession(deviceId: id)
        if record.claims.subtracting([.current]).isEmpty {
            book.removeRecord(id)
            if let resume = pairingResumeId {
                book.setCurrent(resume, phone: remembered.phone(id: resume)?.ref).forEach(perform)
                // R3: taking `current` for the pairing reset the resumed
                // phone's machine (it had no other claim). A trust-lost phone
                // must read Pair again again, not Idle (PAIR-32/33).
                if let ref = remembered.phone(id: resume)?.ref,
                   let kind = remembered.trustLost(id: resume) {
                    send(.restoreTrustLost(ref, kind), from: resume)
                }
            }
        }
        pairingDeviceId = nil
        pairingResumeId = nil
    }

    /// A sheet went away (Esc, Cancel, or programmatically): stop what it was running.
    func sheetDismissed() {
        addPhoneTarget = nil
        cancelPairing()
        if let qr, !qr.succeeded { stopQR() }
    }

    /// Settings ▸ Phones ▸ Use This Phone.
    func use(_ phone: RememberedPhone) {
        guard book.currentId != phone.id else { return }
        // The §3 mirror follows the phone in use: it is that phone's record
        // from here on, and the TLS layer checks the record itself.
        mirrorIdentityPin(deviceId: phone.id)
        remembered.setActive(id: phone.id)
        windows.closeAll()
        stopClipboardSync()
        book.setCurrent(phone.id, phone: phone.ref).forEach(perform)
        if let session = book.current?.session {
            windows.attach(session)
            startClipboardSync(on: session)
            session.enableClipboard(ClipboardSync.isEnabled(in: profile.defaults))
            session.requestApps()
        }
        resetPhoneData(for: phone.ref)
        rememberedPhones = remembered.all
    }

    /// The panel's phone pop-up (PANEL-27): switch the phone in use through the
    /// same route Settings' Use This Phone runs (SET-DEV-03).
    func usePhone(id: String) {
        guard let phone = remembered.phone(id: id) else { return }
        use(phone)
    }

    func forget(_ phone: RememberedPhone) {
        let wasActive = book.currentId == phone.id || remembered.active?.id == phone.id
        pins.forget(deviceId: phone.id)
        syncIdentityPinMirrorAfterForget(deviceId: phone.id)
        cache.forget(deviceId: phone.id)
        remembered.forget(id: phone.id)
        appsCache.remove(deviceId: phone.id)
        spotlight.remove(deviceId: phone.id)
        spotlightRefreshPending.remove(phone.id)
        SaveAllShortcutsSetting.write(false, for: phone.id, to: profile.defaults)
        dockApps.forget(deviceId: phone.id)
        shortcutGeneration[phone.id, default: 0] += 1
        shortcutWork = shortcutWork.filter { $0.value.deviceId != phone.id }
        shortcutBuilding = shortcutBuilding.filter { !$0.hasPrefix("\(phone.id)/") }
        dockRevision += 1
        rememberedPhones = remembered.all
        if book.record(for: phone.id) != nil {
            send(.forget(deviceId: phone.id), from: phone.id)
            disconnect(deviceId: phone.id)
        }
        if wasActive {
            windows.closeAll()
            apps = []
            appsLoaded = false
            status = nil
            if let next = remembered.active {
                resetPhoneData(for: next.ref)
                book.setCurrent(next.id, phone: next.ref).forEach(perform)
            }
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

    /// File ▸ New <App> Window (⌘N, the Dock shim's menu, the Deck cell's
    /// menu): one more window of the key app on the phone in use (WIN-25).
    /// Every other entry point raises (WIN-36).
    func newWindow() {
        guard link.isOnline, let pkg = windows.keyApp else { return }
        windows.openAdditional(pkg: pkg)
    }

    /// ⌘N pressed with one of the app's windows key: the same item's action.
    func newWindowActivity() { newWindow() }

    /// Window ▸ Next Window (⌘`): the key app's next window, wrapping
    /// (WIN-29, WIN-30). Nothing reaches the phone.
    func cycleWindow() {
        windows.cycleKeyWindow()
    }

    /// A Dock shim's or the Deck cell's menu row was picked (WIN-26).
    func pickWindowMenuRow(_ row: AppWindowMenuRow, pkg: String) {
        guard link.isOnline else { return }
        windows.pickWindowMenuRow(row, pkg: pkg)
    }

    /// The Deck cell's secondary-click menu for an app (WIN-26): the same rows
    /// the Dock shim shows, in the same order.
    func windowMenuRows(for pkg: String) -> [AppWindowMenuRow] {
        windows.windowMenuRows(pkg: pkg)
    }

    /// The set of open app windows changed (opened, closed, retitled, raised):
    /// every shim of those apps gets its new menu, and the Window menu's ⌘`
    /// item follows the key app's count at once (WIN-26, WIN-29).
    private func windowSetChanged() {
        MenuMarks.apply(to: NSApp.mainMenu)
        dockApps.refreshWindowMenus()
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

    // MARK: Foreground app (PANEL-26)

    /// A card opened: ask once now, then at most once every 2 s while it stays
    /// open. The count covers both hosts (the menu-bar panel and the Deck
    /// popover); the timer stops when the last one closes, so a closed card
    /// never reads the phone.
    func beginPanelFrontWatch() {
        frontWatchCount += 1
        guard frontWatchCount == 1 else { return }
        askFront()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.askFront() }
        }
        RunLoop.main.add(timer, forMode: .common)
        frontTimer = timer
    }

    func endPanelFrontWatch() {
        frontWatchCount = max(frontWatchCount - 1, 0)
        guard frontWatchCount == 0 else { return }
        frontTimer?.invalidate()
        frontTimer = nil
    }

    private func askFront() {
        guard link.isOnline, let session else { return }
        frontSeq += 1
        frontApp.ask(seq: frontSeq)
        session.requestFront(seq: frontSeq)
    }

    private func frontReplied(seq: Int, pkg: String?) {
        guard frontApp.reply(seq: seq, pkg: pkg) else { return }
        frontAppRepliedAt = Date()
        let presence = pkg == nil ? "none" : "present"
        Log.app.debug("front: \(presence, privacy: .public)")  // log-ok: only "present"/"none", never the package
    }

    /// A phone that cannot read its task list: no row, and the Phone menu's
    /// fallback keeps its old one-shot behaviour (the window reports the
    /// phone's own refusal).
    private func frontUnavailable() {
        guard case .asking = frontApp.state else { return }
        frontApp.reset()
        frontAppRepliedAt = Date()
        Log.app.debug("front: none")
    }

    /// No stale package across a link loss or a phone change. Bumping the
    /// sequence leaves any in-flight reply stale.
    private func resetFrontApp() {
        frontApp.reset()
        frontAppRepliedAt = nil
        frontSeq += 1
    }

    /// The panel's row: only while online and the machine knows a package.
    var frontAppRow: FrontAppRow? {
        guard link.isOnline, let pkg = frontApp.pkg else { return nil }
        let app = apps.first { $0.pkg == pkg }
        return FrontAppRow(pkg: pkg, label: app?.displayLabel, icon: deckIcons[pkg])
    }

    /// A reply no older than the Phone menu's two-second rule.
    var frontAppFresh: Bool { FrontAppFreshness.isFresh(frontAppRepliedAt) }
    var frontAppNone: Bool { frontApp.isNone }

    /// The Phone menu's handoff item: the app's name while a fresh reply names
    /// one, else the fallback the item must always have.
    var frontMenuTitle: String {
        guard frontAppFresh, let row = frontAppRow else { return FrontAppRow.fallbackTitle }
        return row.title
    }

    var frontMenuEnabled: Bool {
        link.isOnline && !(frontAppFresh && frontAppNone)
    }

    var frontMenuHelp: String? {
        guard link.isOnline else { return PanelUnavailable.offline.sentence }
        if frontAppFresh && frontAppNone { return FrontAppRow.nothingToOpen }
        return nil
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

    /// Whether the app's shim carries the Dock reason (Add to Dock): Save all
    /// and Add to Applications never make a tile's menu say Remove from Dock.
    func isInDock(_ app: AppInfo) -> Bool {
        _ = dockRevision
        guard let id = link.phone?.id else { return false }
        return dockApps.origins(deviceId: id, pkg: app.pkg).contains(.dock)
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
                        launch: true, origins: dockApps.origins(deviceId: phone.id, pkg: app.pkg).union(.dock)) == nil {
            showTransient("Couldn't add \(app.label) to the Dock.")
        }
        spotlightShortcutChanged(deviceId: phone.id, pkg: app.pkg)
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
                            phoneName: displayName(for: phone), launch: true,
                            origins: dockApps.origins(deviceId: add.deviceId, pkg: add.pkg).union(.dock)) == nil {
                showTransient("Couldn't add \(add.label) to the Dock.")
            }
            spotlightShortcutChanged(deviceId: add.deviceId, pkg: add.pkg)
            dockRevision += 1
        }
    }

    func removeFromDock(_ app: AppInfo) {
        guard let id = link.phone?.id else { return }
        removeDockOrigin(deviceId: id, pkg: app.pkg)
        dockRevision += 1
    }

    private func removeDockOrigin(deviceId: String, pkg: String) {
        let decision = DockOrigins.applying(.remove(.dock), to: dockApps.origins(deviceId: deviceId, pkg: pkg))
        switch decision.action {
        case .remove:
            dockApps.remove(deviceId: deviceId, pkg: pkg)
        case .write:
            // Another reason keeps the shortcut: only the Dock identity goes.
            let label = apps.first { $0.pkg == pkg }?.label ?? pkg
            if let phone = link.phone, phone.id == deviceId {
                dockApps.add(deviceId: deviceId, pkg: pkg, label: label, phoneName: displayName(for: phone),
                             launch: false, origins: decision.origins)
            }
            dockApps.quitIfUnbound(deviceId: deviceId, pkg: pkg)
        case .none:
            break
        }
        spotlightShortcutChanged(deviceId: deviceId, pkg: pkg)
    }

    // MARK: Application shortcuts (docs/design/dock.md §Shortcuts)

    /// Whether the app's shim carries the reason "Add to Applications".
    func hasManualShortcut(_ app: AppInfo) -> Bool {
        _ = dockRevision
        guard let id = link.phone?.id else { return false }
        return dockApps.origins(deviceId: id, pkg: app.pkg).contains(.manual)
    }

    var canAddToApplications: Bool { dockApps.isAvailable && link.phone != nil }

    /// This build carries the shim executable, so shortcuts can be made at all.
    var canMakeShortcuts: Bool { dockApps.isAvailable }

    /// "Add to Applications": adds `manual` and builds the shortcut, launching
    /// nothing — it is a Launchpad/Spotlight/launcher entry, not a window.
    func addToApplications(_ app: AppInfo) {
        guard let phone = link.phone, dockApps.isAvailable else { return }
        guard dockIconReady(pkg: app.pkg, deviceId: phone.id) else {
            pendingApplicationAdds["\(phone.id)/\(app.pkg)"] = (phone.id, app.pkg, app.label)
            requestDockIcon(app.pkg)
            return
        }
        installShortcut(deviceId: phone.id, pkg: app.pkg, label: app.label, phone: phone)
    }

    /// "Remove from Applications": removes only `manual`; a shim Save all or the
    /// Dock still asks for stays.
    func removeFromApplications(_ app: AppInfo) {
        guard let id = link.phone?.id else { return }
        let decision = DockOrigins.applying(.remove(.manual), to: dockApps.origins(deviceId: id, pkg: app.pkg))
        switch decision.action {
        case .remove:
            dockApps.remove(deviceId: id, pkg: app.pkg)
        case .write:
            if let phone = link.phone, phone.id == id {
                dockApps.add(deviceId: id, pkg: app.pkg, label: app.label, phoneName: displayName(for: phone),
                             launch: false, origins: decision.origins)
            }
        case .none:
            break
        }
        spotlightShortcutChanged(deviceId: id, pkg: app.pkg)
        dockRevision += 1
    }

    private func installShortcut(deviceId: String, pkg: String, label: String, phone: PhoneRef) {
        let origins = dockApps.origins(deviceId: deviceId, pkg: pkg).union(.manual)
        if dockApps.add(deviceId: deviceId, pkg: pkg, label: label, phoneName: displayName(for: phone),
                        launch: false, origins: origins) == nil {
            showTransient("Couldn't add \(label) to Applications.")
        }
        spotlightShortcutChanged(deviceId: deviceId, pkg: pkg)
        dockRevision += 1
    }

    // MARK: Spotlight's one entry per app (docs/specs/dock.md DOCK-9)

    /// A shim appeared or went away: an app with one is not a CoreSpotlight item
    /// too. A new shim takes its item out (cheap); a removed one puts the phone's
    /// list back in, without the apps that still have shims.
    private func spotlightShortcutChanged(deviceId: String, pkg: String) {
        if dockApps.hasShim(deviceId: deviceId, pkg: pkg) {
            spotlight.remove(deviceId: deviceId, pkg: pkg)
        } else {
            spotlightRefreshPending.insert(deviceId)
        }
        if shortcutBuilding.isEmpty { flushSpotlightRefreshes() }
    }

    /// Save all's batch ends: one exclusion pass for the whole batch, since each
    /// new shim already took its own item out.
    private func spotlightBatchFinished(deviceId: String) {
        spotlightRefreshPending.insert(deviceId)
        flushSpotlightRefreshes()
    }

    /// Save all off removes many bundles: one re-index when the last is gone.
    private func flushSpotlightRefreshes() {
        for deviceId in spotlightRefreshPending.sorted() {
            spotlightRefreshPending.remove(deviceId)
            refreshSpotlight(deviceId: deviceId)
        }
    }

    private func refreshSpotlight(deviceId: String) {
        guard let phone = remembered.phone(id: deviceId)?.ref else { return }
        let list = (link.phone?.id == deviceId && appsLoaded) ? apps : appsCache.load(deviceId: deviceId)
        guard !list.isEmpty else { return }
        spotlight.index(apps: list, deviceId: deviceId, phoneName: displayName(for: phone),
                        excluding: dockApps.shimPackages(deviceId: deviceId),
                        iconData: { IconCache.shared.renderedPNG(pkg: $0, deviceId: deviceId, px: 256) })
    }

    /// "Add to Applications" presses waiting for the Dock's 1296 px reply.
    private func runPendingApplicationAdds() {
        guard let phone = link.phone, !pendingApplicationAdds.isEmpty else { return }
        for key in pendingApplicationAdds.keys.sorted() {
            guard let add = pendingApplicationAdds[key], add.deviceId == phone.id,
                  dockIconReady(pkg: add.pkg, deviceId: add.deviceId) else { continue }
            pendingApplicationAdds[key] = nil
            installShortcut(deviceId: add.deviceId, pkg: add.pkg, label: add.label, phone: phone)
        }
    }

    // MARK: Save all (docs/design/dock.md §Shortcuts)

    /// One app's Save all work (a write or a remove), with the switch revision
    /// it was planned under.
    private struct ShortcutWork {
        var deviceId: String
        var pkg: String
        var label: String
        var origins: DockOriginSet
        var action: DockShimAction
        var generation: Int
    }

    /// The phone page's "Save all apps as shortcuts": per phone, off by default.
    func saveAllShortcuts(deviceId: String) -> Bool {
        SaveAllShortcutsSetting.read(from: profile.defaults, deviceId: deviceId)
    }

    /// The switch changed: store it and apply it. On adds `all` to every app of
    /// the phone; off removes only `all`, so a shim the Dock or the person keeps
    /// stays (rewritten).
    func setSaveAllShortcuts(_ on: Bool, for deviceId: String) {
        guard !deviceId.isEmpty else { return }
        SaveAllShortcutsSetting.write(on, for: deviceId, to: profile.defaults)
        shortcutGeneration[deviceId, default: 0] += 1
        shortcutWork = shortcutWork.filter { $0.value.deviceId != deviceId }
        queueSaveAll(deviceId: deviceId)
    }

    /// Plans the phone's apps against the shims on disk and queues what changed.
    /// On an offline phone the cached list is used; its icons wait for the
    /// connection, so the bundles keep what they have.
    private func queueSaveAll(deviceId: String) {
        let on = saveAllShortcuts(deviceId: deviceId)
        let list = (link.phone?.id == deviceId && appsLoaded) ? apps : appsCache.load(deviceId: deviceId)
        if on, list.isEmpty { return }
        let generation = shortcutGeneration[deviceId, default: 0]
        for step in DockSaveAll.plan(apps: list, records: dockApps.records(), deviceId: deviceId, on: on) {
            shortcutWork["\(deviceId)/\(step.pkg)"] = ShortcutWork(
                deviceId: deviceId, pkg: step.pkg, label: step.label, origins: step.origins,
                action: step.action, generation: generation)
        }
        pumpShortcutWork()
    }

    /// One build at a time, each when its icon has answered; at most four icon
    /// requests in flight (docs/design/dock.md §Shortcuts). The file work is on
    /// DockApps' queue, so the Deck never waits for 230 bundles.
    private func pumpShortcutWork() {
        guard !shortcutWork.isEmpty, let phone = link.phone else { return }
        for key in shortcutWork.keys.sorted() {
            guard let work = shortcutWork[key], !shortcutBuilding.contains(key) else { continue }
            guard work.deviceId == phone.id,
                  work.generation == shortcutGeneration[work.deviceId, default: 0] else {
                // Another phone's work waits for its connection; a superseded
                // switch change drops its own.
                if work.generation != shortcutGeneration[work.deviceId, default: 0] {
                    shortcutWork[key] = nil
                }
                continue
            }
            if work.action == .remove {
                shortcutWork[key] = nil
                shortcutBuilding.insert(key)
                dockApps.removeInBackground(deviceId: work.deviceId, pkg: work.pkg) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.shortcutBuilding.remove(key)
                        self.dockRevision += 1
                        self.spotlightShortcutChanged(deviceId: work.deviceId, pkg: work.pkg)
                        if work.generation != self.shortcutGeneration[work.deviceId, default: 0] {
                            self.queueSaveAll(deviceId: work.deviceId)
                        }
                        self.pumpShortcutWork()
                        // The last removal already put the phone's list back;
                        // this covers a pending removal left by an add batch.
                        if self.shortcutBuilding.isEmpty { self.flushSpotlightRefreshes() }
                    }
                }
            } else if dockIconReady(pkg: work.pkg, deviceId: work.deviceId) {
                shortcutWork[key] = nil
                shortcutBuilding.insert(key)
                let name = displayName(for: phone)
                dockApps.addInBackground(deviceId: work.deviceId, pkg: work.pkg, label: work.label,
                                         phoneName: name, origins: work.origins) { [weak self] ok in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.shortcutBuilding.remove(key)
                        if !ok { self.showTransient("Couldn't save \(work.label) as a shortcut.") }
                        else { Log.app.notice("dock: save all built \(work.pkg, privacy: .public)") }
                        self.dockRevision += 1
                        self.spotlightShortcutChanged(deviceId: work.deviceId, pkg: work.pkg)
                        // The switch changed while the bundle was being written:
                        // run the current plan again so no shim keeps a reason
                        // that was turned off (docs/design/dock.md §Shortcuts).
                        if work.generation != self.shortcutGeneration[work.deviceId, default: 0] {
                            self.queueSaveAll(deviceId: work.deviceId)
                        }
                        self.pumpShortcutWork()
                        if self.shortcutBuilding.isEmpty { self.spotlightBatchFinished(deviceId: work.deviceId) }
                    }
                }
            } else if !dockIconAsked.contains(work.pkg), dockIconOutstanding.count < 4 {
                Log.app.debug("dock: save all asks for \(work.pkg, privacy: .public) (\(self.dockIconOutstanding.count, privacy: .public) out)")
                requestDockIcon(work.pkg)
            }
        }
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
                         launch: false, origins: dockApps.origins(deviceId: phone.id, pkg: pkg).union(.dock))
            spotlightShortcutChanged(deviceId: phone.id, pkg: pkg)
        }
        if let pkg = options.dockRemove {
            removeDockOrigin(deviceId: phone.id, pkg: pkg)
        }
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

    /// An automatic launch that has not finished yet, for one window. The window
    /// can close before the build starts or before the shim is up; then the work
    /// is dropped or the pid is quit, never bound (docs/design/dock.md §Lifecycle).
    private struct DockPendingLaunch {
        var deviceId: String
        var pkg: String
        var started = false
        var windowClosed = false
        var key: String { "\(deviceId)/\(pkg)" }
    }

    /// Stream → its automatic launch while the build, launch or bind is pending.
    private var dockPendingLaunches: [UInt32: DockPendingLaunch] = [:]

    /// True from the start of shutdown: a launch that completes then is stopped
    /// instead of bound, and no window is reconsidered.
    private var isShuttingDown = false

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
        // Its identity may still be building or launching: mark the pending work
        // for the stream gone. A build that has not started is dropped; one that
        // has started still quits the pid it gets (dockLaunchFinished).
        if var pending = dockPendingLaunches[stream] {
            pending.windowClosed = true
            dockPendingLaunches[stream] = pending
            if !pending.started {
                dockPendingLaunches[stream] = nil
                dockEstablishing.remove(pending.key)
            }
        }
        if let (pid, pkg) = dockApps.binding(stream: stream),
           let next = DockWindowFollow.survivor(closing: stream, pkg: pkg,
                                                windows: windows.openAppWindows) {
            dockApps.rebind(pid: pid, to: next)
            return
        }
        dockApps.streamClosed(stream)
        // A dropped launch frees the app's in-flight key: another window of the
        // same app may have been waiting for it.
        recheckOpenWindows()
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
                self.dockApps.relaunch(deviceId: phone.id, pkg: pkg, label: label,
                                       phoneName: self.displayName(for: phone),
                                       bind: stream, launched: launched)
            }
        case .createAndLaunch:
            bindWhenDockCleared(deviceId: phone.id, pkg: pkg, stream: stream) { launched in
                self.dockApps.buildAndLaunch(
                    DockShimSpec(deviceId: phone.id, pkg: pkg, label: label, phoneName: self.displayName(for: phone),
                                 profile: self.profile, hostPath: Bundle.main.bundleURL.path,
                                 origins: self.dockApps.origins(deviceId: phone.id, pkg: pkg).union(.window)),
                    bind: stream, launched: launched)
            }
        }
    }

    /// Runs the launch and clears the in-flight key and binds the pid when it is up.
    private func bindWhenDockCleared(deviceId: String, pkg: String, stream: UInt32,
                                     work: @escaping (_ launched: @escaping (Int?) -> Void) -> Void) {
        dockEstablishing.insert("\(deviceId)/\(pkg)")
        dockPendingLaunches[stream] = DockPendingLaunch(deviceId: deviceId, pkg: pkg)
        let start = { [weak self] in
            guard let self, var pending = self.dockPendingLaunches[stream],
                  !pending.windowClosed else { return }
            pending.started = true
            self.dockPendingLaunches[stream] = pending
            work { pid in
                MainActor.assumeIsolated {
                    self.dockLaunchFinished(stream: stream, deviceId: deviceId, pkg: pkg, pid: pid)
                }
            }
        }
        // e2e: hold the build and launch back, so it lands after a window that
        // closes in the meantime (the load-dependent race, made deterministic).
        if let delay = options.dockLaunchDelay, delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { start() }  // gcd: e2e hold of the launch
        } else {
            start()
        }
    }

    /// The automatic launch finished. A pid for a window that is no longer open
    /// must quit at once: nothing would ever close that shim again, and it would
    /// outlive its window and the app (docs/design/dock.md §Lifecycle).
    private func dockLaunchFinished(stream: UInt32, deviceId: String, pkg: String, pid: Int?) {
        dockPendingLaunches[stream] = nil
        dockEstablishing.remove("\(deviceId)/\(pkg)")
        let landing = DockLaunch.landing(
            pid: pid,
            windowOpen: windows.openAppWindows.contains { $0.stream == stream },
            settingOn: showAppsInDock, pinned: dockApps.isPinned(deviceId: deviceId, pkg: pkg),
            quitting: isShuttingDown)
        switch landing {
        case .nothing:
            break
        case .bind:
            if let pid {
                // The phone is part of the binding: the shim's menu is looked up
                // by the record's device id (WIN-26), and a bind without one
                // sends no menu until the next window-set change.
                dockApps.bind(pid: pid, stream: stream, pkg: pkg, deviceId: deviceId)
                Log.app.notice("dock auto: bound shim \(pid, privacy: .public) to stream \(stream, privacy: .public)")
            }
        case .quitWindowClosed:
            if let pid { dockApps.quit(pid: pid) }
            Log.app.notice("dock auto: late launch for closed stream \(stream, privacy: .public) → quit")
        case .quitSettingOff:
            if let pid { dockApps.quit(pid: pid) }
        case .quitShuttingDown:
            if let pid { dockApps.quit(pid: pid) }
            Log.app.notice("dock auto: launch in flight at quit for stream \(stream, privacy: .public) → quit")
        }
        // The bundle exists on disk after any landing: its Spotlight item goes.
        spotlightShortcutChanged(deviceId: deviceId, pkg: pkg)
        if !isShuttingDown { recheckOpenWindows() }
    }

    /// The automatic path reconsiders every open app window: after the app list,
    /// the icons and the setting (a window may have waited for one of them).
    private func recheckOpenWindows() {
        guard !isShuttingDown else { return }
        for window in windows.openAppWindows {
            guard let pkg = window.pkg else { continue }
            establishDockFollow(pkg: pkg, stream: window.stream)
        }
    }

    private func appLabel(_ pkg: String) -> String? {
        windows.appsByPkg[pkg]?.label ?? apps.first { $0.pkg == pkg }?.label
    }

    /// One app of the phone in use, by package: the live list, else the cache.
    private func appInfo(_ pkg: String) -> AppInfo? {
        if let app = apps.first(where: { $0.pkg == pkg }) ?? windows.appsByPkg[pkg] { return app }
        guard let id = link.phone?.id else { return nil }
        return appsCache.load(deviceId: id).first { $0.pkg == pkg }
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
        if dockIconAsked.insert(pkg).inserted {
            dockIconOutstanding.insert(pkg)
            requestIcon(pkg, px: IconSizeClass.dock.layerPx)
        }
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

    func intentsOpenApp(_ pkg: String, on deviceId: String, newWindow: Bool = false) {
        if link.isOnline, link.phone?.id == deviceId {
            // Only an explicit new-window argument adds one (WIN-36).
            if newWindow {
                windows.openAdditional(pkg: pkg)
            } else {
                windows.openOrRaise(pkg: pkg)
            }
            return
        }
        pendingOpen = SpotlightOpenRequest(deviceId: deviceId, pkg: pkg, newWindow: newWindow)
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
        handleOnCurrent(.phoneState(locked: status?.locked ?? true,
                           battery: charging ? 42 : 87,
                           charging: charging,
                           dnd: status?.dnd,
                           ringer: status?.ringer,
                           volume: status?.volume,
                           volumeMax: status?.volumeMax,
                           screen: status?.screen,
                           secure: nil,
                           panel: nil))
        handleOnCurrent(.mediaState(MediaState(playing: charging,
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
    func dropFiles(_ urls: [URL], target: String?) {
        let files = urls.filter { $0.isFileURL }
        guard !files.isEmpty else { return }
        if files.count == 1, let app = files.first(where: { ApkBundle.kind(of: $0) != nil }) {
            installApk(app)
            return
        }
        dropSources(DropDrag(files: files), target: target, deck: false)
    }

    /// The Deck's general drop destination (SHARE-18): its own routes for an
    /// app bundle, a `.webloc` link and files, then the same source resolver.
    func dropDeck(_ drag: DropDrag) {
        guard !isPreview else { return }
        let routes = DeckDropRouter.actions(drag)
        if let app = routes.install { installApk(app) }
        for link in routes.links { openLink(OpenLinkRequest(url: link.absoluteString)) }
        if !routes.files.isEmpty {
            beginResolvedDrop(routes.files, folder: nil, target: nil)
        } else if routes.generated {
            resolveDrop(drag, target: nil, deck: true)
        } else if let url = routes.download {
            // A link on the Deck keeps today's route even while the phone is
            // away; only a live phone can turn its image answer into a drop.
            if link.isOnline, session != nil {
                resolveDrop(drag, target: nil, deck: true)
            } else {
                openLink(OpenLinkRequest(url: url.absoluteString))
            }
        }
    }

    /// SHARE-18's entry point: D1 picks the source, the resolver materialises it
    /// into the gesture's temp folder, and the existing drop path sends it.
    private func dropSources(_ drag: DropDrag, target: String?, deck: Bool) {
        guard !isPreview else { return }
        if drag.files.count == 1, let app = drag.files.first(where: { ApkBundle.kind(of: $0) != nil }) {
            installApk(app)
            return
        }
        guard DropSourceOrder.choose(drag) != .none else { return }
        resolveDrop(drag, target: target, deck: deck)
    }

    private func resolveDrop(_ drag: DropDrag, target: String?, deck: Bool) {
        guard link.isOnline, session != nil else {
            showTransient("Connect a phone to send files to it.")
            return
        }
        guard !dropFlow.isReady, dropFlow.phase != .resolving, !dropSender.isBusy else {
            dropSender.busy()
            return
        }
        pendingDropTarget = target
        pendingDropDeck = deck
        pendingDropRemote = drag.remote
        windows.setDropFailure(nil)
        if DropSourceOrder.choose(drag) == .files {
            beginResolvedDrop(drag.files, folder: nil, target: target)
        } else {
            windows.setDropPill(("Sending…", true))
            dropFlow.start(drag)
        }
    }

    /// The flow's own hand-off uses the target recorded for this drag.
    private func beginResolvedDrop(_ files: [URL], folder: URL?) {
        beginResolvedDrop(files, folder: folder, target: pendingDropTarget)
    }

    private func beginResolvedDrop(_ files: [URL], folder: URL?, target: String?) {
        guard !files.isEmpty else { return }
        guard link.isOnline, let session else {
            DropScratch.remove(folder)
            showTransient("Connect a phone to send files to it.")
            return
        }
        dropSender.send(files, session: session, target: target)
    }

    private func refuseDrop(_ failure: DropResolveFailure) {
        if pendingDropDeck {
            if failure == .notImage, let url = pendingDropRemote {
                openLink(OpenLinkRequest(url: url.absoluteString))
            } else if failure != .cancelled {
                showTransient(failure.text)
            }
            return
        }
        windows.setDropFailure(failure.token)
        dropSender.refuse(failure.text, outcome: .phone("source_\(failure.token)"))
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
        resetFrontApp()
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
        let endpoints = Dictionary(uniqueKeysWithValues: discovered.map { ($0.deviceId, $0.endpoint) })
        discovered = phones
        searchedLong = false
        scheduleSearchedLong()
        for record in book.all {
            let id = record.deviceId
            let found = phones.first { $0.deviceId == id }
            let changed = found != nil && (!before.contains(id) || endpoints[id] != found?.endpoint)
            if changed, let ref = record.phone, !ref.id.isEmpty {
                send(.reachabilityHint, from: record)
            }
            send(.reachability(advertised: found != nil,
                               hasAddress: cache.address(forDeviceId: id) != nil,
                               changed: changed), from: record)
        }
        if qr != nil { qrRound() }
    }

    /// PAIR-31/35: the advertised record and the last welcome address as the
    /// link machine needs them (a change of schedule, no new dial of its own).
    private func sendReachability() {
        for record in book.all {
            let id = record.deviceId
            send(.reachability(advertised: discovered.contains { $0.deviceId == id },
                               hasAddress: cache.address(forDeviceId: id) != nil,
                               changed: false), from: record)
        }
    }

    private func discoveryDenied(_ denied: Bool) {
        browseDenied = denied
        if denied {
            for id in book.records.keys { send(.localNetworkDenied, from: id) }
        } else {
            tryNowIfDenied()
        }
    }

    private func tryNowIfDenied() {
        if case .offline(let phone, .localNetworkDenied) = link, let id = book.currentId {
            send(.activate(phone), from: id)
        }
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
        for id in book.records.keys { send(.reachabilityHint, from: id) }
    }

    // MARK: Link plumbing

    /// The only way a phone's machine is driven: runs its actions, then reacts
    /// to the new link when that phone is current.
    private func send(_ event: LinkEvent, from record: PhoneSession) {
        apply(book.handle(event, from: record.deviceId, at: Date()))
        syncTrustLoss(record)
    }

    /// PAIR-32: the one write point. The machine decides; the remembered record
    /// keeps the kind so a relaunch starts in it. Welcome and Forget clear it.
    private func syncTrustLoss(_ record: PhoneSession) {
        let id = record.deviceId
        guard !id.isEmpty else { return }
        if let kind = record.machine.trustLossKind {
            if remembered.trustLost(id: id) != kind { remembered.setTrustLost(kind, id: id) }
        } else if remembered.trustLost(id: id) != nil {
            remembered.clearTrustLost(id: id)
        }
    }

    private func send(_ event: LinkEvent, from id: String) {
        guard let record = book.record(for: id) else { return }
        send(event, from: record)
    }

    func apply(_ result: PhoneBookEventResult) {
        for action in result.actions { perform(action) }
        // R4: one line per machine step, closed tokens only. The pairing
        // record is current while its sheet is up, so a cooldown step logs.
        if result.affectsCurrent, let step = result.transition {
            // Closed state tokens, never a person's value (R-PRIV-1 reads the
            // names: `state`/`tag` are the lint's own safe words).
            let fromState = step.from.token
            let eventTag = step.event.token
            let toState = step.to.token
            Log.app.notice("link: \(fromState, privacy: .public) --\(eventTag, privacy: .public)--> \(toState, privacy: .public)")
        }
        guard result.affectsCurrent else { return }
        if case .pairing = link, qr == nil { sheet = .code }
        if isPairing {
            if pairingStartedAt == nil { pairingStartedAt = Date() }
        } else {
            pairingStartedAt = nil
        }
        if result.currentLinkLost {
            windows.linkLost()
            dropFlow.sessionEnded()
            dropSender.connectionLost()
            windows.pasteSessionEnded()
            clipImageBuffer.discard()
        }
        if result.currentLinkRestored { windows.linkRestored() }
        // PAIR-30/33: a phone that lost trust has no session, so no window may
        // keep saying Reconnecting; the windows go and the banner is the one
        // truth. A generic pairing failure (kind nil) keeps today's down window.
        if result.affectsCurrent, case .needsPairing = link, machine.trustLossKind != nil {
            windows.closeAll()
        }
        // A window that was opening during the one-shot transition follows
        // the current Link value too: the zombie-service case left it on
        // "Not responding" while the link was already retrying. A pairing
        // failure is neither down nor online: the one-shot linkLost above is
        // the truth, and restoring here would put a live window over no session.
        if link.isDown, !windows.linkIsDown { windows.linkLost() }
        if link.isOnline, windows.linkIsDown { windows.linkRestored() }
        if let down = link.windowDesiredDown { windows.reconcileLinkDown(down) }
        writePhonesReport()
    }

    private func perform(_ action: PhoneBookAction) {
        switch action {
        case .connect(let id): connect(deviceId: id)
        case .close(let id): closeSession(deviceId: id)
        case .attempt(let id, let delay): scheduleAttempt(after: delay, for: id)
        case .stopAttempts(let id): stopAttempts(deviceId: id)
        case .startPairing: break
        }
    }

    /// Connect or resume one phone without making it current (the
    /// `--connect-phone` hook and a switch to a phone that has no session).
    func connect(deviceId: String) {
        guard let record = book.record(for: deviceId), record.session == nil else { return }
        let ref = record.phone ?? PhoneRef(id: deviceId, name: "Phone", model: "")
        send(.activate(ref), from: record)
    }

    /// Close one phone's session and forget its record; every other phone stays.
    func disconnect(deviceId: String) {
        guard book.record(for: deviceId) != nil else { return }
        closeSession(deviceId: deviceId)
        book.removeRecord(deviceId)
    }

    private func scheduleAttempt(after delay: TimeInterval, for id: String) {
        guard let record = book.record(for: id) else { return }
        record.attemptTask?.cancel()
        record.attemptTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.runAttempt(from: id)
        }
    }

    private func stopAttempts(deviceId: String) {
        guard let record = book.record(for: deviceId) else { return }
        record.attemptTask?.cancel()
        record.attemptTask = nil
    }

    /// Close one phone's session; the clipboard is the current phone's only.
    private func closeSession(deviceId: String) {
        guard let record = book.record(for: deviceId) else { return }
        stopAttempts(deviceId: deviceId)
        if deviceId == book.currentId { stopClipboardSync() }
        record.session?.close()
        record.session = nil
        record.pathOutage = .none
    }

    private func runAttempt(from id: String) {
        guard let record = book.record(for: id) else { return }
        record.attemptTask = nil
        guard let ref = record.machine.link.phone, !isPairing(on: id) else { return }
        // A preempted attempt that has not authenticated is cancelled, never leaked.
        if let session = record.session, session.state != .ready { session.close() }
        if record.session?.state == .ready { return }
        // A test profile never dials a Bonjour-discovered phone on its own:
        // discovery would find the real phones on this Mac's LAN (DialPolicy).
        let found = DialPolicy.mayDialDiscovered(profile)
            ? discovered.first { $0.deviceId == ref.id } : nil
        let known = ref.id.isEmpty || ref.id.hasPrefix("hook:") ? nil : ref.id
        if found == nil, let hook = record.hookEndpoint {
            record.lastAttemptWasService = false
            let endpoints = [Session.Endpoint.hostPort(host: hook.host, port: hook.port)]
            start(Session(endpoint: endpoints[0], endpoints: endpoints,
                          knownDeviceId: known, clientId: clientId,
                          identity: identity, pinnedPhone: pins.record(for: ref.id),
                          pinStore: pins,
                          onPinEstablished: { [weak self] record in self?.mirrorIdentityPin(record: record) }),
                  for: record, policy: .allowed)
            return
        }
        if found == nil, let connect = options.connect, id == book.currentId {
            record.lastAttemptWasService = false
            let endpoints = manualEndpoints(connect)
            start(Session(endpoint: endpoints[0], endpoints: endpoints,
                          knownDeviceId: known, clientId: clientId,
                          identity: identity, pinnedPhone: pins.record(for: ref.id),
                          pinStore: pins,
                          onPinEstablished: { [weak self] record in self?.mirrorIdentityPin(record: record) }),
                  for: record, policy: .never)
            return
        }
        let cached = cache.address(forDeviceId: ref.id)
        let choice = EndpointPlanner().choose(discovered: found != nil, cached: cached,
                                              lastAttemptWasService: record.lastAttemptWasService,
                                              lastAttemptFailed: record.lastAttemptFailed,
                                              sinceLaunch: Date().timeIntervalSince(launchAt))
        let endpoint: Session.Endpoint
        var strict: String?
        switch choice {
        case .service:
            guard let found else { return }
            // After a failed service attempt, try the other interface policy.
            if record.lastAttemptFailed, record.lastAttemptWasService { record.pinInterface.toggle() }
            endpoint = .service(found.endpoint, pinnedTo: record.pinInterface ? found.interface : nil)
            record.lastAttemptWasService = true
        case .cached(let address):
            endpoint = .hostPort(host: address.host, port: address.port)
            strict = ref.id
            record.lastAttemptWasService = false
        case .wait(let seconds):
            scheduleAttempt(after: seconds, for: id)
            return
        case .none:
            noEndpoint(from: id)
            return
        }
        start(Session(endpoint: endpoint, knownDeviceId: known, strictDeviceId: strict,
                      clientId: clientId, identity: identity, pinnedPhone: pins.record(for: ref.id),
                      pinStore: pins,
                      onPinEstablished: { [weak self] record in self?.mirrorIdentityPin(record: record) }),
              for: record, policy: .never)
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
    private func noEndpoint(from id: String) {
        book.record(for: id)?.lastAttemptFailed = true
        send(.attemptFailed(reason: "timeout"), from: id)
    }

    private var isPairing: Bool {
        if let id = pairingDeviceId { return isPairing(on: id) }
        guard let record = book.current else { return false }
        if case .pairing = record.machine.link { return true }
        return false
    }

    private func isPairing(on id: String) -> Bool {
        guard let record = book.record(for: id) else { return false }
        if case .pairing = record.machine.link { return true }
        return false
    }

    private func start(_ newSession: Session, for record: PhoneSession, policy: Session.PairingPolicy) {
        let isCurrent = record.deviceId == book.currentId
        if isCurrent { stopClipboardSync() }
        record.pathOutage = .none
        record.session?.close()
        record.session = newSession
        newSession.pairingPolicy = policy
        if isCurrent { windows.attach(newSession) }
        newSession.onEvent = { [weak self, weak newSession, weak record] event in
            MainActor.assumeIsolated {
                guard let self, let newSession, let record, record.session === newSession else { return }
                self.handle(event, from: record)
            }
        }
        newSession.onVideoEvent = { [weak self, weak newSession, weak record] event in
            guard let self, let newSession, let record,
                  record.deviceId == self.book.currentId,
                  record.session === newSession else { return }
            self.windows.handleVideo(event, from: newSession)
        }
        newSession.onAudioEvent = { [weak self, weak newSession, weak record] event in
            guard let self, let newSession, let record,
                  record.deviceId == self.book.currentId,
                  record.session === newSession else { return }
            switch event {
            case .config(let config): self.audio.configure(config)
            case .frame(let frame): self.audio.receive(frame)
            }
        }
        newSession.start()
    }

    // MARK: Pairing

    private func beginPairing(_ target: PairingTarget, ref: PhoneRef) {
        addPhoneTarget = nil
        pairingTarget = target
        pairingSucceeded = false
        // A retry runs from the previous attempt's provisional record; the
        // phone to go back to on Cancel is the one before the first attempt.
        if book.currentId?.hasPrefix("hook:pair-") != true {
            pairingResumeId = book.currentId
        }
        windows.closeAll()
        stopClipboardSync()
        // A person re-running the pairing revokes the old pin here (§7): the
        // next connect lands in pairing mode (no record, no §3 mirror).
        if case .discovered(let phone) = target {
            pins.forget(deviceId: phone.deviceId)
            syncIdentityPinMirrorAfterForget(deviceId: phone.deviceId)
        }
        let id: String
        let endpoint: Session.Endpoint
        let known: String?
        switch target {
        case .discovered(let phone):
            id = phone.deviceId
            endpoint = .service(phone.endpoint, pinnedTo: phone.interface)
            known = phone.deviceId
        case .manual(let host, let port):
            id = "hook:pair-\(host):\(port)"
            endpoint = .hostPort(host: host, port: port)
            known = nil
        }
        pairingDeviceId = id
        // The pairing record is current while the sheet is up; a previous
        // phone stays live only while another claim names it.
        book.setCurrent(id, phone: ref.id.isEmpty ? nil : ref, connect: false).forEach(perform)
        let record = book.ensureRecord(for: id, phone: ref.id.isEmpty ? nil : ref)
        record.claims.insert(.current)
        sheet = .code
        send(.beginPairing(ref), from: record)
        start(Session(endpoint: endpoint, knownDeviceId: known, clientId: clientId,
                      identity: identity, pinnedPhone: nil, pinStore: pins,
                      onPinEstablished: { [weak self] record in self?.mirrorIdentityPin(record: record) },
                      connectTimeout: connectTimeout, pairingTimeout: pairingTimeout),
              for: record, policy: .allowed)
    }

    /// `--connect-phone host:port`: dial one more phone without making it
    /// current. A remembered phone is resumed from its own cached address and
    /// pin; an unknown endpoint starts under a provisional id and takes the
    /// phone's own id from `welcome`. The test-hook claim keeps it live across
    /// switches (PAIR-24/PAIR-25).
    private func connectHook(host: String, port: UInt16) {
        let cached = cache.devices.first { $0.address.host == host && $0.address.port == port }
        let id = cached?.deviceId ?? "hook:\(host):\(port)"
        let ref = remembered.phone(id: id)?.ref ?? PhoneRef(id: id, name: host, model: "")
        let record = book.ensureRecord(for: id, phone: ref)
        record.hookEndpoint = (host, port)
        book.addClaim(.testHook, to: id, phone: ref).forEach(perform)
    }

    /// `--connect host:port`: the test entry point. The session may pair (the
    /// phone's Allow is the only step) or reconnect with a pin. A remembered
    /// active phone is reused only when the endpoint is its cached address;
    /// otherwise the session starts under an empty id and learns the phone's
    /// id from `welcome` (the second phone of the `phones` check).
    private func beginManualLaunch(host: String, port: UInt16) {
        let active = remembered.active
        let cached = active.flatMap { cache.address(forDeviceId: $0.id) }
        let samePhone = cached?.host == host && cached?.port == port
        let ref = samePhone ? (active?.ref ?? PhoneRef(id: "", name: host, model: ""))
                            : PhoneRef(id: "", name: host, model: "")
        let record = book.ensureRecord(for: ref.id, phone: ref.id.isEmpty ? nil : ref)
        book.setCurrent(ref.id, phone: ref.id.isEmpty ? nil : ref, connect: false).forEach(perform)
        record.claims.insert(.current)
        // `--connect` is the test hook: it dials even when the record says trust
        // was lost (a normal launch is what PAIR-32's relaunch check proves).
        send(.launch(ref), from: record)
        stopAttempts(deviceId: ref.id)
        sendReachability()
        if qr != nil { return } // the QR probes own the first handshake
        startManual(host: host, port: port, ref: ref, record: record)
    }

    /// The test-only second provider rides beside the LAN one (PATH-20/§10).
    private func manualEndpoints(_ connect: (host: String, port: UInt16)) -> [Session.Endpoint] {
        var endpoints = [Session.Endpoint.hostPort(host: connect.host, port: connect.port)]
        if let second = options.connect2 {
            endpoints.append(.hostPort(host: second.host, port: second.port))
        }
        return endpoints
    }

    private func startManual(host: String, port: UInt16, ref: PhoneRef, record: PhoneSession) {
        let endpoints = manualEndpoints((host, port))
        start(Session(endpoint: endpoints[0], endpoints: endpoints,
                      knownDeviceId: ref.id.isEmpty ? nil : ref.id,
                      clientId: clientId, identity: identity, pinnedPhone: pins.record(for: ref.id),
                      pinStore: pins,
                      onPinEstablished: { [weak self] record in self?.mirrorIdentityPin(record: record) },
                      connectTimeout: connectTimeout, pairingTimeout: pairingTimeout,
                      debugNoMarginSwitch: options.debugNoMarginSwitch),
              for: record, policy: .allowed)
    }

    // MARK: Session events

    /// One session's events. Link-bearing events update that phone's record
    /// for every phone; everything else reaches the one-phone surfaces only
    /// when the event came from the current phone (PAIR-26).
    private func handle(_ event: SessionEvent, from record: PhoneSession) {
        switch event {
        case .state(.failed, let detail):
            record.pathOutage = .none
            attemptEnded(reason: detail ?? "closed", from: record)
        case .ready(let info, _, let address):
            ready(info, address: address, from: record)
            return
        case .pathsReconnecting(let on):
            setPathsDown(on, from: record)
            return
        default:
            break
        }
        guard record.deviceId == book.currentId else { return }
        handleCurrent(event)
    }

    private func handleOnCurrent(_ event: SessionEvent) {
        if let record = book.current { handle(event, from: record) }
    }

    private func handleCurrent(_ event: SessionEvent) {
        switch event {
        case .state(let state, _):
            switch state {
            case .failed(let reason):
                clearPathOutage()
                resetFrontApp()
                stopClipboardSync()
                apkInstaller.connectionLost()
                dropFlow.sessionEnded()
                dropSender.connectionLost()
                windows.pasteSessionEnded()
                fsClient?.connectionLost()
                filesBridgeClient?.connectionLost()
                filesBridgeClient = nil
                FilesBridge.shared.detach()
                filesDomain.sessionReady(false)
                clipImageBuffer.discard()
                shareInbox.connectionLost()
                nowPlaying.clear()
                notifyCenter.clearAll()
            case .closed:
                clearPathOutage()
                resetFrontApp()
                stopClipboardSync()
                apkInstaller.connectionLost()
                dropFlow.sessionEnded()
                dropSender.connectionLost()
                windows.pasteSessionEnded()
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
        case .pathsSwitched:
            if let session { windows.requestKeyframes(from: session) }
        case .versionRefused(let sentence):
            // PATH-1: name which app to update; the retry loop stops below on
            // the `version` failure and `retriesAutomatically` says no.
            // A version mismatch is not a blip: keep the sentence that names
            // the app to update up long enough to read (PATH-1).
            showTransient(sentence, seconds: 30)
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
            _ = id
            clipImageBuffer.discard()
        case .clipImageDone(let id, let ok):
            // The phone wrote the clip (SHARE-16): the flow that owns the id
            // sends its one paste key, or shows why it did not.
            windows.clipImageDone(id: id, ok: ok)
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
            shareInbox.fileAbort(id: id)
        case .fsItems(let id, let page, let digest, let items):
            fsClient?.items(id: id, page: page, digest: digest, items: items)
            filesBridgeClient?.items(id: id, page: page, digest: digest, items: items)
        case .fsItem(let id, let item):
            fsClient?.item(id: id, item: item)
            filesBridgeClient?.item(id: id, item: item)
        case .fsDigest(let id, let digests):
            fsClient?.digests(id: id, values: digests)
            filesBridgeClient?.digests(id: id, values: digests)
        case .fsData(let id, let bytes):
            fsClient?.data(id: id, bytes: bytes)
            filesBridgeClient?.data(id: id, bytes: bytes)
        case .fsReadEnd(let id, let size, let sha256):
            fsClient?.readEnd(id: id, size: size, sha256: sha256)
            filesBridgeClient?.readEnd(id: id, size: size, sha256: sha256)
        case .fsThumbEnd(let id, let mime, let size, let sha256):
            fsClient?.thumbEnd(id: id, mime: mime, size: size, sha256: sha256)
            filesBridgeClient?.thumbEnd(id: id, mime: mime, size: size, sha256: sha256)
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
                // NOTIFY-4: the name suffixes a banner title only with 2+
                // phones paired; with one the app's own words are enough.
                phonesPaired: rememberedPhones.count,
                labelFor: { [weak self] in self?.labelFor($0) ?? nil },
            )
        case .notifyImage(let id, let mime, let w, let h, let data):
            notifyCenter.image(id: id, mime: mime, width: w, height: h, data: data)
        case .notifyRemoved(let id):
            notifyCenter.remove(id: id)
        case .notifySnapshot(let ids):
            // NOTIFY-1: the active set after a rejoin. The posts before it
            // already added or updated the rows; this drops what it lacks.
            notifyCenter.snapshot(ids: ids)
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
            if let askedPx, IconSizeClass.forRequest(askedPx) == .dock {
                dockIconOutstanding.remove(pkg)
                Log.app.debug("dock: icon answered for \(pkg, privacy: .public) (\(self.dockIconOutstanding.count, privacy: .public) still out)")
            } else if askedPx == nil {
                Log.app.debug("dock: icon answered with no request for \(pkg, privacy: .public)")
            }
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
            runPendingApplicationAdds()
            pumpShortcutWork()
            recheckOpenWindows()
        case .frontApp(let seq, let pkg):
            frontReplied(seq: seq, pkg: pkg)
        case .phoneState(let locked, let battery, let charging, let dnd, let ringer, let volume,
                         let volumeMax, let screen, let secure, let panel):            status = PhoneStatus(locked: locked, battery: battery, charging: charging, dnd: dnd, ringer: ringer,
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
            if let id = pairingDeviceId ?? book.currentId { send(.pairApproved, from: id) }
        case .qrPaired(let deviceId):
            finishQRPairing(deviceId: deviceId, name: session?.phone?.name)
        case .identityMismatch(let expected, let actual):
            Log.session.notice("dropping cached address for \(expected, privacy: .public) (answers as \(actual, privacy: .public))")
            cache.forget(deviceId: expected)
        case .phoneError(let code, _, let stream):
            if code == "not_available", stream == 0 {
                // `task.front` on a phone that cannot read its task list:
                // the row stays off; the Phone menu keeps its fallback.
                frontUnavailable()
            } else if code == "nothing_to_continue" {
                // The window never opened: it goes away, the notice is what stays.
                windows.closeFailedHandoff(stream: stream)
                showTransient("Nothing to move. Your phone is showing its home screen or PocketDeck.")
            } else if code == "launch_failed" {
                showTransient(ConnectionFailure.message(for: code) ?? "Something went wrong.")
            } else if stream == 0 && (code == "unavailable" || code == "bad_request") {
                // `phone.panel` refused: the phone never turned its screen off.
                windows.failPhonePanelRequest()
            }
            // `no_stream` is never a launcher notice (WIN-38): WindowManager
            // handles it by the window's state, and with no window it is only
            // logged. The gate in Session means it should not arrive at all.
        default:
            break
        }
        windows.handle(event)
    }

    private func attemptEnded(reason: String, from record: PhoneSession) {
        record.lastAttemptFailed = true
        var mapped = reason
        if reason == "pin-mismatch" {
            // PAIR-31: a pin mismatch is the same phone with a new identity
            // when the advertised TXT id says so (the only same-device proof
            // before TLS), otherwise a foreign phone at a stale address.
            let advertised = discovered.contains { $0.deviceId == record.deviceId }
            if TrustLoss.sameDevice(dialedService: record.lastAttemptWasService,
                                    advertised: advertised) {
                Log.session.notice("trust lost: inferred for \(record.deviceId, privacy: .public)")
            } else {
                mapped = "foreign-pin"
                if let id = record.phone?.id, !id.isEmpty {
                    Log.session.notice("dropping cached address for \(id, privacy: .public) (the TLS pin refuses it)")
                    cache.forget(deviceId: id)
                    sendReachability()
                }
            }
        }
        send(.attemptFailed(reason: mapped), from: record)
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

    private func ready(_ info: PhoneInfo, address: CachedAddress?, from record: PhoneSession) {
        if record.deviceId != info.id {
            let provisional = record.deviceId
            let wasCurrent = provisional == book.currentId
            if let displaced = book.adopt(record, as: info.id) {
                // The same phone under two ids: the older record's session is
                // closed here, never left running with no owner.
                displaced.attemptTask?.cancel()
                displaced.attemptTask = nil
                displaced.session?.close()
                displaced.session = nil
                if !wasCurrent, info.id == book.currentId, let session = record.session {
                    windows.attach(session)
                }
            }
            if pairingDeviceId == provisional { pairingDeviceId = info.id }
        }
        let ref = PhoneRef(id: info.id, name: info.name, model: info.model)
        let isCurrent = record.deviceId == book.currentId
        let wasPairing = isPairing(on: record.deviceId)
        record.phone = ref
        record.lastAttemptFailed = false
        remembered.remember(ref, makeActive: isCurrent)
        rememberedPhones = remembered.all
        markWelcomeSeen()
        if let address {
            cache.store(address, deviceId: info.id)
            cache.store(name: info.name, deviceId: info.id)
        }
        send(.welcome(ref), from: record)
        sendReachability()
        guard isCurrent else { return }
        // A successful connect (a fresh pairing or an enforced reconnect):
        // the §3 mirror is this phone's record from now on.
        mirrorIdentityPin(deviceId: info.id)
        readyCurrent(info, ref: ref, wasPairing: wasPairing)
    }

    /// The one-phone surfaces, only for the current phone (PAIR-25/PAIR-26).
    private func readyCurrent(_ info: PhoneInfo, ref: PhoneRef, wasPairing: Bool) {
        layerRefresh.reset()
        iconRequests = [:]
        dockIconAsked = []
        dockIconOutstanding = []
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
            if request.newWindow {
                windows.openAdditional(pkg: request.pkg)
            } else {
                windows.openOrRaise(pkg: request.pkg)
            }
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
            dockApps.reconcile(deviceId: ref.id, apps: list, phoneName: displayName(for: ref),
                               keep: dockPkgsOfOpenWindows,
                               saveAll: SaveAllShortcutsSetting.read(from: profile.defaults, deviceId: ref.id))
            queueSaveAll(deviceId: ref.id)
            // An app with a shim is listed by Launchpad/Spotlight/a launcher as the
            // real app, so it is not a CoreSpotlight item too (DOCK-9).
            spotlight.index(apps: list, deviceId: ref.id, phoneName: displayName(for: ref),
                            excluding: dockApps.shimPackages(deviceId: ref.id),
                            iconData: { IconCache.shared.renderedPNG(pkg: $0, deviceId: ref.id, px: 256) })
        }
        runDockHooks()
        runPendingDockAdds()
        runPendingApplicationAdds()
        recheckOpenWindows()
        // An open-app intent needs the live list (a fresh profile has no cache).
        runPendingDebugIntents(immediateOnly: false)
    }

    private func codeShown(deviceId: String?, code: String) {
        guard let id = pairingDeviceId ?? book.currentId,
              let record = book.record(for: id) else { return }
        let ref = record.phone ?? PhoneRef(id: deviceId ?? "", name: "your phone", model: "")
        send(.codeShown(ref, code: code), from: record)
        sheet = .code
    }

    private func showTransient(_ text: String, seconds: TimeInterval = 5) {
        transientBanner = Banner(text: text, action: nil)
        transientTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.transientBanner = nil }
        }
        transientTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)  // gcd: the banner's dismissal timer
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
        // `deckdrop PATH`: the Deck's own drop handler, which carries no app
        // window and so no share target (SHARE-17).
        debugInput?.deckDrop = { [weak self] urls in
            MainActor.assumeIsolated { self?.dropFiles(urls, target: nil) }
        }
        // `deckdropimage`/`deckdropurl`: the Deck's SHARE-18 sources.
        debugInput?.deckDropDrag = { [weak self] drag in
            MainActor.assumeIsolated { self?.dropDeck(drag) }
        }
        // The dockapps action writes the setting the way Settings'
        // @AppStorage does, then calls the same handler its onChange does.
        debugInput?.dockApps = { [weak self] on in
            MainActor.assumeIsolated { self?.setShowAppsInDock(on) }
        }
        debugInput?.shortcutsAll = { [weak self] on in
            MainActor.assumeIsolated {
                guard let self, let phone = self.link.phone else { return }
                self.setSaveAllShortcuts(on, for: phone.id)
            }
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
        case "activate":
            // Setup for a real-key check: bring the app front without touching
            // its windows, so a CGEvents key reaches its menu equivalents.
            BackgroundMode.activateApp()
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
        case "resize-drag":
            // A whole drag on the first window's own live-resize path, one
            // step a display refresh: a quiet run cannot post real mouse
            // events (the person's pointer must not move).
            guard arguments.count >= 4, let amount = Double(arguments[1]),
                  let steps = Int(arguments[2]), let stepMs = Int(arguments[3]) else {
                return "resize-drag needs right|bottom|top AMOUNT STEPS STEP_MS"
            }
            guard let window = windows.controller(for: 1) else { return "no first window" }
            return window.debugResizeDrag(edge: arguments[0], amount: CGFloat(amount),
                                          steps: steps, stepMs: stepMs)
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
            // report what happened while it was up (MenuTrack.swift). An
            // optional ITEM names a row to hover (the WIN-27 shots): the menu
            // is positioned so that row is at a known point, which is written
            // to POINT_PATH for the check's real pointer move.
            guard arguments.count >= 3, arguments[0].hasPrefix("/"),
                  let seconds = Double(arguments[2]) else {
                return "menutrack needs PATH View/Density SECONDS [ITEM POINT_PATH]"
            }
            var hover: String?
            var hoverPath: String?
            if arguments.count > 3 {
                guard arguments.count >= 5, let last = arguments.last, last.hasPrefix("/") else {
                    return "menutrack needs PATH MENU SECONDS ITEM POINT_PATH"
                }
                hoverPath = last
                hover = arguments[3..<(arguments.count - 1)].joined(separator: " ")
            }
            return MenuTrack.start(path: arguments[0], itemPath: arguments[1], seconds: seconds,
                                   hover: hover, hoverPath: hoverPath)
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
            // A real right click on a cell (multiwin's WIN-26 shot) opens its
            // context menu only when the Deck's app is already front: the
            // click that activates a background app is used up activating it.
            // An automatic Dock shim can hold the front after a window launch.
            // Background mode keeps the person's front app (no activation).
            BackgroundMode.activateApp()
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
        case "deckcellpoint":
            // The cell's own place in Quartz coordinates (a read): the check
            // posts a real right click there, so the cell's menu is the one a
            // person's click opens (WIN-26).
            guard arguments.count == 2, let path = arguments.last, path.hasPrefix("/") else {
                return "deckcellpoint needs LABEL /absolute/path"
            }
            guard DeckWindow.window != nil else { return "no deck window" }
            guard let point = DeckCellClick.centre(label: arguments[0]) else {
                return "no Deck cell labelled \(arguments[0])"
            }
            let text = "\(point.x) \(point.y)\n"
            return (try? text.write(toFile: path, atomically: true, encoding: .utf8)) == nil
                ? "deckcellpoint failed" : nil
        case "deckmenu":
            // The cell's own context menu, through a secondary click at its
            // drawn place (for the quiet screenshots; setup, not a check).
            guard !arguments.isEmpty else { return "deckmenu needs an app label" }
            guard let deck = DeckWindow.window else { return "no deck window" }
            return DeckCellClick.menu(label: arguments.joined(separator: " "), in: deck)
        case "shortcut", "dock":
            // The tile's menu actions (docs/specs/dock.md DOCK-3/4): a context
            // menu cannot be clicked in a quiet run, so the check runs the same
            // controller action the item runs, by package. Setup for the e2e.
            guard arguments.count >= 2, ["add", "remove"].contains(arguments[0]) else {
                return "\(command) needs add|remove PKG"
            }
            guard let app = appInfo(arguments[1]) else { return "no app \(arguments[1])" }
            if command == "dock" {
                arguments[0] == "add" ? addToDock(app) : removeFromDock(app)
            } else {
                arguments[0] == "add" ? addToApplications(app) : removeFromApplications(app)
            }
            return nil
        case "shortcutsall":
            // The phone page's Save all switch, through the same write-then-
            // apply path its binding runs (setup for the e2e).
            guard let raw = arguments.first, ["on", "off"].contains(raw) else {
                return "shortcutsall needs on|off"
            }
            guard let phone = link.phone else { return "no phone" }
            setSaveAllShortcuts(raw == "on", for: phone.id)
            return nil
        case "shortcutstats":
            // Save all's own counters (the e2e's diagnosis when a build stalls):
            // counts and package names, never a label.
            guard let path = arguments.first, path.hasPrefix("/") else {
                return "shortcutstats needs an absolute PATH"
            }
            let text = """
            pending=\(shortcutWork.count)
            building=\(shortcutBuilding.count)
            asked=\(dockIconAsked.count)
            outstanding=\(dockIconOutstanding.count)
            pending_keys=\(shortcutWork.keys.sorted().joined(separator: ","))
            building_keys=\(shortcutBuilding.sorted().joined(separator: ","))
            asked_keys=\(dockIconAsked.sorted().joined(separator: ","))
            outstanding_keys=\(dockIconOutstanding.sorted().joined(separator: ","))
            """
            do { try text.write(toFile: path, atomically: true, encoding: .utf8) } catch { return "cannot write \(path)" }
            return nil
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
        case "livedump":
            // The menu bar's LIVE section at an arbitrary moment (the notify
            // and path checks read the rows before and after an outage).
            guard let path = arguments.first, path.hasPrefix("/") else {
                return "livedump needs an absolute PATH"
            }
            return writeLiveDump(path) ? nil : "livedump could not write \(path)"
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
        case "deckpanelclose":
            // Closing it again: a quiet run cannot click outside the popover,
            // and the Deck's own shots must not carry it.
            closeDeckPanel()
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
        case "menupick":
            // One of the app's own menu items, by title path: the item's
            // target and action after the same validation an open menu runs
            // (`DebugInput`'s script verb; here for a check that reads the bar
            // between two steps). Titles carry spaces, so the path is the rest
            // of the line.
            let path = arguments.joined(separator: " ")
            guard !path.isEmpty, path.contains("/") else { return "menupick needs a title path" }
            NSApp.mainMenu?.update()
            MainActor.assumeIsolated { MenuMarks.apply(to: NSApp.mainMenu) }
            guard let item = DebugInputDriver.menuItem(at: path, in: NSApp.mainMenu) else {
                return "no item at \(path)"
            }
            guard item.isEnabled else { return "item disabled at \(path)" }
            guard let action = item.action else { return "item has no action at \(path)" }
            NSApp.sendAction(action, to: item.target, from: item)
            return nil
        case "windowmenu":
            // The Deck cell's (and the Dock shim's) rows for an app, as the one
            // menu rule builds them (WIN-26). A quiet run cannot right-click a
            // Deck cell, so the check reads the rows here and drives the raise
            // through the shim's own menu item.
            guard arguments.count == 2, arguments[0].hasPrefix("/") else {
                return "windowmenu needs PATH and PKG"
            }
            let rows = windows.windowMenuRows(pkg: arguments[1]).map(\.message)
            guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]) else {
                return "windowmenu failed"
            }
            return (try? data.write(to: URL(fileURLWithPath: arguments[0]), options: .atomic)) == nil
                ? "windowmenu failed" : nil
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
        case "panelfocus":
            // The item holding the card's keyboard focus (PANEL-7): where the
            // opening ring landed, which a quiet run reads instead of pressing
            // a key into a non-activating panel.
            guard arguments.count == 1, let item = PanelProbe.focusedItem(host: arguments[0]) else {
                return "panelfocus needs HOST"
            }
            return item
        case "gearhold":
            // How long the gear's menu stays open in a quiet run: the run
            // cannot press Escape, so the menu closes itself (PANEL-3).
            guard arguments.count == 1, let seconds = Double(arguments[0]) else {
                return "gearhold needs SECONDS"
            }
            guard let menuBar = MenuBarController.current else { return "no menu bar item" }
            menuBar.holdGearMenu(seconds: seconds)
            return nil
        case "gearanchor":
            // The frame the card's gear anchors its menu to, without opening it
            // (PANEL-3). The hosted card is the one a quiet run has open.
            if let rect = PanelProbe.gearAnchor() {
                return "gear \(Int(rect.minX)) \(Int(rect.minY)) \(Int(rect.width)) \(Int(rect.height))"
            }
            guard let menuBar = MenuBarController.current else { return "no menu bar item" }
            return menuBar.menuAnchorDescription()
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
        case "deckzoom":
            // The Deck's zoom step, for a run that wants 125 %: the same store
            // ⌘+ / ⌘− write, which the grid follows.
            guard let raw = arguments.first, let value = Double(raw) else {
                return "deckzoom needs a value"
            }
            Profile.active.defaults.set(value, forKey: DeckZoom.key)
            return nil
        case "deckzoomwindow":
            // The Deck's standard zoom (DECK-24): the same AppKit path the
            // green button and a title-bar double-click take, so
            // windowWillUseStandardFrame answers it.
            guard let window = DeckWindow.window else { return "no Deck window" }
            window.zoom(nil)
            return nil
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
        case "deck-screen":
            // The visible frame of the screen the Deck window is on, "W H" in
            // points: the standard zoom takes that height, and the key window
            // is not the Deck in a quiet run (DECK-24).
            guard let path = arguments.first, path.hasPrefix("/") else {
                return "deck-screen needs PATH"
            }
            guard let screen = DeckWindow.window?.screen ?? NSScreen.main else { return "no screen" }
            let visible = screen.visibleFrame
            let line = "\(Int(visible.width.rounded())) \(Int(visible.height.rounded()))\n"
            return (try? line.write(toFile: path, atomically: true, encoding: .utf8)) == nil
                ? "deck-screen failed" : nil
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
        if let previous = book.currentId { disconnect(deviceId: previous) }
        let record = book.ensureRecord(for: ref.id, phone: ref)
        book.setCurrent(ref.id, phone: ref, connect: false).forEach(perform)
        record.claims.insert(.current)
        // The probe's socket has to be gone first: the phone serves one session.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.resetPhoneData(for: ref)
                self.send(.activate(ref), from: record)
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
        func deck(_ link: Link, loaded: Bool = true, noApps: Bool = false, battery: Int = 87,
                  charging: Bool = false, locked: Bool = true) {
            rememberedPhones = [phone]
            welcomeSeen = true
            apps = noApps ? [] : (loaded ? PreviewData.apps : [])
            appsLoaded = loaded
            icons = PreviewData.icons
            missingIcons = PreviewData.iconless
            // A preview shows the offline banner's last-seen line: five
            // minutes ago, a fixed sighting the shot can read.
            machine = LinkMachine(link: link, lastSeen: Date().addingTimeInterval(-5 * 60))
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
        case "code-denied": pairingSheet(.denied(until: Date().addingTimeInterval(30)))
        case "code-cooling": pairingSheet(.coolingDown(until: Date().addingTimeInterval(23)))
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
        case "no-apps": deck(.online(ref), noApps: true)
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
        case "devices-trust-lost":
            // The Settings render (PAIR-32/34): the current phone's record says
            // trust was lost, so the header offers Pair Again….
            deck(.needsPairing(ref))
            stage([phone, RememberedPhone(id: other.id, name: other.name, model: other.model,
                                          lastSeen: Date().addingTimeInterval(-86_400 * 2))],
                  active: ref.id)
            remembered.setTrustLost(.told, id: ref.id)
            rememberedPhones = remembered.all
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
