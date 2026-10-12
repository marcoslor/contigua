// Shared behaviour for the two window kinds: video routing, resize debounce,
// pause/resume on occlusion, close, and the ⌘+/⌘-/⌘0 density control.

import AppKit

class StreamWindowController: NSWindowController, NSWindowDelegate {
    let stream: UInt32
    let videoView: VideoLayerView
    unowned let manager: WindowManager

    /// UI scale: dpi = 160 × backingScale × density (0.75…1.5).
    var density: Double = 1.0
    private(set) var isPaused = false
    private var resizeWork: DispatchWorkItem?
    private var closingFromRemote = false

    init(stream: UInt32, contentSize: NSSize, manager: WindowManager) {
        self.stream = stream
        self.manager = manager
        self.videoView = VideoLayerView(frame: NSRect(origin: .zero, size: contentSize))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        super.init(window: window)
        window.delegate = self
        window.contentView = videoView
        let mapper = InputMapper(stream: stream)
        mapper.videoRectProvider = { [weak self] in self?.videoView.videoRect() ?? .zero }
        mapper.locationProvider = { [weak self] event in
            self?.videoView.convert(event.locationInWindow, from: nil) ?? .zero
        }
        mapper.viewIsFlipped = { [weak self] in self?.videoView.isFlipped ?? false }
        mapper.send = { [weak self] command in self?.handle(command) }
        videoView.inputMapper = mapper
        videoView.onRequestKeyframe = { [weak self] in
            guard let self else { return }
            self.manager.session.requestKeyframe(stream: self.stream)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Sizing

    var session: Session { manager.session }

    /// Virtual-display pixels for the current content size.
    func displayPixels() -> CGSize {
        guard let window else { return .zero }
        let bounds = videoView.bounds.size
        return VideoSize.displayPixels(bounds: bounds, backingScale: Double(window.backingScaleFactor))
    }

    func dpi() -> Double {
        guard window != nil else { return 160 * density }
        return VideoSize.dpi(pixels: displayPixels(), bounds: videoView.bounds.size, density: density)
    }

    func sendOpen() {}
    func sendResize() {
        let pixels = displayPixels()
        session.resizeWindow(stream: stream, width: Int(pixels.width), height: Int(pixels.height), dpi: dpi())
    }

    /// Programmatic content-size change (test hook + chrome actions).
    func setContentSize(_ size: NSSize) {
        window?.setContentSize(size)
    }

    // MARK: Presence

    func present() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(videoView)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeFromRemote() {
        closingFromRemote = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        resizeWork?.cancel()
        if !closingFromRemote { session.closeWindow(stream: stream) }
        manager.remove(stream: stream)
    }

    // MARK: Resize

    func windowDidResize(_ notification: Notification) {
        scheduleResize(after: 0.3)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        scheduleResize(after: 0)
    }

    private func scheduleResize(after delay: TimeInterval) {
        resizeWork?.cancel()
        if delay <= 0 {
            sendResize()
            videoView.needsLayout = true
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.sendResize() }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        videoView.needsLayout = true
    }

    // MARK: Occlusion / minimize

    func windowDidMiniaturize(_ notification: Notification) { setPaused(true) }
    func windowDidDeminiaturize(_ notification: Notification) { setPaused(shouldPause) }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        setPaused(shouldPause)
    }

    /// Minimized windows are never "visible", and AppKit can briefly report a
    /// visible occlusion state while miniaturizing; both fold into one flag.
    private var shouldPause: Bool {
        guard let window else { return false }
        return window.isMiniaturized || !window.occlusionState.contains(.visible)
    }

    func setPaused(_ paused: Bool) {
        guard !manager.shuttingDown, !closingFromRemote else { return }
        guard paused != isPaused else { return }
        isPaused = paused
        if paused { session.pauseWindow(stream: stream) } else { session.resumeWindow(stream: stream) }
    }

    // MARK: Density

    func adjustDensity(_ delta: Double) {
        density = min(max((density + delta).rounded(toPlaces: 3), 0.75), 1.5)
        sendResize()
    }

    func resetDensity() {
        density = 1.0
        sendResize()
    }

    // MARK: Input routing

    private func handle(_ command: InputMapper.Command) {
        switch command {
        case .touch(let action, let nx, let ny):
            session.touch(TouchEvent(action: action, nx: nx, ny: ny), stream: stream)
        case .scroll(let event):
            session.scroll(event, stream: stream)
        case .key(let event):
            session.key(event, stream: stream)
        case .text(let text):
            session.text(stream: stream, text: text)
        case .nav(let action):
            session.nav(stream: stream, action: action)
        case .adjustDensity(let delta):
            adjustDensity(delta)
        case .resetDensity:
            resetDensity()
        }
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
