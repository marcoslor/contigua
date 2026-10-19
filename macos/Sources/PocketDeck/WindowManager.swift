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

    /// The drop pill's state on every stream window; nil hides them all.
    func setDropPill(_ state: (text: String, showsProgress: Bool)?) {
        for controller in allControllers() { controller.setDropPill(state) }
    }

    private let frames: UserDefaults
    private var cascadePoint = NSPoint.zero
    private static let framesKey = "streamFrames"
    private static let showTouchesKey = "showTouches"
    /// Whether this Mac has a trackpad decides the Show Touches default; read
    /// once, before the menu state seeds itself.
    private let hasTrackpad: Bool

    init(session: Session, defaults: UserDefaults = .standard) {
        self.session = session
        frames = defaults
        hasTrackpad = TrackpadPresence.anyTrackpad()
        styleStore = WindowStyleStore(defaults: defaults)
        barMirror = BarMirror.stored(in: defaults)
        StreamMenuState.shared.showTouches = ShowTouchesDefault.resolve(
            hasTrackpad: hasTrackpad, stored: defaults.object(forKey: Self.showTouchesKey) as? Bool)
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
    /// The framed bar's mirror alphas, as the profile's defaults set them.
    let barMirror: BarMirror

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

    @discardableResult
    func openApp(pkg: String, activity: String? = nil) -> AppWindowController {
        let stream = allocateStream()
        let label = appsByPkg[pkg]?.label ?? pkg
        let controller = AppWindowController(stream: stream, pkg: pkg, activity: activity,
                                            label: label, manager: self)
        store(controller, stream: stream)
        controller.present()
        controller.sendOpen()
        onChange?()
        onAppWindowOpened?(pkg, stream)
        return controller
    }

    @discardableResult
    func openLink(_ url: String) -> LinkWindowController {
        let stream = allocateStream()
        let controller = LinkWindowController(stream: stream, url: url, manager: self)
        store(controller, stream: stream)
        controller.present()
        controller.sendOpen()
        onChange?()
        return controller
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

    @discardableResult
    func openPhoneWindow() -> PhoneWindowController {
        let stream = allocateStream()
        let controller = PhoneWindowController(stream: stream, phone: phone, manager: self)
        store(controller, stream: stream)
        controller.present()
        controller.sendOpen()
        onChange?()
        return controller
    }

    /// "Continue on Mac" (docs/ROADMAP.md #9): a window for the app in the
    /// foreground on the phone's screen. The phone answers with the stream it
    /// opened (`task.continue`) or an error; the video and the app label follow.
    @discardableResult
    func openHandoffWindow() -> HandoffWindowController {
        let stream = allocateStream()
        let controller = HandoffWindowController(stream: stream, manager: self)
        store(controller, stream: stream)
        controller.present()
        controller.sendOpen()
        onChange?()
        return controller
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
        lock.lock(); let removed = streams.removeValue(forKey: stream) != nil; lock.unlock()
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
        StreamMenuState.shared.showTouches = false
        for key in frames.dictionaryRepresentation().keys where key.hasPrefix(WindowStyleStore.prefix) {
            frames.removeObject(forKey: key)
        }
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
        case .config(let stream, let config):
            videoDump?.write(config: config, stream: stream)
            controller(for: stream)?.videoView.configure(config)
        case .frame(let stream, let frame):
            videoDump?.write(frame: frame, stream: stream)
            controller(for: stream)?.videoView.enqueue(frame)
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
        case .windowOpened(let stream, _, _, _, let started):
            if started == .fresh {
                (controller(for: stream) as? HandoffWindowController)?.showFreshNotice()
            }
        case .ready(_, let isReconnect, _):
            if isReconnect { reopenAll() }
        default:
            break
        }
    }
}
