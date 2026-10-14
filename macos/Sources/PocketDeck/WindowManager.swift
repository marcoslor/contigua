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

    /// Fired when the set of open windows or the icon cache changes.
    var onChange: (() -> Void)?

    /// Fired once per window that closed, whoever closed it (Dock apps follow their window).
    var onStreamClosed: ((UInt32) -> Void)?

    /// Test hook (`--float-windows`): new stream windows float above other apps.
    var floatWindows = false

    /// Test hook (`--dump-video`): the streams' H.264 written to disk.
    var videoDump: VideoDump?

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

    private let frames: UserDefaults
    private var cascadePoint = NSPoint.zero
    private static let framesKey = "streamFrames"
    private static let titleStripsKey = "titleStrips"
    private static let showTouchesKey = "showTouches"

    init(session: Session, defaults: UserDefaults = .standard) {
        self.session = session
        frames = defaults
        StreamMenuState.shared.showTouches = defaults.bool(forKey: Self.showTouchesKey)
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

    /// The title strip is on unless the person turned it off for that app.
    func titleStrip(forKey key: String) -> Bool {
        (frames.dictionary(forKey: Self.titleStripsKey) as? [String: Bool])?[key] ?? true
    }

    func setTitleStrip(_ enabled: Bool, forKey key: String) {
        var all = frames.dictionary(forKey: Self.titleStripsKey) as? [String: Bool] ?? [:]
        all[key] = enabled
        frames.set(all, forKey: Self.titleStripsKey)
    }

    /// View → Show Touches: the fingers Android sees while a trackpad gesture runs. Off by default.
    var showTouches: Bool {
        get { frames.bool(forKey: Self.showTouchesKey) }
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

    func resize(stream: UInt32, to size: NSSize) {
        controller(for: stream)?.setContentSize(size)
    }

    func setIcon(_ image: NSImage, pkg: String) {
        icons[pkg] = image
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

    /// Re-issue window.open for every open window (used after a reconnect).
    func reopenAll() {
        for controller in allControllers() { controller.sendOpen() }
    }

    /// Apply labels to app windows once `apps` arrives (they may open before it).
    func applyLabels() {
        for controller in allControllers() {
            guard let app = controller as? AppWindowController,
                  let info = appsByPkg[app.pkg] else { continue }
            app.setTitle(info.label)
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
        case .windowTitle(let stream, let label, _):
            (controller(for: stream) as? PhoneWindowController)?.setTitle(label)
            (controller(for: stream) as? AppWindowController)?.setTitle(label)
            (controller(for: stream) as? LinkWindowController)?.setTitle(label)
        case .windowClosed(let stream, let reason):
            Log.app.info("phone closed stream \(stream, privacy: .public) (\(reason, privacy: .public))")
            controller(for: stream)?.closeFromRemote()
        case .ready(_, let isReconnect, _):
            if isReconnect { reopenAll() }
        default:
            break
        }
    }
}
