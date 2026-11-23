// Owns the stream-id allocator and routes session events to the right window.
// One Mac window per stream; several app windows can be open at once.

import AppKit

final class WindowManager {
    private(set) var session: Session
    private var nextStream: UInt32 = 1
    private var streams: [UInt32: StreamWindowController] = [:]
    /// Guards `streams`: video is routed from the session queue, windows are
    /// created and destroyed on the main queue.
    private let lock = NSLock()

    var appsByPkg: [String: AppInfo] = [:]
    private(set) var icons: [String: NSImage] = [:]
    /// Streams whose first frame has reached this window (the opening cover's
    /// end); touched on the session queue under `lock`.
    private var firstFrameNoted: Set<UInt32> = []
    /// Streams the phone answered `window.opened` for, with the display's
    /// `w`×`h` it made (MCP-41, MCP-100).
    private var phoneOpened: [UInt32: (width: Int, height: Int)] = [:]
    /// An MCP open waiting on its window (MCP-41): one per call, by stream.
    private var openWatches: [UInt32: [(id: Int, client: MCPClientID?, feed: (MCPActMachine.Event) -> Void)]] = [:]
    private var nextOpenWatch = 0
    var phone: PhoneInfo?
    /// The active phone's display name (its nickname, else its own name):
    /// app and link window titles carry it — "WhatsApp (Nicky)".
    private(set) var phoneName = ""

    /// The phone's cap on app windows at once (`state.maxWindows`, WIN-32); a
    /// phone that reports none counts as 4. It counts every app stream on the
    /// phone — the Phone Mirror is a separate encoder and is not counted.
    private(set) var maxWindows = 4
    static let defaultMaxWindows = 4

    /// The windows front to back, as the person sees them: maintained here
    /// rather than read from `NSApp.orderedWindows` so the Window menu, ⌘` and
    /// the tests share one order (WIN-29, WIN-30).
    private var frontOrder: [UInt32] = []

    /// Fired when the set of open windows or the icon cache changes.
    var onChange: (() -> Void)?

    /// Fired once per window that closed, whoever closed it (Dock apps follow their window).
    var onStreamClosed: ((UInt32) -> Void)?
    /// MCP-84: the person's pointer or keys reached a window (StreamWindow).
    var onPersonInput: ((UInt32) -> Void)?
    /// The Mac closed a stream window itself; true when `close_window` did.
    var onMacClosed: ((UInt32, MCPClientID?) -> Void)?

    /// Fired when a stream id is handed out (F4): a reused id must forget any
    /// refs a closed window left behind.
    var onStreamAllocated: ((UInt32) -> Void)?

    /// Fired when a phone-app window becomes dockable (docs/design/dock.md
    /// §Lifecycle): app windows at open, link windows once the phone reports
    /// the package that displays the link. pkg, stream.
    var onAppWindowOpened: ((String, UInt32) -> Void)?

    /// Test hook (`--float-windows`): new stream windows float above other apps.
    var floatWindows = false
    /// Where the stream windows write their header state (e2e), if anywhere.
    var chromeStateFile: URL?

    /// Test hook (`--dump-video`): the streams' H.264 written to disk.
    var videoDump: VideoDump?

    /// Test hook (`--debug-frame-log`): one line per frame a window received,
    /// with the path it arrived on.
    var frameLog: DebugFrameLog?

    /// The phone's clock offset, for the windows' capture→local delays. nil
    /// until a pong carried `now` (an older phone sends none).
    var clockOffsetUs: Double? { session.phoneClockOffsetUs }

    /// The session-wide `stream.stats` switch: on with the first window, off
    /// with the last (StatsSubscription).
    private var statsSubscription = StatsSubscription()

    /// Files a Finder drag dropped on a stream window (docs/design/dragdrop.md).
    /// The second argument is the app window's package (SHARE-17); the Deck, a
    /// phone-mode window and a link window pass nil. The owner
    /// (ConnectionController) routes them; an .apk keeps its own route.
    var onFilesDropped: (([URL], String?) -> Void)?

    /// A drag carrying SHARE-18's sources (image data, a promise, a link) or
    /// files; the owner resolves it before the file-drop sender runs.
    var onDropDrag: ((DropDrag, String?) -> Void)?

    /// Set while the app is terminating so windows stop emitting pause/resume.
    private(set) var shuttingDown = false

    func beginShutdown() { shuttingDown = true }

    /// The controller owns one `Session` per attempt; windows outlive them and
    /// talk to whichever is current.
    func attach(_ session: Session) {
        lock.lock(); self.session = session; lock.unlock()
        statsSubscription.sessionEnded()
    }

    /// True while the link is down: stream windows show a "Reconnecting…" pill
    /// over their last frame and drop input (docs/design/mac-redesign.md §3.7).
    /// The phase is the phone's, shared by every window and the New items
    /// ("Reconnecting…" after 1 s, "Phone offline" after 15 s; WIN-16, WIN-34).
    private(set) var linkPhase = PhoneLinkPhase.up
    private var linkClock = LinkPhaseClock()
    private var linkOfflineTimer: Timer?
    var linkIsDown: Bool { linkPhase != .up }

    /// The one drop time every window counts from. A window opened mid-outage
    /// must not restart the 15 s: it reads this, not its own open time (R5).
    var linkDownAt: TimeInterval? { linkClock.downAt }

    /// A window of an app was refused because the phone is at its cap: the
    /// Deck's banner carries the same sentence the New item would (WIN-32).
    var onTooManyWindows: ((String) -> Void)?

    func linkLost() {
        linkLost(at: ProcessInfo.processInfo.systemUptime)
    }

    /// The clock-explicit half, so a test drives the two steps without waiting.
    func linkLost(at time: TimeInterval) {
        guard !shuttingDown else { return }
        linkClock.linkLost(at: time)
        publishLinkPhase()
        for controller in allControllers() { controller.setLinkDown(true, at: time) }
        // The one timer behind "Phone offline": a one-shot per phase change, so
        // no window or menu keeps a second copy of the rule.
        linkOfflineTimer?.invalidate()
        linkOfflineTimer = nil
        let current = ProcessInfo.processInfo.systemUptime
        if let next = linkClock.nextChange(at: current) {
            let timer = Timer(timeInterval: max(next.at - current, 0),
                              repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.linkPhaseTicked() }
            }
            RunLoop.main.add(timer, forMode: .common)
            linkOfflineTimer = timer
        }
    }

    func linkRestored() {
        linkOfflineTimer?.invalidate()
        linkOfflineTimer = nil
        linkClock.linkRestored()
        publishLinkPhase()
        for controller in allControllers() { controller.setLinkDown(false) }
    }

    /// Reconcile every window against the Link value, not the manager's phase:
    /// a window can miss the one-shot transition (it opened during the drop,
    /// or a pairing failure arrived between the edge and this call). The
    /// caller decides the desired state; nil leaves windows untouched.
    func reconcileLinkDown(_ down: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let time = down ? (linkClock.downAt ?? now) : now
        for controller in allControllers() where controller.isLinkDown != down {
            if down {
                controller.setLinkDown(true, at: time)
            } else {
                controller.setLinkDown(false, at: time)
            }
        }
    }

    /// A window opening while the link is down counts from the shared drop,
    /// not from its own opening, so its 1 s/15 s agree with the panel (R5).
    func markLinkDown(_ controller: StreamWindowController) {
        guard let downAt = linkClock.downAt else { return }
        controller.setLinkDown(true, at: downAt)
    }

    private func linkPhaseTicked() {
        linkPhaseTicked(at: ProcessInfo.processInfo.systemUptime)
    }

    /// The clock-explicit tick: the New items say "Phone offline" once 15 s
    /// have passed since the drop.
    func linkPhaseTicked(at time: TimeInterval) {
        linkClock.tick(at: time)
        publishLinkPhase()
    }

    private func publishLinkPhase() {
        guard linkPhase != linkClock.phase else { return }
        linkPhase = linkClock.phase
        onChange?()
    }

    /// `state.maxWindows`: the phone's cap, 4 when it sends none (WIN-32).
    func setMaxWindows(_ value: Int?) {
        maxWindows = max(1, value ?? Self.defaultMaxWindows)
        onChange?()
    }

    /// `power.locked`: the phone's own power press with app streams up. Every
    /// app and link window holds its last frame for the watchdog's grace; the
    /// phone mirror is display 0 itself, so its picture is genuinely gone with
    /// the panel and says so.
    func powerLocked() {
        for controller in allControllers() where !(controller is PhoneWindowController) {
            controller.powerLocked()
        }
    }

    /// The drop pill's state on every stream window; nil hides them all. Kept
    /// here too, so a window opened mid-transfer starts with it.
    func setDropPill(_ state: (text: String, showsProgress: Bool)?) {
        dropPill = state
        for controller in allControllers() { controller.setDropPill(state) }
    }

    private var dropPill: (text: String, showsProgress: Bool)?
    /// The last source refusal's closed token, written into the chrome state so
    /// the e2e can name it without ever logging a message (SHARE-18).
    private var dropFailure: String?

    func setDropFailure(_ token: String?) {
        dropFailure = token
        for controller in allControllers() { controller.setDropFailure(token) }
    }

    /// The phone wrote a clipboard image (SHARE-16): the window whose paste
    /// flow owns that id sends its one key, or shows the fallback pill.
    func clipImageDone(id: UInt32, ok: Bool) {
        for controller in allControllers() { controller.clipImageDone(id: id, ok: ok) }
    }

    /// Every window's paste flow stops waiting when the session goes.
    func pasteSessionEnded() {
        for controller in allControllers() { controller.pasteSessionEnded() }
    }

    private let frames: UserDefaults
    private var cascadePoint = NSPoint.zero
    private static let framesKey = "streamFrames"
    private static let showTouchesKey = "showTouches"
    /// Settings ▸ Input "Hover over Android apps".
    static let hoverKey = "input.hover"
    /// Whether this Mac has a trackpad decides the Show Touches default; read
    /// once, before the menu state seeds itself.
    private let hasTrackpad: Bool

    init(session: Session, defaults: UserDefaults = .standard) {
        self.session = session
        frames = defaults
        hasTrackpad = TrackpadPresence.anyTrackpad()
        styleStore = WindowStyleStore(defaults: defaults)
        densityStore = WindowDensityStore(defaults: defaults)
        StreamMenuState.shared.showTouches = ShowTouchesDefault.resolve(
            hasTrackpad: hasTrackpad, stored: defaults.object(forKey: Self.showTouchesKey) as? Bool)
        StreamMenuState.shared.settingsDensity = WindowDensity.value(in: defaults)
        StreamMenuState.shared.revealDelay = RevealDelay.stored(in: defaults)
        observeKeyWindows()
    }

    /// The View menu's Window Style: toggle/switch the key stream window's
    /// style directly (the menu cannot rely on the responder chain delivering
    /// a nil-target action). The menu tracks the key stream window itself: a
    /// pick or a ⌥⌘F while the Deck is key must never reach the window behind
    /// it (ISS-88, MENU-9).
    private var keyStreamController: StreamWindowController? {
        guard StreamMenuState.shared.hasStream, let stream = keyStream else { return nil }
        return controller(for: stream) as? StreamWindowController
    }

    func toggleKeyWindowStyle() {
        keyStreamController?.toggleStyleMenuAction(nil)
    }

    func setKeyWindowStyle(_ style: WindowStyle) {
        keyStreamController?.setStyle(style)
    }

    // MARK: Placement

    func savedFrame(forKey key: String) -> NSRect? {
        guard let raw = (frames.dictionary(forKey: Self.framesKey) as? [String: String])?[key] else { return nil }
        let rect = NSRectFromString(raw)
        return rect.isEmpty ? nil : rect
    }

    func saveFrame(_ frame: NSRect, forKey key: String) {
        var all = frames.dictionary(forKey: Self.framesKey) as? [String: String] ?? [:]
        all[key] = NSStringFromRect(frame)
        frames.set(all, forKey: Self.framesKey)
    }

    // MARK: Chrome preferences

    /// The per-package style keys (WindowStyleStore) over this profile's defaults.
    let styleStore: WindowStyleStore

    /// The per-package density overrides (WindowDensityStore), same scheme.
    let densityStore: WindowDensityStore

    /// Fired when a density override is added, changed or cleared (Settings →
    /// General lists them).
    var onDensityOverridesChanged: (() -> Void)?

    /// Settings → General "Default window density": what apps without an
    /// override use.
    var defaultDensity: Double { WindowDensity.value(in: frames) }

    /// Every app's override for Settings → General "App overrides".
    var densityOverrides: [DensityOverride] {
        densityStore.all().map { DensityOverride(pkg: $0.key, value: $0.value) }
            .sorted { $0.pkg < $1.pkg }
    }

    /// Settings → General's density changed: every window of an app without an
    /// override takes it at once, and the View ▸ Density Default item's label
    /// follows.
    func defaultDensityChanged() {
        StreamMenuState.shared.settingsDensity = defaultDensity
        for controller in allControllers() { controller.defaultDensityChanged() }
    }

    /// A density override for `pkg` changed (nil clears it): every open window
    /// of that app takes it at once.
    func setDensity(_ value: Double?, forPackage pkg: String) {
        densityStore.set(value, forKey: WindowDensityStore.key(forPackage: pkg))
        for controller in allControllers() where controller.densityPackage == pkg {
            controller.applyStoredDensity()
        }
        refreshKeyWindowMenu()
        onDensityOverridesChanged?()
    }

    func clearAllDensityOverrides() {
        let overridden = allControllers().filter { $0.densityOverride != nil }
        densityStore.clearAll()
        for controller in overridden { controller.applyStoredDensity() }
        refreshKeyWindowMenu()
        onDensityOverridesChanged?()
    }

    /// View ▸ Live Text for the key stream window: on enters, off leaves for
    /// the person's toggle. No key stream window means nothing to do.
    func setKeyWindowLiveText(_ on: Bool) {
        guard let controller = NSApp.keyWindow?.windowController as? StreamWindowController else { return }
        if on { controller.enterLiveText() } else { controller.exitLiveText(.menu) }
    }

    /// View ▸ Density's pick for the key stream window's app; nil is
    /// "Default". Nothing happens without a key stream window that shows an app.
    func setKeyWindowDensity(_ value: Double?) {
        guard let controller = NSApp.keyWindow?.windowController as? StreamWindowController,
              let pkg = controller.densityPackage else { return }
        setDensity(value, forPackage: pkg)
    }

    /// View ▸ Density ▸ Larger / Smaller: one ⌘+/⌘− step on the key stream
    /// window's app, the same call the window's own key handling makes.
    func adjustKeyWindowDensity(_ delta: Double) {
        (NSApp.keyWindow?.windowController as? StreamWindowController)?.adjustDensity(delta)
    }

    /// View ▸ Density ▸ Actual Size (⌘0): the key stream window's app goes back
    /// to the Settings default.
    func resetKeyWindowDensity() {
        (NSApp.keyWindow?.windowController as? StreamWindowController)?.resetDensity()
    }

    /// View → Show Touches: the fingers Android sees while a trackpad gesture
    /// runs. On by default where a trackpad exists (built-in or connected);
    /// once the person toggles it, their stored choice always wins.
    var showTouches: Bool {
        get {
            ShowTouchesDefault.resolve(hasTrackpad: hasTrackpad,
                                       stored: frames.object(forKey: Self.showTouchesKey) as? Bool)
        }
        set {
            frames.set(newValue, forKey: Self.showTouchesKey)
            for controller in allControllers() { controller.videoView.showsTouches = newValue }
            StreamMenuState.shared.showTouches = newValue
        }
    }

    /// Settings → General "Reveal controls after": the Immersive pill's
    /// dwell, read from the profile's defaults.
    var revealDelay: RevealDelay { RevealDelay.stored(in: frames) }

    /// The Mac's stream strategies (ISS-40) for windows opened now, read from
    /// this profile's defaults (`app.contigua.mac` for the person's app).
    var streamStrategy: MacStreamStrategy { MacStreamStrategy.read(from: frames) }

    /// Settings ▸ Input "Hover over Android apps": the Mac pointer over a
    /// stream window is a mouse over Android. On unless turned off; every
    /// mapper reads it live, so a change applies to open windows at once.
    var hoverEnabled: Bool {
        get { frames.object(forKey: Self.hoverKey) as? Bool ?? true }
        set { frames.set(newValue, forKey: Self.hoverKey) }
    }

    /// Settings ▸ Input "Secondary click (two-finger click)": read live, so the
    /// Settings change reaches every open window at once.
    var secondaryClick: SecondaryClick {
        get { SecondaryClick.stored(in: frames) }
        set { frames.set(newValue.rawValue, forKey: SecondaryClick.key) }
    }

    /// The setting changed: every open window takes the new delay at once, a
    /// rest already running included.
    func revealDelayChanged() {
        let delay = revealDelay
        StreamMenuState.shared.revealDelay = delay
        for controller in allControllers() { controller.setRevealDelay(delay) }
    }

    /// Write the setting and apply it (the Settings picker's path is
    /// `revealDelayChanged`; tests and debug hooks use this).
    func setRevealDelay(_ delay: RevealDelay) {
        frames.set(delay.rawValue, forKey: RevealDelay.key)
        revealDelayChanged()
    }

    /// View ▸ Hide Controls' pick: store the reveal choice for every window.
    /// It never changes a window's style, and only an Immersive window's pill
    /// reads it.
    func pickHideControls(_ item: FullScreenMenuItem) {
        guard let pick = FullScreenMenuModel.pick(item) else { return }
        setRevealDelay(pick)
    }

    /// A remembered frame may belong to a display that is gone.
    func clampedToScreen(_ frame: NSRect) -> NSRect {
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard let area = screens.first(where: { $0.intersects(frame) }) ?? screens.first else { return frame }
        var result = frame
        result.size.width = min(result.width, area.width)
        result.size.height = min(result.height, area.height)
        result.origin.x = min(max(result.minX, area.minX), area.maxX - result.width)
        result.origin.y = min(max(result.minY, area.minY), area.maxY - result.height)
        return result
    }

    /// Top-left for a window with no remembered frame: a 28 pt cascade from the
    /// top-left of the main screen, so new windows never stack exactly and never
    /// open centred over the Deck.
    func nextCascadeOrigin(for window: NSWindow) -> NSPoint {
        let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let start = NSPoint(x: area.minX + 48, y: area.maxY - 48)
        var point = cascadePoint == .zero ? start : NSPoint(x: cascadePoint.x + 28, y: cascadePoint.y - 28)
        if point.x + window.frame.width > area.maxX || point.y - window.frame.height < area.minY { point = start }
        cascadePoint = point
        return point
    }

    // MARK: Windows

    var openStreams: [UInt32] {
        lock.lock(); defer { lock.unlock() }
        return streams.keys.sorted()
    }

    func controller(for stream: UInt32) -> StreamWindowController? {
        lock.lock(); defer { lock.unlock() }
        return streams[stream]
    }

    /// The body every `open*` shares: allocate a stream, build its controller,
    /// remember it, show it, tell the phone what to show, redraw the window list.
    private func open<T: StreamWindowController>(_ make: (UInt32) -> T) -> T {
        let stream = allocateStream()
        let controller = make(stream)
        // MCP-100: an agent's new window takes the phone's shape.
        if openShape == .phone, let shape = agentShape(for: controller) {
            controller.takeAgentShape(shape)
        }
        store(controller, stream: stream)
        // A window opened while a drop runs or its outcome is up shows the pill.
        controller.setDropPill(dropPill)
        markLinkDown(controller)
        controller.setDropFailure(dropFailure)
        controller.present()
        controller.sendOpen()
        noteFront(stream)
        refreshTitles()
        syncStatsSubscription()
        onChange?()
        return controller
    }

    /// The phone in use, for the keying every window function takes (phase 2
    /// writes one phone; epic 2 renames `deviceId` to a `WindowKey`).
    var activeDeviceId: String { phone?.id ?? remoteDeviceId }

    /// The device id this manager's windows belong to when no phone is
    /// connected yet (`remembered.active`); windows opened before `welcome`
    /// keep their phone once it arrives.
    var remoteDeviceId = ""

    /// The one way a phone app reaches a Mac window (CONV-MAC-11, WIN-2).
    /// Every entry point — a Deck tile, Find Apps' Return, the Dock shim,
    /// Launchpad/Spotlight (which launch the shim), a `contigua://` or intent
    /// link and the MCP `open_app` tool — calls this and nothing else. An app
    /// that already has a window is raised (un-minimised, key, in front, this
    /// app activated) and the phone is sent no second `window.open`. While the
    /// window is still opening this also stops the v104 thrash (seven opens of
    /// Chrome in 77 s, each a launch on the phone, none making the picture come
    /// sooner).
    @discardableResult
    func openOrRaise(pkg: String, activity: String? = nil, deviceId: String? = nil) -> AppWindowController {
        if let existing = appWindows(pkg: pkg, deviceId: deviceId).first {
            // MCP-101: a raise keeps the shape and size the window has.
            existing.agentShapeEvent(.raise)
            raise(existing)
            return existing
        }
        let label = appsByPkg[pkg]?.label ?? pkg.split(separator: ".").last.map(String.init) ?? pkg
        let controller = open {
            AppWindowController(stream: $0, pkg: pkg, activity: activity, label: label,
                                deviceId: deviceId ?? activeDeviceId, manager: self)
        }
        onAppWindowOpened?(pkg, controller.stream)
        return controller
    }

    /// The explicit "New <App> Window" (WIN-25): one more window of `pkg` on
    /// the phone in use, one `window.open` carrying `newInstance`, cascaded
    /// 28 pt from the app's front window and never remembered as the app's
    /// frame (WIN-13, WIN-36). Nothing is sent when the item is disabled —
    /// the cap, a single-window app, an opening window or a link that is down
    /// (WIN-27, WIN-32, WIN-34).
    @discardableResult
    func openAdditional(pkg: String, activity: String? = nil, deviceId: String? = nil) -> AppWindowController? {
        let phone = deviceId ?? activeDeviceId
        let existing = appWindows(pkg: pkg, deviceId: phone)
        guard newWindowItem(for: pkg, deviceId: phone).enabled else { return nil }
        if existing.isEmpty { return openOrRaise(pkg: pkg, activity: activity, deviceId: phone) }
        let label = appsByPkg[pkg]?.label ?? pkg.split(separator: ".").last.map(String.init) ?? pkg
        let stream = allocateStream()
        let controller = AppWindowController(stream: stream, pkg: pkg, activity: activity,
                                             label: label, deviceId: phone, manager: self)
        // The extra window is not the app's remembered frame: it follows the
        // front one, 28 pt down and right, and forgets its own place when it
        // closes (WIN-13).
        controller.remembersFrame = false
        if let front = existing.first?.window?.frame {
            controller.placementOverride = NSRect(x: front.minX + 28, y: front.minY - 28,
                                                  width: front.width, height: front.height)
        }
        // MCP-100: an agent's added window takes the phone's shape too, at the
        // cascade's place.
        if openShape == .phone, let shape = agentShape(for: controller) {
            controller.takeAgentShape(shape)
            if let placed = controller.placementOverride, let frame = controller.window?.frame {
                controller.placementOverride = NSRect(x: placed.minX, y: placed.maxY - frame.height,
                                                      width: frame.width, height: frame.height)
            }
        }
        store(controller, stream: stream)
        controller.setDropPill(dropPill)
        markLinkDown(controller)
        controller.present()
        controller.sendOpen(newInstance: true)
        noteFront(stream)
        refreshTitles()
        onChange?()
        onAppWindowOpened?(pkg, controller.stream)
        return controller
    }

    /// WIN-45: the phone reported a task the app started itself. The same
    /// New-item rule as ⌘N decides: one more cascaded window and one
    /// `window.adopt` when it may act; nothing when a single-window app, a down
    /// link or a window still opening blocks it; at the cap the task stays on
    /// the phone and the Deck carries WIN-32's sentence.
    @discardableResult
    func noteTaskArrival(stream: UInt32, taskId: Int, pkg: String, label: String?) -> AppWindowController? {
        opening(by: .app) { noteTaskArrivalBody(stream: stream, taskId: taskId, pkg: pkg, label: label) }
    }

    private func noteTaskArrivalBody(stream: UInt32, taskId: Int, pkg: String, label: String?) -> AppWindowController? {
        guard taskId > 0, !pkg.isEmpty else { return nil }
        let item = newWindowItem(for: pkg)
        guard item.enabled else {
            if item.blocker == .atCap {
                let app = appsByPkg[pkg]?.label ?? pkg.split(separator: ".").last.map(String.init) ?? pkg
                onTooManyWindows?(NewWindowBlocker.atCap.sentence(app: app) ?? "")
            }
            return nil
        }
        return adoptAdditional(sourceStream: stream, taskId: taskId, pkg: pkg, label: label)
    }

    /// The window an adopted task opens in: the app's front window's frame
    /// cascaded 28 pt, its task's label, one `window.adopt` (WIN-45, WIN-46).
    @discardableResult
    func adoptAdditional(sourceStream: UInt32, taskId: Int, pkg: String, label: String?,
                         deviceId: String? = nil) -> AppWindowController? {
        let phone = deviceId ?? activeDeviceId
        guard newWindowItem(for: pkg, deviceId: phone).enabled else { return nil }
        let appLabel = appsByPkg[pkg]?.label ?? pkg.split(separator: ".").last.map(String.init) ?? pkg
        let stream = allocateStream()
        let adopted = AppWindowController(stream: stream, pkg: pkg, activity: nil,
                                          label: appLabel, deviceId: phone, manager: self)
        adopted.remembersFrame = false
        let anchor = appWindows(pkg: pkg, deviceId: phone).first?.window?.frame
            ?? self.controller(for: sourceStream)?.window?.frame
        if let anchor {
            adopted.placementOverride = NSRect(x: anchor.minX + 28, y: anchor.minY - 28,
                                               width: anchor.width, height: anchor.height)
        }
        store(adopted, stream: stream)
        adopted.setDropPill(dropPill)
        markLinkDown(adopted)
        adopted.setTaskLabel(label)
        adopted.present()
        adopted.sendAdopt(taskId: taskId)
        noteFront(stream)
        refreshTitles()
        onChange?()
        onAppWindowOpened?(pkg, adopted.stream)
        return adopted
    }

    /// The windows of one app on one phone, front to back (WIN-29, WIN-30).
    func appWindows(pkg: String, deviceId: String? = nil) -> [AppWindowController] {
        let phone = deviceId ?? activeDeviceId
        return frontToBack(allControllers().compactMap { $0 as? AppWindowController })
            .filter { $0.pkg == pkg && $0.deviceId == phone }
    }

    /// Every app window on one phone, front to back.
    func appWindows(deviceId: String? = nil) -> [AppWindowController] {
        let phone = deviceId ?? activeDeviceId
        return frontToBack(allControllers().compactMap { $0 as? AppWindowController })
            .filter { $0.deviceId == phone }
    }

    /// The stream window the app last made key. Read instead of
    /// `NSApp.keyWindow` on demand: a menu item's action can arrive while the
    /// menu itself is the key window, and the answer must still be the window
    /// the person was working in (MENU-2, WIN-25).
    private(set) var keyStream: UInt32?
    private var keyObservers: [NSObjectProtocol] = []

    /// Follows the key window by AppKit's own notifications rather than the
    /// window delegate: a quiet run's emulated key window posts them, and a
    /// delegate method is only called for the notifications AppKit makes
    /// itself (MENU-2's title and enabled flag hang on this). The same two
    /// notifications are the menus' key-window machine's events, so a window
    /// that is not a stream window (the Deck, Settings, a sheet) always drops
    /// the last stream window's values (MENU-4, MENU-6, MENU-9, ISS-88).
    private func observeKeyWindows() {
        guard keyObservers.isEmpty else { return }
        let center = NotificationCenter.default
        keyObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                               object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow else { return }
                guard let controller = window.windowController as? StreamWindowController else {
                    // Any other key window: the Deck, Settings, a sheet, the
                    // panel. No stream window is key any more.
                    self.performMenuKey(.otherWindowBecameKey)
                    return
                }
                self.noteFront(controller.stream)
                self.noteKey(controller.stream)
                self.performMenuKey(.streamBecameKey(controller.menuValues))
            }
        })
        keyObservers.append(center.addObserver(forName: NSWindow.didResignKeyNotification,
                                               object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let controller = (note.object as? NSWindow)?.windowController as? StreamWindowController
                else { return }
                self.noteKeyLost(controller.stream)
                self.performMenuKey(.streamResigned(stream: controller.stream))
            }
        })
        // A reactivation gives the key back to the window that had it; a
        // deactivation leaves the app with no usable key window at all.
        keyObservers.append(center.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.performMenuKey(.appDeactivated) }
        })
        keyObservers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let controller = NSApp.keyWindow?.windowController as? StreamWindowController {
                    self.performMenuKey(.streamBecameKey(controller.menuValues))
                } else {
                    self.performMenuKey(.otherWindowBecameKey)
                }
            }
        })
    }

    /// One key-window transition for the menus, with its action run.
    private func performMenuKey(_ event: StreamMenuKeyMachine.Event) {
        let actions = StreamMenuState.shared.handle(event)
        if actions.contains(.correctMenu) {
            MainActor.assumeIsolated { MenuMarks.apply(to: NSApp.mainMenu) }
        }
    }

    /// The key stream window's menu values moved (a density pick, a default).
    private func refreshKeyWindowMenu() {
        (NSApp.keyWindow?.windowController as? StreamWindowController)?.refreshMenuState()
    }

    func noteKey(_ stream: UInt32) { keyStream = stream }
    func noteKeyLost(_ stream: UInt32) {
        if keyStream == stream { keyStream = nil }
    }

    /// The app whose window is key ("Chrome"), or nil for the Deck, a phone
    /// view or a link window with no package.
    var keyApp: String? {
        if let stream = keyStream,
           let app = controller(for: stream) as? AppWindowController,
           app.window?.isVisible == true {
            return app.pkg
        }
        guard let app = NSApp.keyWindow?.windowController as? AppWindowController else { return nil }
        return app.pkg
    }

    /// The File menu's New item, from the phone's answer and the app's state
    /// (MENU-2, WIN-25, WIN-27, WIN-32, WIN-34).
    func newWindowItem(for pkg: String?, deviceId: String? = nil) -> NewWindowItem {
        guard let pkg, let info = appsByPkg[pkg] else {
            return NewWindowItem.make(app: nil, windowCount: 0, multi: false, opening: false,
                                      cap: maxWindows, link: linkPhase)
        }
        let windows = appWindows(pkg: pkg, deviceId: deviceId)
        return NewWindowItem.make(app: info.label,
                                  windowCount: appWindows(deviceId: deviceId).count,
                                  multi: info.multi,
                                  opening: windows.contains { $0.isOpening },
                                  cap: maxWindows,
                                  link: linkPhase)
    }

    /// The key app's New item, for the File menu's snapshot.
    var keyNewWindowItem: NewWindowItem { newWindowItem(for: keyApp) }

    /// Window ▸ Next Window ⌘`: the next window of `pkg` in front-to-back
    /// order, wrapping; nothing to the phone, and nothing at all with one
    /// window (WIN-30).
    ///
    /// The cycle keeps one order for the whole run: the app's windows newest
    /// first, which is their front-to-back order before anyone raises one. The
    /// raises themselves would reorder the list on every press, so a cycle
    /// read from the live order would bounce between the top two windows.
    @discardableResult
    func cycleWindows(pkg: String, deviceId: String? = nil) -> AppWindowController? {
        let windows = appWindows(pkg: pkg, deviceId: deviceId)
        guard windows.count > 1, let front = windows.first else { return nil }
        let order = windows.sorted { $0.stream > $1.stream }
        guard let index = order.firstIndex(where: { $0.stream == front.stream }) else { return nil }
        let next = order[(index + 1) % order.count]
        raise(next)
        return next
    }

    /// Window ▸ Next Window from the keyboard or the menu: the key app's.
    @discardableResult
    func cycleKeyWindow() -> AppWindowController? {
        guard let pkg = keyApp else { return nil }
        return cycleWindows(pkg: pkg)
    }

    /// Whether ⌘` has somewhere to go: two or more windows of the key app.
    var canCycleWindows: Bool {
        guard let pkg = keyApp else { return false }
        return appWindows(pkg: pkg).count > 1
    }

    /// The Dock shim's and the Deck cell's menu for an app (WIN-26).
    func windowMenuRows(pkg: String, deviceId: String? = nil) -> [AppWindowMenuRow] {
        let label = appsByPkg[pkg]?.label ?? pkg.split(separator: ".").last.map(String.init) ?? pkg
        let windows = appWindows(pkg: pkg, deviceId: deviceId).map { (stream: $0.stream, label: $0.taskLabel) }
        return AppWindowMenu.rows(app: label, windows: windows,
                                  newWindow: newWindowItem(for: pkg, deviceId: deviceId))
    }

    /// A picked row: the New item adds one window, a window row raises it.
    @discardableResult
    func pickWindowMenuRow(_ row: AppWindowMenuRow, pkg: String, deviceId: String? = nil) -> Bool {
        switch row.action {
        case .newWindow:
            return openAdditional(pkg: pkg, deviceId: deviceId) != nil
        case .raise(let stream):
            guard let controller = controller(for: stream) else { return false }
            raise(controller)
            return true
        }
    }

    /// The app's task label reached a window (`window.title` on an app stream):
    /// retitle it and the menus that list it (WIN-28).
    func setTaskLabel(_ label: String?, stream: UInt32) {
        guard let app = controller(for: stream) as? AppWindowController else { return }
        guard app.setTaskLabel(label) else { return }
        refreshTitles()
        onChange?()
    }

    /// Every window's title from the app's window count and the phone's name
    /// (WIN-3, WIN-28). Cheap enough to run on every change; it only writes
    /// when the value differs.
    func refreshTitles() {
        for app in appWindows() { app.retitle() }
        for controller in allControllers() where !(controller is AppWindowController) {
            controller.retitle()
        }
    }

    @discardableResult
    func openLink(_ url: String) -> LinkWindowController {
        open { LinkWindowController(stream: $0, url: url, manager: self) }
    }

    /// The open app and link windows — the ones a Dock identity stands for — as
    /// (stream, package) pairs. A link window names its package once the phone
    /// reports `window.title`.
    var openAppWindows: [(stream: UInt32, pkg: String?)] {
        allControllers().compactMap { controller -> (UInt32, String?)? in
            if let app = controller as? AppWindowController { return (app.stream, app.pkg) }
            if let link = controller as? LinkWindowController { return (link.stream, link.pkg) }
            return nil
        }
    }

    /// The last `state.screen`; a phone window opened while the panel sleeps
    /// starts with its cover up.
    private(set) var phoneScreen: PhoneScreen?

    @discardableResult
    func openPhoneWindow() -> PhoneWindowController {
        // One mirror per phone. Phone ▸ Phone Window (⌘P), the panel's row, the
        // Deck and the intents all land here: a second mirror of the same
        // screen is the screen twice, so the open one is raised instead.
        if let existing = phoneWindow {
            raise(existing)
            return existing
        }
        let controller = open { PhoneWindowController(stream: $0, phone: phone, manager: self) }
        controller.setPhoneScreen(phoneScreen)
        return controller
    }

    /// Bring an open window front: out of the Dock, and to its Space when it
    /// lives in one of its own (a full-screen window).
    private func raise(_ controller: StreamWindowController) {
        guard let window = controller.window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        noteFront(controller.stream)
        BackgroundMode.activateApp()
    }

    /// The open phone window, if any (the debug route and the screen state).
    var phoneWindow: PhoneWindowController? {
        allControllers().compactMap { $0 as? PhoneWindowController }.first
    }

    /// `state.screen` from the session reaches every phone window.
    func setPhoneScreen(_ screen: PhoneScreen?) {
        phoneScreen = screen
        for controller in allControllers() {
            (controller as? PhoneWindowController)?.setPhoneScreen(screen)
        }
    }

    /// `state.panel`: the phone holds its mirrored panel off for this window.
    func setPhonePanel(_ panel: PhonePanel?) {
        for controller in allControllers() {
            (controller as? PhoneWindowController)?.setPhonePanel(panel)
        }
    }

    /// The phone refused `phone.panel`: the window says so and leaves the
    /// button unchecked (the phone's last report is the truth).
    func failPhonePanelRequest() {
        for controller in allControllers() {
            (controller as? PhoneWindowController)?.panelRequestFailed()
        }
    }

    /// Phone ▸ Turn Off Phone Screen for the open phone window. The phone is
    /// the one that holds the panel, so this only asks; the check follows its
    /// report.
    func togglePhonePanelOff() {
        guard let phone = phoneWindow else { return }
        NSApp.sendAction(#selector(PhoneWindowController.togglePanelOffMenuAction(_:)), to: phone, from: nil)
    }

    /// The profile's defaults, for what is remembered per phone (nicknames,
    /// window styles and "Turn Off Phone Screen").
    var profileDefaults: UserDefaults { frames }

    /// `state.secure`: the phone's mirror is a surface Android blanks.
    func setPhoneSecure(_ secure: Bool) {
        for controller in allControllers() {
            (controller as? PhoneWindowController)?.setPhoneSecure(secure)
        }
    }

    /// "Open Current App on Mac" (docs/ROADMAP.md #9): a window for the app in the
    /// foreground on the phone's screen. The phone answers with the stream it
    /// opened (`task.continue`) or an error; the video and the app label follow.
    @discardableResult
    func openHandoffWindow() -> HandoffWindowController {
        open { HandoffWindowController(stream: $0, manager: self) }
    }

    /// The phone refused `task.continue` (docs/design/handoff.md): nothing
    /// continuable on its screen. The window that never opened is removed; the
    /// connection's session already answered with a phone error.
    func closeFailedHandoff(stream: UInt32) {
        guard let controller = controller(for: stream), controller is HandoffWindowController else { return }
        controller.closeFromRemote()
    }

    func resize(stream: UInt32, to size: NSSize) {
        controller(for: stream)?.setContentSize(size)
    }

    /// A menu stopped tracking: a menu is transient, so a window it covered is
    /// judged by its own occlusion again.
    func reevaluatePause() {
        for controller in allControllers() { controller.reevaluatePause() }
    }

    func setIcon(_ image: NSImage, pkg: String) {
        icons[pkg] = image
        // A window opened before the icons arrived shows its app's icon as
        // soon as it is here, not at the next phase change.
        for controller in allControllers() {
            guard let app = controller as? AppWindowController, app.pkg == pkg else { continue }
            app.refreshOpeningCover()
        }
    }

    /// "WhatsApp (Nicky)": the subject of a stream window's title, with the
    /// phone's display name appended; without a name just the subject.
    func titled(_ subject: String) -> String {
        phoneName.isEmpty ? subject : "\(subject) (\(phoneName))"
    }

    /// A new display name: remember it and retitle every open window.
    func setPhoneName(_ name: String) {
        guard name != phoneName else { return }
        phoneName = name
        for controller in allControllers() {
            controller.retitle()
            controller.refreshOpeningCover()
        }
    }

    /// Whether this frame is the first of `stream` for its window, recorded
    /// once per stream under `lock`. A frame with no window (a closed
    /// stream's last one, after `remove`) notes nothing: it took the id's one
    /// note before, and the next window opened on that id kept its opening
    /// cover for good.
    /// MCP-41: an MCP open hears its window's `window.opened`, first frame,
    /// refusal and close; what already happened is fed at once. Returns the
    /// id `unwatchOpen` takes.
    func watchOpen(stream: UInt32, client: MCPClientID?,
                   _ feed: @escaping (MCPActMachine.Event) -> Void) -> Int {
        nextOpenWatch += 1
        let id = nextOpenWatch
        openWatches[stream, default: []].append((id, client, feed))
        lock.lock()
        let framed = firstFrameNoted.contains(stream)
        lock.unlock()
        let live = controller(for: stream).map { $0.mcpLifecycle != .opening } ?? false
        // A window that is already showing its picture has had its open.
        if phoneOpened[stream] != nil || live { feed(.windowOpened) }
        if framed || live { feed(.firstFrame) }
        return id
    }

    /// The display the phone made for `stream` (`window.opened`'s `w`×`h`),
    /// nil until the phone answers (MCP-41, MCP-100).
    func openedSize(_ stream: UInt32) -> (width: Int, height: Int)? { phoneOpened[stream] }

    func unwatchOpen(stream: UInt32, id: Int) {
        openWatches[stream]?.removeAll { $0.id == id }
        if openWatches[stream]?.isEmpty == true { openWatches[stream] = nil }
    }

    private func feedOpenWatches(_ stream: UInt32, _ event: (MCPClientID?) -> MCPActMachine.Event) {
        for watch in openWatches[stream] ?? [] { watch.feed(event(watch.client)) }
    }

    /// The window went: each watching call hears why, as its client sees it.
    private func openWatchesClosed(_ stream: UInt32) {
        let now = ProcessInfo.processInfo.systemUptime
        feedOpenWatches(stream) { client in
            let record = self.ledger.closeRecord(stream, asker: client, now: now)
            return .windowClosed(reason: record?.reason ?? "closed", by: record?.closedBy ?? "person")
        }
        phoneOpened[stream] = nil
    }

    func markFirstFrame(stream: UInt32, hasWindow: Bool) -> Bool {
        guard hasWindow else { return false }
        lock.lock()
        defer { lock.unlock() }
        return firstFrameNoted.insert(stream).inserted
    }

    func remove(stream: UInt32) {
        lock.lock()
        let removed = streams.removeValue(forKey: stream) != nil
        firstFrameNoted.remove(stream)
        frontOrder.removeAll { $0 == stream }
        lock.unlock()
        if removed { openWatchesClosed(stream) }
        if removed { onStreamClosed?(stream) }
        if removed { syncStatsSubscription() }
        refreshTitles()
        // A closed key window hands the keyboard to another window. AppKit
        // does this itself; a quiet run's emulated key window would otherwise
        // stay nil, and the menu commands would act on nothing (WIN-31).
        if keyStream == nil, let next = appWindows().first {
            raise(next)
        }
        onChange?()
    }

    func closeAll(cause: MCPWindowLedger.Cause? = nil) {
        lock.lock()
        let controllers = Array(streams.values)
        if let cause { for controller in controllers { recordClose(controller.stream, cause: cause) } }
        streams.removeAll()
        frontOrder.removeAll()
        lock.unlock()
        for controller in controllers {
            openWatchesClosed(controller.stream)
            onStreamClosed?(controller.stream)
            controller.closeFromRemote()
        }
        onChange?()
    }

    /// Test hook (`--debug-control` reset, e2e): back to the windows of a just
    /// launched app for the next check that shares this running app. Every stream
    /// window closes the way the person closes one (the phone gets window.close),
    /// stream ids start at 1 again, no cascade position carries over and the
    /// per-check options are off. `forgetPrefs` also drops the remembered frames,
    /// styles and Show Touches (a fresh profile); without it they stay, as they
    /// do across a relaunch.
    func resetForNextCheck(forgetPrefs: Bool) {
        for controller in allControllers() { controller.window?.close() }
        nextStream = 1
        cascadePoint = .zero
        floatWindows = false
        chromeStateFile = nil
        frontOrder = []
        linkOfflineTimer?.invalidate()
        linkOfflineTimer = nil
        linkClock = LinkPhaseClock()
        linkPhase = .up
        maxWindows = Self.defaultMaxWindows
        guard forgetPrefs else { return }
        frames.removeObject(forKey: Self.framesKey)
        frames.removeObject(forKey: Self.showTouchesKey)
        frames.removeObject(forKey: Self.hoverKey)
        frames.removeObject(forKey: SecondaryClick.key)
        frames.removeObject(forKey: RevealDelay.key)
        StreamMenuState.shared.showTouches = false
        for key in frames.dictionaryRepresentation().keys where key.hasPrefix(WindowStyleStore.prefix) {
            frames.removeObject(forKey: key)
        }
        densityStore.clearAll()
        StreamMenuState.shared.showTouches = false
        StreamMenuState.shared.handle(.reset)
        StreamMenuState.shared.settingsDensity = WindowDensity.value(in: frames)
    }

    /// Re-issue window.open for every open window (used after a reconnect):
    /// per app front to back, with `newInstance` on every window of that app
    /// but its first, so the phone gives each its own task again (WIN-34).
    func reopenAll() {
        var seen = Set<String>()
        for controller in frontToBack(allControllers()) {
            guard let app = controller as? AppWindowController else {
                controller.sendOpen()
                continue
            }
            let key = "\(app.deviceId)/\(app.pkg)"
            let first = seen.insert(key).inserted
            app.sendOpen(newInstance: !first)
        }
    }

    /// PATH-5: after a switch every open video stream asks for one keyframe
    /// (and a fresh config where the phone needs one), so the picture is live
    /// again within stale_picture_ms.
    func requestKeyframes(from session: Session) {
        for controller in allControllers() { session.requestKeyframe(stream: controller.stream) }
    }

    /// Apply labels to app windows once `apps` arrives (they may open before it).
    func applyLabels() {
        for controller in allControllers() {
            guard let app = controller as? AppWindowController,
                  let info = appsByPkg[app.pkg] else { continue }
            app.setAppLabel(info.label)
        }
        refreshTitles()
        onChange?()
    }

    /// The windows in the order the person last saw them. A stream that is not
    /// in the order yet (it was just created) goes to the front.
    private func frontToBack<T: StreamWindowController>(_ controllers: [T]) -> [T] {
        lock.lock()
        let order = frontOrder
        lock.unlock()
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return controllers.sorted { (rank[$0.stream] ?? Int.max) < (rank[$1.stream] ?? Int.max) }
    }

    /// A window became key or was raised: it is the front one from now on.
    /// A new front changes every menu that lists the app's windows (WIN-26),
    /// so the change is announced like any other window-set change; without
    /// this a raise reordered the Deck cell's live menu but left the Dock
    /// shim's pushed copy on the old front.
    func noteFront(_ stream: UInt32) {
        lock.lock()
        let changed = frontOrder.first != stream
        frontOrder.removeAll { $0 == stream }
        frontOrder.insert(stream, at: 0)
        lock.unlock()
        if changed { onChange?() }
    }

    private func store(_ controller: StreamWindowController, stream: UInt32) {
        lock.lock(); streams[stream] = controller; lock.unlock()
        // MCP-51: every new window is recorded once, with whoever is opening.
        ledger.opened(stream, kind: Self.ledgerKind(controller), package: Self.ledgerPackage(controller),
                      by: opener, now: ProcessInfo.processInfo.systemUptime)
    }

    /// The windows ledger (MCP-50…53): who opened each window, why it closed.
    private(set) var ledger = MCPWindowLedger()

    /// Who the open in progress is for: the person unless a caller says
    /// otherwise (an MCP connection's `open_app`, the app's own task).
    var opener: MCPWindowLedger.Opener = .person

    /// The shape a new window opens at (MCP-100): `.window` for every
    /// person's open, the MCP call's `shape` for an agent's.
    private(set) var openShape: MCPWindowShape = .window

    /// Run `body` with `opener` naming who opens (MCP-51) and `shape` the
    /// shape a window it creates takes (MCP-100).
    func opening<T>(by opener: MCPWindowLedger.Opener, shape: MCPWindowShape = .window,
                    _ body: () throws -> T) rethrows -> T {
        let before = (self.opener, openShape)
        self.opener = opener
        openShape = shape
        defer { (self.opener, openShape) = before }
        return try body()
    }

    /// MCP-100: the phone shape for a new app or link window, fitted to the
    /// visible frame of the screen it opens on with its style's chrome; nil
    /// when the phone reported no screen (the window opens as a person's).
    func agentShape(for controller: StreamWindowController) -> AgentWindowShape? {
        guard controller is AppWindowController || controller is LinkWindowController,
              let phone else { return nil }
        let visible = (controller.window?.screen ?? NSScreen.main)?.visibleFrame.size
            ?? CGSize(width: 1440, height: 900)
        return AgentWindowShape.make(screenWidth: phone.screenWidth, screenHeight: phone.screenHeight,
                                     screenDpi: phone.screenDpi, encoder: phone.encoder,
                                     visible: visible, chrome: controller.style.windowSize(stream: .zero))
    }

    /// MCP-52: record why a window closed. The first cause wins.
    func recordClose(_ stream: UInt32, cause: MCPWindowLedger.Cause) {
        ledger.closed(stream, cause: cause, now: ProcessInfo.processInfo.systemUptime)
    }

    static func ledgerPackage(_ controller: StreamWindowController) -> String? {
        if let app = controller as? AppWindowController { return app.pkg }
        if let link = controller as? LinkWindowController { return link.pkg }
        if let handoff = controller as? HandoffWindowController { return handoff.pkg }
        return nil
    }

    private static func ledgerKind(_ controller: StreamWindowController) -> MCPWindowLedger.Kind {
        if controller is LinkWindowController { return .link }
        if controller is HandoffWindowController { return .handoff }
        if controller is PhoneWindowController { return .mirror }
        return .app
    }

    #if DEBUG
    /// Test seam: register a window without a phone session, so the controller
    /// link-reconcile tests drive the same manager path production uses.
    func registerForTesting(_ controller: StreamWindowController, stream: UInt32) {
        store(controller, stream: stream)
    }
    #endif

    /// Asks for or stops the phone's `stream.stats` at the one moment the
    /// window set crosses empty↔non-empty (StatsSubscription). A send the
    /// session refuses (opened before the link was ready) is not lost: the
    /// machine is put back and the ready session's sync asks again.
    private func syncStatsSubscription() {
        guard let on = statsSubscription.windowsChanged(open: openStreams.count) else { return }
        if !session.setStreamStats(on) {
            statsSubscription.deliveryFailed(on)
        }
    }

    private func allControllers() -> [StreamWindowController] {
        lock.lock(); defer { lock.unlock() }
        return Array(streams.values)
    }

    private func allocateStream() -> UInt32 {
        defer { nextStream += 1 }
        onStreamAllocated?(nextStream)
        return nextStream
    }

    // MARK: Events

    /// Video arrives on the session queue; hand it straight to the display
    /// layer's queue without a main-thread hop.
    func handleVideo(_ event: VideoEvent, from source: Session) {
        lock.lock(); let current = session; lock.unlock()
        guard source === current else { return }
        switch event {
        case .config(let stream, let config, let picture):
            videoDump?.write(config: config, stream: stream)
            controller(for: stream)?.stats.noteConfig(now: ProcessInfo.processInfo.systemUptime)
            // A new CONFIG is the phone's answer to a resize too: the value
            // that waited behind it may go out now. This runs on the session's
            // video queue, and the coalescer is the window's (main-thread)
            // state: hop with the stream id, the picture itself stays hop-free.
            DispatchQueue.main.async { [weak self] in  // gcd: one hop from the video queue
                self?.controller(for: stream)?.resizeSettled()
            }
            controller(for: stream)?.videoView.configure(config, picture: picture)
        case .frame(let stream, let frame, let path):
            frameLog?.note(stream: stream, path: path)
            videoDump?.write(frame: frame, stream: stream)
            let controller = controller(for: stream)
            controller?.stats.noteReceived(now: ProcessInfo.processInfo.systemUptime,
                                           bytes: frame.annexB.count)
            // MCP-20: count the complete access unit; the snapshot decoder
            // gets its stamp so a screenshot names the frame it decoded.
            let stamp = controller?.frameClock.note()
            controller?.videoView.enqueue(frame, stamp: stamp)
            // The opening cover ends at the stream's first frame; the note is
            // main-thread state, sent once per stream.
            if markFirstFrame(stream: stream, hasWindow: controller != nil), let controller {
                // One hop from the session's video queue to the main thread,
                // where the window's cover and the menus live.
                DispatchQueue.main.async { [weak self, weak controller] in  // gcd: off the video queue
                    controller?.noteFirstFrame()
                    self?.feedOpenWatches(stream) { _ in .firstFrame }  // MCP-41
                    // The New Window items say "Opening on your phone…" until
                    // this moment: the menus and the Dock shim read it now
                    // (WIN-27).
                    self?.onChange?()
                }
            }
        case .chunkIncomplete(let stream):
            // R6: the session's assembler threw a stub away; the picture's
            // feed must break until a keyframe or the next delta corrupts.
            controller(for: stream)?.videoView.incompleteChunkedUnit()
        }
    }

    /// What the phone's `error no_stream` meant for the windows (WIN-38).
    enum NoStreamOutcome: Equatable {
        /// Nothing is open on that stream: the expected case after a close,
        /// and only the log says so.
        case noWindow
        /// The window is still opening: the cover refuses it (WIN-11).
        case refusedOpening
        /// A live window whose stream the phone lost: it closes as if the
        /// phone had sent `window.closed` (WIN-12).
        case closedWindow
    }

    /// The phone answered `no_stream` for a stream: it has forgotten it. A
    /// window still opening wears the cover's refusal; a live one closes
    /// without echoing a close back to a phone that no longer has it; no
    /// window means nothing visible at all — never a launcher notice.
    @discardableResult
    func phoneAnsweredNoStream(_ stream: UInt32) -> NoStreamOutcome {
        guard let controller = controller(for: stream) else { return .noWindow }
        if controller.isOpening {
            controller.refuseOpening("no_stream")
            return .refusedOpening
        }
        controller.closeFromRemote()
        return .closedWindow
    }

    func handle(_ event: SessionEvent) {
        switch event {
        case .windowTitle(let stream, let label, let pkg, let title):
            // An app window names its task (`title`, falling back to the app's
            // own name, WIN-28); the phone, link and handoff windows name the
            // app the display shows (`label`), never the page it is on
            // (WIN-3), and a message that names no app leaves it standing.
            if controller(for: stream) is AppWindowController {
                let task = title ?? (label.isEmpty ? nil : label)
                if task != nil { setTaskLabel(task, stream: stream) }
            } else if !label.isEmpty {
                (controller(for: stream) as? PhoneWindowController)?.setSubject(label)
            }
            (controller(for: stream) as? HandoffWindowController)?.adopt(pkg: pkg)
            if !label.isEmpty {
                (controller(for: stream) as? HandoffWindowController)?.setSubject(label)
            }
            if let link = controller(for: stream) as? LinkWindowController {
                let unknown = link.pkg == nil
                if !label.isEmpty { link.setSubject(label) }
                link.adopt(pkg: pkg)
                if unknown, !pkg.isEmpty {
                    onAppWindowOpened?(pkg, stream)
                }
            }
        case .windowClosed(let stream, let reason):
            Log.app.info("phone closed stream \(stream, privacy: .public) (\(reason, privacy: .public))")
            controller(for: stream)?.closeFromRemote()
        case .windowStill(let stream):
            // A heartbeat for that stream's picture rule only: another stream's
            // still says nothing about this window.
            controller(for: stream)?.noteStill()
        case .phoneStats(let stream, let stats):
            controller(for: stream)?.stats.notePhoneStats(stats)
        case .windowResizeAck(let stream, let width, let height, let dpi, let outcome):
            let controller = controller(for: stream)
            let ms = controller?.takeResizeAckMs().map { String(format: "%.1f", $0) } ?? "-"
            Log.video.info("stream \(stream, privacy: .public) resize ack \(width, privacy: .public)x\(height, privacy: .public) dpi=\(dpi, privacy: .public) (\(outcome, privacy: .private)) in \(ms, privacy: .public) ms")
            controller?.resizeSettled(ResizeRequest(w: width, h: height, dpi: dpi))
        case .windowOpened(let stream, _, let width, let height, let started):
            phoneOpened[stream] = (width, height)
            feedOpenWatches(stream) { _ in .windowOpened }  // MCP-41
            if started == .fresh {
                (controller(for: stream) as? HandoffWindowController)?.showFreshNotice()
            }
        case .windowTask(let stream, let taskId):
            (controller(for: stream) as? AppWindowController)?.taskId = taskId
        case .appTaskArrived(let stream, let taskId, let pkg, let label):
            noteTaskArrival(stream: stream, taskId: taskId, pkg: pkg, label: label)
        case .maxWindows(let cap):
            setMaxWindows(cap)
        case .phoneError(let code, _, let stream):
            // MCP-41/43: an MCP open hears the phone's refusal of its window.
            if stream != 0, code != "no_stream" { feedOpenWatches(stream) { _ in .openFailed(code) } }
            if code == "cannot_adopt" {
                // WIN-46: the phone could not move that task. That window goes
                // quietly — no launcher notice, and the task stays where it is.
                Log.app.info("adopt refused for stream \(stream, privacy: .public)")
                recordClose(stream, cause: .openFailed)  // MCP-52
                controller(for: stream)?.closeFromRemote()
                return
            }
            if code == "too_many_windows" {
                // The phone refused the extra window (WIN-32): it closes, no
                // window.close is sent for a window that never opened, and the
                // Deck carries the cap's sentence.
                let app = (controller(for: stream) as? AppWindowController)
                    .map { appsByPkg[$0.pkg]?.label ?? $0.appLabel } ?? ""
                recordClose(stream, cause: .openFailed)  // MCP-52
                controller(for: stream)?.closeFromRemote()
                onTooManyWindows?(NewWindowBlocker.atCap.sentence(app: app) ?? "")
                return
            }
            if code == "no_stream" {
                // The phone has forgotten the stream (WIN-38). What to do
                // depends on the window, never on a launcher notice.
                switch phoneAnsweredNoStream(stream) {
                case .noWindow:
                    Log.session.notice("no_stream for stream \(stream, privacy: .public): no window")
                case .refusedOpening:
                    Log.app.info("no_stream for stream \(stream, privacy: .public): opening refused")
                case .closedWindow:
                    Log.app.info("phone lost stream \(stream, privacy: .public): window closed")
                }
            } else {
                // A phone that refuses an open answers it itself: that
                // window's cover says why and offers Close only (MIRROR-2, WIN-11).
                controller(for: stream)?.refuseOpening(code)
            }
        case .ready(_, let isReconnect, _):
            if isReconnect { reopenAll() }
            syncStatsSubscription()
        default:
            break
        }
    }
}
