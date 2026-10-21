// Shared behaviour for the two window kinds: video routing, resize debounce,
// pause/resume on occlusion, close, the ⌘+/⌘-/⌘0 density control and the
// window chrome (StreamChrome.swift).

import AppKit
import SwiftUI

class StreamWindowController: NSWindowController, NSWindowDelegate {
    /// The stream this window shows.
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
    
    /// The app whose density override this window follows; nil for the phone
    /// window (its dpi keeps the phone's dp width) and for a link or handoff
    /// window before the phone names its package.
    var densityPackage: String? { nil }

    /// Where this window's density override lives (WindowDensityStore).
    var densityKey: String? { densityPackage.flatMap { WindowDensityStore.key(forPackage: $0) } }

    /// The app's stored override; nil means the Settings default applies.
    var densityOverride: Double? { manager.densityStore.override(forKey: densityKey) }

    /// Whether the window's dpi follows the density setting at all. The phone
    /// window's does not.
    var usesDensity: Bool { true }

    /// UI scale: dpi = 160 × backingScale × density (0.75…1.5). The app's
    /// override, else Settings → General's default.
    var density: Double { DensityRules.effective(override: densityOverride, settings: manager.defaultDensity) }

    private(set) var isPaused = false
    /// What freezes the phone-side actions: Live Text (the frame is frozen),
    /// a stalled picture, or, in the phone window, a cover over the mirror. One
    /// predicate for the shortcuts, the bar's buttons, the Navigate menu and
    /// the input mapper.
    var frozen: Bool { liveText.isActive || isStalled }

    /// The picture watchdog (FrameWatchdog): frames counted from the session
    /// queue, the decision on the main thread.
    @ObservationIgnored let frameClock = FrameClock()
    private var watchdog = FrameWatchdog()
    private var stallTimer: Timer?
    private(set) var isStalled = false
    private var linkIsDown = false

    /// The watchdog's rule: a live session, the window on screen, and a picture
    /// that is wanted (not paused, not Live Text, no cover). While it is false
    /// the clock is idle and any stall is dropped: a covered or paused picture
    /// has no "live" claim to be wrong about.
    var expectsFrames: Bool {
        guard !isPaused, !liveText.isActive, !linkIsDown,
              let window, window.isVisible, !window.isMiniaturized else { return false }
        return true
    }
    /// The mode was active at the last change, and the phone is paused for it.
    private var liveTextWasActive = false
    private var liveTextPaused = false
    /// The standard buttons' slots before the chrome moved them, as an x and a
    /// distance from the window's top edge (the titlebar's anchor).
    private var standardLightSlots: [NSWindow.ButtonType: (x: CGFloat, fromTop: CGFloat, size: NSSize)] = [:]
    /// The windowed frame to come back to: AppKit restores a standard
    /// titlebar's 28 pt even though this window's titlebar is hidden and clear,
    /// which would grow the window and its stream on every full-screen exit.
    private var windowedFrame: NSRect?
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
        super.init(window: window)
        window.delegate = self
        window.contentView = chrome
        // Where AppKit put the standard buttons before the chrome moves them;
        // full screen gives them back (applyChromeConfig).
        captureStandardLights()
        chrome.onBarPress = { [weak self] in self?.barPresses += 1; self?.writeChromeState() }
        chrome.onLiveTextToggle = { [weak self] in self?.toggleLiveText() }
        chrome.liveTextDragProvider = { [weak self] in self?.liveText.dragFileURL() }
        chrome.setActions(headerActions())
        // The overlay's setting before the first state write: the file reports it.
        videoView.showsTouches = manager.showTouches
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
        // Live Text mode receives nothing: pointer, keys, scroll, hover and
        // trackpad all stop at the mapper (Esc leaves the mode instead).
        mapper.inputSuspended = { [weak self] in self?.frozen ?? false }
        mapper.onLiveTextEscape = { [weak self] in self?.exitLiveText(.escape) }
        mapper.send = { [weak self] command in self?.handle(command) }
        mapper.touchPointsChanged = { [weak self] points in self?.videoView.showTouchPoints(points) }
        mapper.hoverEnabled = { [weak self] in self?.manager.hoverEnabled ?? false }
        videoView.onDroppedFiles = { [weak manager] urls in manager?.onFilesDropped?(urls) }
        videoView.onTouchDotsChanged = { [weak self] in self?.writeChromeState() }
        videoView.inputMapper = mapper
        // In immersive the dwell feed already sees every move in the window;
        // the tracking area would report the same ones twice.
        videoView.hoverFeedActive = { [weak self] in
            guard let self else { return false }
            return self.style == .immersive && !(self.window?.styleMask.contains(.fullScreen) ?? false)
        }
        videoView.macUIAtWindowPoint = { [weak self] point in
            guard let self, self.style == .immersive, self.chrome.showsPill else { return false }
            let height = self.chrome.bounds.height
            let streamPoint = CGPoint(x: point.x, y: height - point.y)
            return self.chrome.pillStreamRect.insetBy(dx: -4, dy: -4).contains(streamPoint)
        }
        videoView.onRequestKeyframe = { [weak self] in
            guard let self else { return }
            self.manager.session.requestKeyframe(stream: self.stream)
        }
        videoView.liveText.onStateChange = { [weak self] state, reason in
            self?.liveTextChanged(state, reason)
        }
        // The picture watchdog's clock: a quarter-second is finer than the
        // one-second deadline and cheap.
        let stall = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickFrameWatchdog() }
        }
        RunLoop.main.add(stall, forMode: .common)
        stallTimer = stall
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        stallTimer?.invalidate()
    }

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
        ImmersiveMenuInstaller.refresh(style: style)
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
    /// otherwise and any shown pill is taken away. With Always Visible there
    /// is no dwell at all: the lights and the capsules stay up.
    private func configureDwell() {
        let immersive = style == .immersive && !(window?.styleMask.contains(.fullScreen) ?? false)
        let always = ImmersiveChrome.alwaysVisible(manager.revealDelay)
        chromeAlwaysVisible = immersive && always
        if immersive && ImmersiveChrome.usesDwell(alwaysVisible: always) {
            dwell = DwellPill(zone: CGRect(origin: .zero, size: DwellChrome.hotZone), pill: chrome.pillStreamRect,
                              dwell: manager.revealDelay.seconds)
            startDwellFeed()
            chrome.setPill(false)
            lastPillShown = false
        } else if chromeAlwaysVisible {
            stopDwellFeed()
            dwell = DwellPill(dwell: manager.revealDelay.seconds)
            lastPillShown = true
            chrome.setPill(true)
        } else {
            stopDwellFeed()
            dwell = DwellPill(dwell: manager.revealDelay.seconds)
            chrome.setPill(false)
            lastPillShown = false
        }
        chrome.placeTrafficLights()
        writeChromeState()
    }

    /// The chrome stays up by the Always Visible choice (not by a dwell).
    private var chromeAlwaysVisible = false

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

    /// Settings → General "Reveal controls after" / View ▸ Immersive changed:
    /// a switch into or out of Always Visible reconfigures the chrome; another
    /// delay re-times a rest already running (a shorter one can show the pill
    /// at once).
    func setRevealDelay(_ seconds: TimeInterval) {
        let always = ImmersiveChrome.alwaysVisible(manager.revealDelay)
        // Into or out of Always Visible: whether a dwell exists at all
        // changed, so reconfigure. Another delay only re-times the rest.
        if always || chromeAlwaysVisible {
            configureDwell()
            return
        }
        guard dwell.dwell != seconds else { return }
        dwell.setDwell(seconds)
        refreshDwell()
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
    /// The window closed: what the phone is told, before it is forgotten.
    func sendClose() { session.closeWindow(stream: stream) }
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
        captureStandardLights()
        chrome.placeTrafficLights()
        if manager.floatWindows { window?.orderFrontRegardless() }
        window?.makeFirstResponder(videoView)
        BackgroundMode.activateApp()
        configureDwell()
    }

    /// Frames are remembered per app (or "phone") in the profile's defaults.
    var frameKey: String { "stream" }

    func windowDidMove(_ notification: Notification) { rememberFrame() }

    private func rememberFrame() {
        // Never the screen-sized frame full screen moves the window to: the
        // next open would come back too big.
        guard let window, window.isVisible, !closingFromRemote,
              !window.styleMask.contains(.fullScreen), windowedFrame == nil else { return }
        manager.saveFrame(window.frame, forKey: frameKey)
    }

    func closeFromRemote() {
        closingFromRemote = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        liveText.exit(.close)
        dwellTimer?.invalidate()
        stopDwellFeed()
        resizeWork?.cancel()
        if !closingFromRemote { sendClose() }
        manager.remove(stream: stream)
    }

    // MARK: Resize

    func windowDidResize(_ notification: Notification) {
        // A stream window changing shape cannot keep a frozen frame: the new
        // picture would be a different size under the same overlay.
        liveText.exit(.resize)
        chrome.placeTrafficLights()
        scheduleResize(after: 0.3)
        writeChromeState()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        scheduleResize(after: 0)
        rememberFrame()
    }

    private func scheduleResize(after delay: TimeInterval) {
        // The window's shape changed: until the phone's frame at that size
        // arrives the last one fills it (VideoLayerView's pending rule). The
        // message itself is debounced below; the fill starts with the drag.
        videoView.noteResizeRequested()
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
        state.fullScreen = window?.styleMask.contains(.fullScreen) ?? false
        state.densityPackage = densityPackage
        state.densityOverride = densityOverride
        state.settingsDensity = manager.defaultDensity
        state.liveText = liveText.isActive
        state.frozen = frozen
        state.revealDelay = manager.revealDelay
        ImmersiveMenuInstaller.refresh(style: style)
    }

    func windowDidResignKey(_ notification: Notification) {
        let state = StreamMenuState.shared
        state.hasStream = false
        state.fullScreen = false
        state.densityPackage = nil
        state.densityOverride = nil
        state.liveText = false
        state.frozen = false
        videoView.windowResignedKey()
    }

    // MARK: View menu

    /// View → Show Touches: one setting for every stream window.
    @objc func toggleShowTouches(_ sender: Any?) {
        manager.showTouches.toggle()
    }

    // MARK: Live Text

    var liveText: LiveTextSession { videoView.liveText }

    /// View ▸ Live Text (⌘⇧T) and the bar button: enter from idle, leave from
    /// any other state.
    @objc func toggleLiveTextMenuAction(_ sender: Any?) { toggleLiveText() }

    func toggleLiveText() {
        if liveText.isActive { liveText.exit(.toggle) } else { enterLiveText() }
    }

    /// Enter the mode. False when there is no displayed frame yet (the window
    /// keeps showing live video) or it is already on.
    @discardableResult
    func enterLiveText() -> Bool {
        liveText.enter()
    }

    func exitLiveText(_ reason: LiveTextExitReason) {
        liveText.exit(reason)
    }

    /// The mode's state moves the phone and the chrome: the stream pauses at
    /// the phone while the frame is frozen, and the status pill and menu check
    /// follow. A close or a lost link resumes nothing: the stream is gone.
    private func liveTextChanged(_ state: LiveTextState, _ reason: LiveTextExitReason?) {
        let active = state.isActive
        if active, !liveTextWasActive {
            videoView.inputMapper?.dropPendingInput()
        }
        if state == .analyzing, !liveTextPaused {
            // The frame is frozen and the overlay is up: the picture can stop
            // arriving. (While capturing, the keyframe route is still asking
            // the phone for that frame, so the stream keeps running.)
            if !isPaused { session.pauseWindow(stream: stream) }
            liveTextPaused = true
        } else if !active, liveTextPaused {
            let streamEnded = reason == .close || reason == .disconnect
            if !streamEnded, !isPaused { session.resumeWindow(stream: stream) }
            liveTextPaused = false
        }
        liveTextWasActive = active
        chrome.setLiveText(active: active)
        StreamMenuState.shared.liveText = active
        updateFrozen()
    }

    /// Applies `frozen` everywhere it is read: the bar's action buttons, the
    /// Navigate menu, and the chrome state file. The cover (phone window) and
    /// Live Text both call it.
    func updateFrozen() {
        chrome.setFrozen(frozen)
        if window?.isKeyWindow ?? false { StreamMenuState.shared.frozen = frozen }
        writeChromeState()
    }

    /// The pointer moved to a point in the window (also the scripted driver's
    /// hover): the immersive dwell's feed, and the phone's mouse hover.
    func pointerMoved(toWindowPoint point: CGPoint) {
        if style == .immersive && !chromeAlwaysVisible {
            // DwellChrome's zone is in stream coordinates, top-left origin: in
            // immersive the window is exactly the stream.
            let height = chrome.bounds.height
            dwell.pointerMoved(to: CGPoint(x: point.x, y: height - point.y), now: now())
            refreshDwell()
        }
        // The global feed reports moves anywhere on the Mac: only one inside
        // the video is a hover over the phone.
        if videoView.bounds.contains(videoView.convert(point, from: nil)) {
            videoView.hoverPointerMoved(toWindowPoint: point)
        } else {
            videoView.inputMapper?.hoverExit()
        }
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Chrome state (e2e)

    private var barPresses = 0

    /// The scripted check reads what the chrome is doing here; `--debug-chrome-state
    /// FILE` puts the file on the manager.
    var stateFile: URL? { didSet { writeChromeState() } }

    func writeChromeState() {
        guard let stateFile else { return }
        let lights = window?.standardWindowButton(.closeButton).map { !$0.isHidden } ?? false
        let pillUp = chrome.showsPill
        let titleUp = window?.titleVisibility == .visible
        let managed = chrome.lightsManagedByAppKit ? "appkit" : "us"
        let fullScreen = window?.styleMask.contains(.fullScreen) ?? false
        let line = "style=\(style.rawValue) lights=\(lights ? "shown" : "hidden") pill=\(pillUp ? "shown" : "hidden")"
            + " title_visible=\(titleUp ? "yes" : "no") lights_managed=\(managed)"
            + " fullscreen=\(fullScreen ? "yes" : "no") clicks=\(barPresses)"
            + " dots=\(chrome.touchDotsOutsideMirror ? "outside" : "mirrored")"
            + " touches=\(videoView.showsTouches ? "on" : "off") dot_count=\(chrome.touchDotCount)"
            + " collection=\(window?.collectionBehavior.rawValue ?? 0)"
            + " collection_none=\(window?.collectionBehavior.contains(.fullScreenNone) == true ? 1 : 0)"
            + " menu_fullscreen=\(FullScreenMenu.allowsFullScreen(window) ? 1 : 0)"
            + " screen=\(chrome.phoneOverlay.cover == .screenOff ? "off" : "on")"
            + " overlay=\(chrome.phoneOverlay.cover == nil ? 0 : 1)"
            + " secure=\(chrome.phoneOverlay.cover == .secure ? 1 : 0)"
            + " stall=\(isStalled ? 1 : 0)\n"
        try? Data(line.utf8).write(to: stateFile, options: .atomic)
    }

    /// The dwell's state machine keeps its own time; the pill's fade and the
    /// lights follow it through `setPill`.

    /// The standard buttons' slots before the chrome moved them. AppKit lays
    /// them out at the window's top-left; only their distance from the top
    /// edge survives a window that grows to the screen.
    private func captureStandardLights() {
        guard let window else { return }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
        where standardLightSlots[type] == nil {
            guard let light = window.standardWindowButton(type), let superview = light.superview,
                  light.frame.width > 0, light.frame.height > 0 else { continue }
            let inWindow = superview.convert(light.frame, to: nil)
            standardLightSlots[type] = (inWindow.minX, window.frame.height - inWindow.maxY, inWindow.size)
        }
    }

    private func restoreStandardLights() {
        guard let window else { return }
        for (type, slot) in standardLightSlots {
            guard let light = window.standardWindowButton(type), let superview = light.superview else { continue }
            let frame = NSRect(x: slot.x, y: window.frame.height - slot.fromTop - slot.size.height,
                               width: slot.size.width, height: slot.size.height)
            light.frame = superview.convert(frame, from: nil)
            light.isHidden = false
            light.alphaValue = 1
        }
    }

    /// The titlebar and the buttons by state (ChromeConfig): the windowed
    /// chrome's hidden title and clear titlebar, or full screen's standard
    /// titlebar with the title shown and AppKit placing the buttons.
    private func applyChromeConfig(fullScreen: Bool) {
        guard let window else { return }
        let config = ChromeConfig.forState(style: style, fullScreen: fullScreen)
        window.titleVisibility = config.titleVisible ? .visible : .hidden
        window.titlebarAppearsTransparent = config.titlebarTransparent
        chrome.lightsManagedByAppKit = config.lightsManagedByAppKit
        if config.lightsManagedByAppKit {
            captureStandardLights()
            restoreStandardLights()
        }
    }

    /// Before the transition, so the system's bar slides in with the title and
    /// lights already in place (and out with the windowed chrome's).
    func windowWillEnterFullScreen(_ notification: Notification) {
        if let window, !window.styleMask.contains(.fullScreen) {
            windowedFrame = window.frame
        }
        applyChromeConfig(fullScreen: true)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        updateFullScreenMenuState(true)
        chromeLayoutChanged()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        // The titlebar goes back to hidden before the window starts back;
        // waiting for did-exit would flash the standard title.
        window?.titleVisibility = .hidden
        window?.titlebarAppearsTransparent = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        updateFullScreenMenuState(false)
        applyChromeConfig(fullScreen: false)
        if let window, let frame = windowedFrame, window.frame != frame {
            window.setFrame(frame, display: true)
        }
        windowedFrame = nil
        chromeLayoutChanged()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        windowedFrame = nil
        updateFullScreenMenuState(false)
        applyChromeConfig(fullScreen: false)
        chromeLayoutChanged()
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        updateFullScreenMenuState(true)
        applyChromeConfig(fullScreen: true)
        chromeLayoutChanged()
    }

    /// The Window menu's Enter/Exit Full Screen title follows the key window.
    private func updateFullScreenMenuState(_ fullScreen: Bool) {
        guard window?.isKeyWindow ?? false else { return }
        StreamMenuState.shared.fullScreen = fullScreen
        FullScreenMenu.setState(fullScreen: fullScreen)
    }

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

    // MARK: Picture watchdog

    /// One watchdog tick: fold in any frame the clock saw, then ask whether the
    /// silence has lasted long enough to call the picture stalled.
    private func tickFrameWatchdog() {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = frameClock.lastFrame {
            if watchdog.frame(at: last) { setStalled(false) }
        }
        let expecting = expectsFrames
        if !expecting {
            // Paused, covered, Live Text or the link down: the picture is not
            // presented as live, so there is nothing to call stale.
            setStalled(false)
        }
        if watchdog.tick(at: now, expecting: expecting) { setStalled(true) }
    }

    /// The picture stopped (or came back): the same kind of pill as the
    /// reconnecting one, "Not responding", and `stall=1` in the chrome state.
    /// A stall is a frozen mode: input and the phone-side actions stop too.
    private func setStalled(_ stalled: Bool) {
        guard stalled != isStalled else { return }
        isStalled = stalled
        if stalled {
            let pill = self.pill ?? GlassPillView(text: "Not responding", showsProgress: false)
            if self.pill == nil {
                self.pill = pill
                videoView.addSubview(pill)
                pill.alphaValue = 0
            }
            pill.setText("Not responding", showsProgress: false)
            layoutPill()
            pill.fade(to: 1)
            Log.video.notice("stream \(self.stream, privacy: .public): stall=1")
        } else {
            pill?.fade(to: 0)
            Log.video.notice("stream \(self.stream, privacy: .public): stall=0")
        }
        updateFrozen()
    }

    // MARK: Link state

    private var pill: GlassPillView?
    private var pillShowWork: DispatchWorkItem?
    private var pillOfflineWork: DispatchWorkItem?

    /// The link dropped or came back: a pill over the last frame says so after
    /// 1 s (a blip shows nothing), and "Phone offline" after 15 s.
    func setLinkDown(_ down: Bool) {
        linkIsDown = down
        if down {
            liveText.exit(.disconnect)
            setStalled(false)
        }
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

    /// ⌘+/⌘-: one step on the focused window's app override, created from the
    /// value it shows now when the app had none (View ▸ Density does the same
    /// for an exact option).
    func adjustDensity(_ delta: Double) {
        guard usesDensity, let pkg = densityPackage else { return }
        manager.setDensity(DensityRules.stepped(from: density, by: delta), forPackage: pkg)
    }

    /// ⌘0: back to the Settings default (the app's override is cleared).
    func resetDensity() {
        setDensityOverride(nil)
    }

    /// The View ▸ Density pick (nil is "Default") for this window's app.
    func setDensityOverride(_ value: Double?) {
        guard let pkg = densityPackage else { return }
        manager.setDensity(value, forPackage: pkg)
    }

    /// The app's override or the Settings default changed: the phone gets the
    /// new dpi. The value itself is computed, so this only re-sends.
    func applyStoredDensity() {
        guard window != nil else { return }
        sendResize()
    }

    /// Settings → General's default changed: apps without an override follow
    /// it at once.
    func defaultDensityChanged() {
        guard usesDensity, densityOverride == nil else { return }
        applyStoredDensity()
    }

    /// A link or handoff window learned the app it shows: that app's override
    /// (if it has one) now applies.
    func reapplyStoredDensity() {
        guard densityOverride != nil else { return }
        applyStoredDensity()
    }

    // MARK: Navigation

    /// Menu action (target nil, responder chain). Enabled in every stream window.
    /// Live Text freezes it: the phone behind the frozen frame is paused.
    @objc func navigateBack(_ sender: Any?) {
        guard HeaderActionPolicy.allowsPhoneShortcut(frozen: frozen) else { return }
        session.nav(stream: stream, action: "back")
    }

    /// A touch that passed through the immersive hot zone restarts the rest,
    /// so the pill can never appear while the finger is still tapping there
    /// (DwellPill.clickReachedApp; the touch itself goes on as normal input,
    /// with no added delay). Doubles as the scripted check's path.
    func touchInHotZone(_ event: TouchEvent) {
        guard !chromeAlwaysVisible, style == .immersive, let window, window.isVisible,
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
        case .hover(let event):
            session.hover(event, stream: stream)
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
