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
    var phone: PhoneInfo?
    /// The active phone's display name (its nickname, else its own name):
    /// app and link window titles carry it — "WhatsApp (Nicky)".
    private(set) var phoneName = ""

    /// Fired when the set of open windows or the icon cache changes.
    var onChange: (() -> Void)?

    /// Fired once per window that closed, whoever closed it (Dock apps follow their window).
    var onStreamClosed: ((UInt32) -> Void)?

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

    /// Files a Finder drag dropped on a stream window (docs/design/dragdrop.md).
    /// The owner (ConnectionController) routes them; an .apk keeps its own route.
    var onFilesDropped: (([URL]) -> Void)?

    /// Set while the app is terminating so windows stop emitting pause/resume.
    private(set) var shuttingDown = false

    func beginShutdown() { shuttingDown = true }

    /// The controller owns one `Session` per attempt; windows outlive them and
    /// talk to whichever is current.
    func attach(_ session: Session) {
        lock.lock(); self.session = session; lock.unlock()
    }

    /// True while the link is down: stream windows show a "Reconnecting…" pill
    /// over their last frame and drop input (docs/design/mac-redesign.md §3.7).
    private(set) var linkIsDown = false

    func linkLost() {
        linkIsDown = true
        for controller in allControllers() { controller.setLinkDown(true) }
    }

    func linkRestored() {
        linkIsDown = false
        for controller in allControllers() { controller.setLinkDown(false) }
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
    }

    /// The View menu's Window Style: toggle/switch the key stream window's
    /// style directly (the menu cannot rely on the responder chain delivering
    /// a nil-target action).
    func toggleKeyWindowStyle() {
        (NSApp.keyWindow?.windowController as? StreamWindowController)?.toggleStyleMenuAction(nil)
    }

    func setKeyWindowStyle(_ style: WindowStyle) {
        (NSApp.keyWindow?.windowController as? StreamWindowController)?.setStyle(style)
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
        let state = StreamMenuState.shared
        if state.densityPackage == pkg { state.densityOverride = value }
        onDensityOverridesChanged?()
    }

    func clearAllDensityOverrides() {
        let overridden = allControllers().filter { $0.densityOverride != nil }
        densityStore.clearAll()
        for controller in overridden { controller.applyStoredDensity() }
        StreamMenuState.shared.densityOverride = nil
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

    /// Settings → General "Reveal controls after": the immersive dwell, read
    /// from the profile's defaults.
    var revealDelay: RevealDelay { RevealDelay.stored(in: frames) }

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
        let seconds = revealDelay.seconds
        StreamMenuState.shared.revealDelay = revealDelay
        for controller in allControllers() { controller.setRevealDelay(seconds) }
    }

    /// Write the setting and apply it (the Settings picker's path is
    /// `revealDelayChanged`; tests and debug hooks use this).
    func setRevealDelay(_ delay: RevealDelay) {
        frames.set(delay.rawValue, forKey: RevealDelay.key)
        revealDelayChanged()
    }

    /// View ▸ Immersive's pick: store the choice for every window and take the
    /// focused one to immersive (as the plain "Immersive" item did).
    func pickImmersive(_ item: ImmersiveMenuItem) {
        guard let pick = ImmersiveMenuModel.pick(item) else { return }
        setRevealDelay(pick.reveal)
        setKeyWindowStyle(pick.style)
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
        store(controller, stream: stream)
        // A window opened while a drop runs or its outcome is up shows the pill.
        controller.setDropPill(dropPill)
        controller.present()
        controller.sendOpen()
        onChange?()
        return controller
    }

    @discardableResult
    func openApp(pkg: String, activity: String? = nil) -> AppWindowController {
        // A dock click (or a second open request) while the app is still
        // opening raises the window that is already waiting instead of asking
        // the phone for another stream. The v104 log had seven opens of Chrome
        // while the first window was black; each was a second launch on the
        // phone and none of them made the picture come sooner.
        if let opening = allControllers().compactMap({ $0 as? AppWindowController })
            .first(where: { $0.pkg == pkg && $0.isOpening }) {
            opening.window?.makeKeyAndOrderFront(nil)
            return opening
        }
        let label = appsByPkg[pkg]?.label ?? pkg
        let controller = open {
            AppWindowController(stream: $0, pkg: pkg, activity: activity, label: label, manager: self)
        }
        onAppWindowOpened?(pkg, controller.stream)
        return controller
    }

    /// A notification click's window: raise the app's window when it is
    /// already open, else open one. The returned stream is where the phone
    /// runs the notification's action.
    @discardableResult
    func openOrRaiseApp(pkg: String, activity: String? = nil) -> UInt32 {
        if let existing = allControllers().compactMap({ $0 as? AppWindowController })
            .first(where: { $0.pkg == pkg }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return existing.stream
        }
        return openApp(pkg: pkg, activity: activity).stream
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

    /// "Move Phone App to Mac" (docs/ROADMAP.md #9): a window for the app in the
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
        for controller in allControllers() { controller.retitle() }
    }

    func remove(stream: UInt32) {
        lock.lock()
        let removed = streams.removeValue(forKey: stream) != nil
        firstFrameNoted.remove(stream)
        lock.unlock()
        if removed { onStreamClosed?(stream) }
        onChange?()
    }

    func closeAll() {
        lock.lock()
        let controllers = Array(streams.values)
        streams.removeAll()
        lock.unlock()
        for controller in controllers {
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
        StreamMenuState.shared.densityOverride = nil
        StreamMenuState.shared.settingsDensity = WindowDensity.value(in: frames)
    }

    /// Re-issue window.open for every open window (used after a reconnect).
    func reopenAll() {
        for controller in allControllers() { controller.sendOpen() }
    }

    /// Apply labels to app windows once `apps` arrives (they may open before it).
    func applyLabels() {
        for controller in allControllers() {
            guard let app = controller as? AppWindowController,
                  let info = appsByPkg[app.pkg] else { continue }
            app.setSubject(info.label)
        }
    }

    private func store(_ controller: StreamWindowController, stream: UInt32) {
        lock.lock(); streams[stream] = controller; lock.unlock()
    }

    private func allControllers() -> [StreamWindowController] {
        lock.lock(); defer { lock.unlock() }
        return Array(streams.values)
    }

    private func allocateStream() -> UInt32 {
        defer { nextStream += 1 }
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
            // A new CONFIG is the phone's answer to a resize too: the value
            // that waited behind it may go out now. This runs on the session's
            // video queue, and the coalescer is the window's (main-thread)
            // state: hop with the stream id, the picture itself stays hop-free.
            DispatchQueue.main.async { [weak self] in  // gcd: one hop from the video queue
                self?.controller(for: stream)?.resizeSettled()
            }
            controller(for: stream)?.videoView.configure(config, picture: picture)
        case .frame(let stream, let frame):
            videoDump?.write(frame: frame, stream: stream)
            let controller = controller(for: stream)
            controller?.videoView.enqueue(frame)
            controller?.frameClock.note()
            // The opening cover ends at the stream's first frame; the note is
            // main-thread state, sent once per stream.
            lock.lock()
            let first = firstFrameNoted.insert(stream).inserted
            lock.unlock()
            if first, let controller {
                DispatchQueue.main.async { [weak controller] in controller?.noteFirstFrame() }
            }
        }
    }

    func handle(_ event: SessionEvent) {
        switch event {
        case .windowTitle(let stream, let label, let pkg):
            (controller(for: stream) as? PhoneWindowController)?.setSubject(label)
            (controller(for: stream) as? AppWindowController)?.setSubject(label)
            (controller(for: stream) as? HandoffWindowController)?.adopt(pkg: pkg)
            (controller(for: stream) as? HandoffWindowController)?.setSubject(label)
            if let link = controller(for: stream) as? LinkWindowController {
                let unknown = link.pkg == nil
                link.setSubject(label)
                link.adopt(pkg: pkg)
                if unknown, !pkg.isEmpty {
                    onAppWindowOpened?(pkg, stream)
                }
            }
        case .windowClosed(let stream, let reason):
            Log.app.info("phone closed stream \(stream, privacy: .public) (\(reason, privacy: .public))")
            controller(for: stream)?.closeFromRemote()
        case .windowResizeAck(let stream, let width, let height, let dpi, let outcome):
            Log.video.info("stream \(stream, privacy: .public) resize ack \(width, privacy: .public)x\(height, privacy: .public) dpi=\(dpi, privacy: .public) (\(outcome, privacy: .private))")
            controller(for: stream)?.resizeSettled(ResizeRequest(w: width, h: height, dpi: dpi))
        case .windowOpened(let stream, _, _, _, let started):
            if started == .fresh {
                (controller(for: stream) as? HandoffWindowController)?.showFreshNotice()
            }
        case .phoneError(let code, _, let stream):
            // A phone that cannot mirror answers the open itself; that window
            // says so and offers Close only (MIRROR-2).
            (controller(for: stream) as? PhoneWindowController)?.refuseOpening(code)
        case .ready(_, let isReconnect, _):
            if isReconnect { reopenAll() }
        default:
            break
        }
    }
}
