// Shared behaviour for the two window kinds: video routing, resize debounce,
// pause/resume on occlusion, close, the ⌘+/⌘-/⌘0 density control and the
// window chrome (StreamChrome.swift).

import AppKit
import SwiftUI

class StreamWindowController: NSWindowController, NSWindowDelegate {
    let stream: UInt32
    let videoView: VideoLayerView
    let chrome: StreamChromeView
    unowned let manager: WindowManager

    /// This window's chrome style: read from the profile's per-package key on
    /// open (WindowStyleStore); a window with nothing remembered opens framed.
    private(set) var style: WindowStyle
    /// The immersive dwell pill: pure state until its pill view exists (this
    /// file feeds it; the scripted driver's hover reaches the same path).
    private(set) var dwell = DwellPill()
    
    /// UI scale: dpi = 160 × backingScale × density (0.75…1.5).
    var density: Double = WindowDensity.current
    private(set) var isPaused = false
    private var resizeWork: DispatchWorkItem?
    private var closingFromRemote = false
    /// Folds the dwell's time in; `pointerMoved` also schedules a hide.
    private var dwellTimer: Timer?

    init(stream: UInt32, contentSize: NSSize, manager: WindowManager, styleKey: String?) {
        self.stream = stream
        self.manager = manager
        self.style = manager.styleStore.style(forKey: styleKey)
        self.videoView = VideoLayerView(frame: NSRect(origin: .zero, size: contentSize))
        // `contentSize` is the stream's; the window adds the style's bar above
        // it (WindowStyle.swift). The content view fills the whole window,
        // under a transparent titlebar, and is transparent itself outside
        // the stream.
        let frameSize = style.windowSize(stream: contentSize)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: frameSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.titlebarAppearsTransparent = true
        // The title still names the window in the Window menu and Mission Control.
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.setFrame(NSRect(origin: window.frame.origin, size: frameSize), display: false)
        chrome = StreamChromeView(video: videoView, style: style)
        chrome.mirror = manager.barMirror
        super.init(window: window)
        window.delegate = self
        window.contentView = chrome
        chrome.onBarPress = { [weak self] in self?.barPresses += 1; self?.writeChromeState() }
        chrome.setActions(headerActions())
        stateFile = manager.chromeStateFile
        writeChromeState()
        let mapper = InputMapper(stream: stream)
        mapper.videoRectProvider = { [weak self] in self?.videoView.videoRect() ?? .zero }
        mapper.locationProvider = { [weak self] event in
            self?.videoView.convert(event.locationInWindow, from: nil) ?? .zero
        }
        mapper.viewIsFlipped = { [weak self] in self?.videoView.isFlipped ?? false }
        mapper.videoSizeProvider = { [weak self] in self?.videoView.videoSize ?? .zero }
        mapper.escapeAllowed = { [weak self] in
            guard let window = self?.window else { return false }
            return window.isKeyWindow && window.attachedSheet == nil
        }
        mapper.send = { [weak self] command in self?.handle(command) }
        mapper.touchPointsChanged = { [weak self] points in self?.videoView.showTouchPoints(points) }
        videoView.onDroppedFiles = { [weak manager] urls in manager?.onFilesDropped?(urls) }
        videoView.inputMapper = mapper
        videoView.showsTouches = manager.showTouches
        videoView.onRequestKeyframe = { [weak self] in
            guard let self else { return }
            self.manager.session.requestKeyframe(stream: self.stream)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The defaults key this window's style is remembered under; nil while the
    /// window does not know the app it shows (a link window before the phone
    /// reports it). Written by every switch the window itself makes.
    var styleKey: String? { nil }

    /// The window kind's actions, at the bar's right end (the phone window's
    /// Back/Home/Recents), also inside the immersive pill.
    func headerActions() -> [HeaderAction] { [] }

    // MARK: Style switching

    /// View ▸ Window Style's switch (and the scripted driver's toggle): the
    /// window grows or shrinks by the bar above the stream (the stream keeps its place;
    /// `WindowStyle.frame` nudges it down when the bar would poke above the
    /// screen), the choice is remembered under this window's key. In full
    /// screen only the memory moves: the layout applies on exit (no bar there
    /// in either style).
    func setStyle(_ next: WindowStyle) {
        guard let window, next != style else { return }
        let fullScreen = window.styleMask.contains(.fullScreen)
        if !fullScreen {
            let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect.zero
            let target = style.frame(switchedTo: next, current: window.frame, visible: visible)
            window.setFrame(target, display: true)
        }
        style = next
        if let key = styleKey { manager.styleStore.set(style, forKey: key) }
        StreamMenuState.shared.style = style
        chrome.setStyle(style)
        configureDwell()
        writeChromeState()
    }

    /// The menu selectors (View ▸ Window Style's radio items).
    @objc func useFramedStyle(_ sender: Any?) { setStyle(.framed) }
    @objc func useImmersiveStyle(_ sender: Any?) { setStyle(.immersive) }

    /// View ▸ Toggle Window Style (⌥⌘F); the scripted driver's toggle is the
    /// same action.
    @objc func toggleStyleMenuAction(_ sender: Any?) { toggleStyle() }

    func toggleStyle() { setStyle(style == .framed ? .immersive : .framed) }
    /// A link or handoff window learned the app it shows: the stored choice
    /// for that package now applies (a no-op when it agrees).
    func reapplyStoredStyle() {
        guard let key = styleKey else { return }
        let stored = manager.styleStore.style(forKey: key)
        if stored != style { setStyle(stored) }
    }

    // MARK: Dwell (the immersive pill's driver)

    private var monitors: [Any] = []
    private var lastPillShown = false

    /// Only an immersive non-fullscreen window dwells; the feed stops
    /// otherwise and any shown pill is taken away.
    private func configureDwell() {
        let active = style == .immersive && !(window?.styleMask.contains(.fullScreen) ?? false)
        if active {
            dwell = DwellPill(zone: CGRect(origin: .zero, size: DwellChrome.hotZone), pill: chrome.pillStreamRect)
            startDwellFeed()
        } else {
            stopDwellFeed()
            dwell = DwellPill()
        }
        chrome.setPill(false)
        lastPillShown = false
        chrome.placeTrafficLights()
        writeChromeState()
    }

    func startDwellFeed() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.pointerMoved(toScreen: NSEvent.mouseLocation)
            return event
        }) { monitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.pointerMoved(toScreen: NSEvent.mouseLocation)
        }) { monitors.append(global) }
    }

    func stopDwellFeed() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    func pointerMoved(toScreen point: NSPoint) {
        guard let window, window.isVisible, style == .immersive,
              window.styleMask.contains(.fullScreen) == false else { return }
        pointerMoved(toWindowPoint: window.convertPoint(fromScreen: point))
    }

    /// Folds the dwell's time in now; also what the show/hide timers call.
    private func refreshDwell() {
        dwell.update(now: now())
        dwellTimer?.invalidate()
        dwellTimer = nil
        if let hideAt = dwell.hideAt {
            dwellTimer = Timer(timeInterval: max(hideAt - now(), 0), repeats: false) { [weak self] _ in
                self?.refreshDwell()
            }
            RunLoop.main.add(dwellTimer!, forMode: .common)
        } else if !dwell.shown, let start = dwell.restStart {
            dwellTimer = Timer(timeInterval: max(start + dwell.dwell - now(), 0), repeats: false) { [weak self] _ in
                self?.refreshDwell()
            }
            RunLoop.main.add(dwellTimer!, forMode: .common)
        }
        if dwell.shown != lastPillShown {
            lastPillShown = dwell.shown
            chrome.setPill(dwell.shown)
        }
        writeChromeState()
    }

    // MARK: Sizing

    var session: Session { manager.session }

    /// The stream in points: the window minus the style's bar, whether the bar
    /// shows or not. This is what the virtual display is sized from.
    func videoBounds() -> CGSize {
        guard let window, let chrome = window.contentView as? StreamChromeView else { return .zero }
        return style.streamSize(window: chrome.bounds.size, fullScreen: window.styleMask.contains(.fullScreen))
    }

    /// Virtual-display pixels for the video area.
    func displayPixels() -> CGSize {
        guard let window else { return .zero }
        return VideoSize.displayPixels(bounds: videoBounds(), backingScale: Double(window.backingScaleFactor))
    }

    func dpi() -> Double {
        guard window != nil else { return 160 * density }
        return VideoSize.dpi(pixels: displayPixels(), bounds: videoBounds(), density: density)
    }

    func sendOpen() {}
    /// Reapply the window's title after the phone's display name changed.
    func retitle() {}
    func sendResize() {
        let pixels = displayPixels()
        session.resizeWindow(stream: stream, width: Int(pixels.width), height: Int(pixels.height), dpi: dpi())
    }

    /// Programmatic stream size change (test hook); the top-left stays put.
    func setContentSize(_ streamSize: NSSize) {
        guard let window else { return }
        let size = style.windowSize(stream: streamSize)
        let top = window.frame.maxY
        window.setFrame(NSRect(x: window.frame.minX, y: top - size.height, width: size.width, height: size.height),
                        display: true)
    }

    // MARK: Presence

    /// Where this window opens: the frame it had last time, else a cascade
    /// step from the previous stream window (never on top of the Deck).
    func present() {
        if let window {
            if let saved = manager.savedFrame(forKey: frameKey), saved.size.width >= 240, saved.size.height >= 160 {
                window.setFrame(manager.clampedToScreen(saved), display: false)
            } else {
                window.setFrameTopLeftPoint(manager.nextCascadeOrigin(for: window))
            }
        }
        if manager.floatWindows { window?.level = .floating }
        window?.makeKeyAndOrderFront(nil)
        if let forced = ProcessInfo.processInfo.environment["PD_APPEARANCE"], let window {
            // Debug-only (bisect/screenshot runs): force the window's look.
            window.appearance = NSAppearance(named: forced == "light" ? .aqua : .darkAqua)
        }
        chrome.placeTrafficLights()
        if manager.floatWindows { window?.orderFrontRegardless() }
        window?.makeFirstResponder(videoView)
        NSApp.activate(ignoringOtherApps: true)
        configureDwell()
    }

    /// Frames are remembered per app (or "phone") in the profile's defaults.
    var frameKey: String { "stream" }

    func windowDidMove(_ notification: Notification) { rememberFrame() }

    private func rememberFrame() {
        guard let window, window.isVisible, !closingFromRemote else { return }
        manager.saveFrame(window.frame, forKey: frameKey)
    }

    func closeFromRemote() {
        closingFromRemote = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        dwellTimer?.invalidate()
        stopDwellFeed()
        resizeWork?.cancel()
        if !closingFromRemote { session.closeWindow(stream: stream) }
        manager.remove(stream: stream)
    }

    // MARK: Resize

    func windowDidResize(_ notification: Notification) {
        chrome.placeTrafficLights()
        scheduleResize(after: 0.3)
        writeChromeState()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        scheduleResize(after: 0)
        rememberFrame()
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
        let w = window
        let sp = shouldPause
        Log.video.info("occlusion changed: visible=\(w?.isVisible ?? false) mini=\(w?.isMiniaturized ?? false) occl.hasVisible=\(w?.occlusionState.contains(.visible) ?? false) raw=\(String(describing: w?.occlusionState.rawValue)) -> pause=\(sp)")
        setPaused(sp)
    }

    /// Minimized windows are never "visible", and AppKit can briefly report a
    /// visible occlusion state while miniaturizing; both fold into one flag.
    /// `occlusionState` can spuriously report !visible for the frontmost window,
    /// which would detach its encoder; the key/main window never pauses.
    private var shouldPause: Bool {
        guard let window else { return false }
        if window.isMiniaturized { return true }
        if window.isKeyWindow || window.isMainWindow { return false }
        return !window.occlusionState.contains(.visible)
    }

    func setPaused(_ paused: Bool) {
        let changed = paused != self.isPaused
        Log.video.info("setPaused paused=\(paused) was=\(self.isPaused) changed=\(changed) mini=\(self.window?.isMiniaturized ?? false) key=\(self.window?.isKeyWindow ?? false)")
        guard !manager.shuttingDown, !closingFromRemote else { return }
        guard changed else { return }
        self.isPaused = paused
        if paused { session.pauseWindow(stream: stream) } else { session.resumeWindow(stream: stream) }
    }

    // MARK: Focus

    func windowDidBecomeKey(_ notification: Notification) {
        let state = StreamMenuState.shared
        state.hasStream = true
        state.showTouches = manager.showTouches
        state.style = style
    }

    func windowDidResignKey(_ notification: Notification) {
        StreamMenuState.shared.hasStream = false
        videoView.windowResignedKey()
    }

    // MARK: View menu

    /// View → Show Touches: one setting for every stream window.
    @objc func toggleShowTouches(_ sender: Any?) {
        manager.showTouches.toggle()
    }

    /// The pointer moved to a point in the window (also the scripted driver's
    /// hover): the immersive dwell's feed. Framed never dwells.
    func pointerMoved(toWindowPoint point: CGPoint) {
        guard style == .immersive else { return }
        // DwellChrome's zone is in stream coordinates, top-left origin: in
        // immersive the window is exactly the stream.
        let height = chrome.bounds.height
        dwell.pointerMoved(to: CGPoint(x: point.x, y: height - point.y), now: now())
        refreshDwell()
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Chrome state (e2e)

    private var barPresses = 0

    /// The scripted check reads what the chrome is doing here; `--debug-chrome-state
    /// FILE` puts the file on the manager.
    var stateFile: URL? { didSet { writeChromeState() } }

    private func writeChromeState() {
        guard let stateFile else { return }
        let lights = window?.standardWindowButton(.closeButton).map { !$0.isHidden } ?? false
        let pillUp = chrome.showsPill
        let line = "style=\(style.rawValue) lights=\(lights ? "shown" : "hidden") pill=\(pillUp ? "shown" : "hidden") clicks=\(barPresses)\n"
        try? Data(line.utf8).write(to: stateFile, options: .atomic)
    }

    /// The dwell's state machine keeps its own time; the pill's fade and the
    /// lights follow it through `setPill`.

    func windowDidEnterFullScreen(_ notification: Notification) { chromeLayoutChanged() }
    func windowDidExitFullScreen(_ notification: Notification) { chromeLayoutChanged() }

    /// Full screen drops the bar in either style and leaves the dwell alone:
    /// the stream is then the whole screen.
    private func chromeLayoutChanged() {
        chrome.layoutChrome()
        chrome.placeTrafficLights()
        chrome.setPill(false)
        lastPillShown = false
        configureDwell()
        scheduleResize(after: 0)
        writeChromeState()
    }

    // MARK: Link state

    private var pill: GlassPillView?
    private var pillShowWork: DispatchWorkItem?
    private var pillOfflineWork: DispatchWorkItem?

    /// The link dropped or came back: a pill over the last frame says so after
    /// 1 s (a blip shows nothing), and "Phone offline" after 15 s.
    func setLinkDown(_ down: Bool) {
        pillShowWork?.cancel()
        pillOfflineWork?.cancel()
        guard down else {
            pill?.fade(to: 0)
            return
        }
        let show = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let pill = self.pill ?? GlassPillView(text: "Reconnecting…", showsProgress: true)
            if self.pill == nil {
                self.pill = pill
                self.videoView.addSubview(pill)
                pill.alphaValue = 0
            }
            pill.setText("Reconnecting…", showsProgress: true)
            self.layoutPill()
            pill.fade(to: 1)
        }
        let offline = DispatchWorkItem { [weak self] in
            self?.pill?.setText("Phone offline", showsProgress: false)
            self?.layoutPill()
        }
        pillShowWork = show
        pillOfflineWork = offline
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: show)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: offline)
    }

    // MARK: File-drop pill (docs/design/dragdrop.md)

    private var dropPill: GlassPillView?

    /// Over the last frame: "Sending report.pdf… 43 %", then the outcome.
    /// nil hides the pill (a finished transfer fades when the state times out).
    func setDropPill(_ state: (text: String, showsProgress: Bool)?) {
        guard let state else { dropPill?.fade(to: 0); return }
        let pill = dropPill ?? GlassPillView(text: state.text, showsProgress: state.showsProgress)
        if dropPill == nil {
            dropPill = pill
            videoView.addSubview(pill)
            pill.alphaValue = 0
        }
        pill.setText(state.text, showsProgress: state.showsProgress)
        layoutDropPill()
        pill.fade(to: 1)
    }

    private func layoutDropPill() {
        guard let dropPill else { return }
        let size = dropPill.fittingSize
        dropPill.frame = NSRect(x: (videoView.bounds.width - size.width) / 2,
                                y: videoView.bounds.height - size.height - 24,
                                width: size.width, height: size.height)
        dropPill.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
    }

    private func layoutPill() {
        guard let pill else { return }
        let size = pill.fittingSize
        pill.frame = NSRect(x: (videoView.bounds.width - size.width) / 2, y: 24, width: size.width, height: size.height)
        pill.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
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

    // MARK: Navigation

    /// Menu action (target nil, responder chain). Enabled in every stream window.
    @objc func navigateBack(_ sender: Any?) {
        session.nav(stream: stream, action: "back")
    }

    /// A touch that passed through the immersive hot zone restarts the rest,
    /// so the pill can never appear while the finger is still tapping there
    /// (DwellPill.clickReachedApp; the touch itself goes on as normal input,
    /// with no added delay). Doubles as the scripted check's path.
    func touchInHotZone(_ event: TouchEvent) {
        guard style == .immersive, let window, window.isVisible,
              window.styleMask.contains(.fullScreen) == false, event.action == .down else { return }
        let bounds = videoBounds()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let point = CGPoint(x: CGFloat(event.nx) * bounds.width, y: CGFloat(event.ny) * bounds.height)
        if dwell.zone.contains(point) {
            dwell.clickReachedApp(at: point, now: now())
            refreshDwell()
        }
    }

    // MARK: Input routing

    private func handle(_ command: InputMapper.Command) {
        switch command {
        case .touch(let event):
            touchInHotZone(event)
            session.touch(event, stream: stream)
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
