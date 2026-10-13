// Owns the stream-id allocator and routes session events to the right window.
// One Mac window per stream; several app windows can be open at once.

import AppKit

final class WindowManager {
    let session: Session
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

    /// Set while the app is terminating so windows stop emitting pause/resume.
    private(set) var shuttingDown = false

    func beginShutdown() { shuttingDown = true }

    init(session: Session) {
        self.session = session
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
        lock.lock(); streams.removeValue(forKey: stream); lock.unlock()
        onChange?()
    }

    func closeAll() {
        lock.lock()
        let controllers = Array(streams.values)
        streams.removeAll()
        lock.unlock()
        for controller in controllers { controller.closeFromRemote() }
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
    func handleVideo(_ event: VideoEvent) {
        switch event {
        case .config(let stream, let config):
            controller(for: stream)?.videoView.configure(config)
        case .frame(let stream, let frame):
            controller(for: stream)?.videoView.enqueue(frame)
        }
    }

    func handle(_ event: SessionEvent) {
        switch event {
        case .windowTitle(let stream, let label, _):
            (controller(for: stream) as? PhoneWindowController)?.setTitle(label)
            (controller(for: stream) as? AppWindowController)?.setTitle(label)
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

/// App icons: memory first, disk under ~/Library/Caches/<profile folder>.
final class IconCache {
    static let shared = IconCache(profile: .active)
    private let directory: URL
    private let lock = NSLock()

    private init(profile: Profile) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        directory = base.appendingPathComponent(profile.supportDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func store(_ data: Data, pkg: String) {
        lock.lock(); defer { lock.unlock() }
        try? data.write(to: directory.appendingPathComponent("\(pkg).png"))
    }

    func load(pkg: String) -> NSImage? {
        guard let data = loadData(pkg: pkg) else { return nil }
        return NSImage(data: data)
    }

    /// Raw PNG (Spotlight thumbnails want the bytes, not an NSImage).
    func loadData(pkg: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return try? Data(contentsOf: directory.appendingPathComponent("\(pkg).png"))
    }
}
