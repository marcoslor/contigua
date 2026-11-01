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

    /// The opening cover (OpeningCover, docs/UX.md): from the window's open
    /// until the stream's first frame, then for the retry/failure wording.
    private(set) var opening = OpeningCover(startedAt: 0)
    private var openingTimer: Timer?
    /// The phase on screen, so the timer only redraws when it changes.
    private var openingPhase: OpeningCover.Phase?

    /// The kinds with an opening cover; a link or handoff window has no icon
    /// or name to show before its first frame.
    var showsOpeningCover: Bool { false }
    var openingName: String { "" }
    var openingIcon: NSImage? { nil }
    var openingIsPhone: Bool { false }

    /// The cover is over the window: no input to the phone, and no live
    /// picture for the watchdog to call stale yet.
    var isOpening: Bool { showsOpeningCover && opening.isUp }

    /// What freezes the phone-side actions: Live Text (the frame is frozen),
    /// a stalled picture, the opening cover, or, in the phone window, a cover
    /// over the mirror. One predicate for the shortcuts, the bar's buttons,
    /// the Navigate menu and the input mapper.
    var frozen: Bool { liveText.isActive || isStalled || isOpening }

    /// The mirror's bar from the keyboard (MIRROR-13): picture ↔ bar(index).
    /// One machine decides, one place applies it, and every transition is
    /// logged so a field log shows the path.
    private(set) var barFocus = BarFocus()

    /// The window's appearance, by name, for the chrome state: the shot check
    /// and the review read whether a capture really was dark.
    var barAppearanceName: String {
        guard let match = window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) else {
            return "aqua"
        }
        return match == .darkAqua ? "darkAqua" : "aqua"
    }

    /// The bar's focused button for the chrome state (`none` on the picture).
    var barFocusState: String {
        barFocus.index.map(String.init) ?? "none"
    }

    /// The picture watchdog (FrameWatchdog): frames counted from the session
    /// queue, the decision on the main thread.
    @ObservationIgnored let frameClock = FrameClock()
    private var watchdog = FrameWatchdog()
    private var stallTimer: Timer?
    /// The local key monitor that gives the bar its keys before AppKit's own
    /// Tab handling (see `handleBarKey`).
    private var barKeyMonitor: Any?
    /// The picture's state (WIN-39): live, stalled, or the link's two down
    /// steps. One machine, whose presentation is the disconnection overlay.
    private(set) var picture = PictureState()
    var isStalled: Bool { picture.isStalled }
    /// The link is down: the bar's phone-side controls are dimmed, with the
    /// reason, so a click cannot vanish into a dead session (M3, item 8).
    private(set) var phoneControlsOffline = false
    private var linkIsDown: Bool { picture.isLinkDown }

    /// The watchdog's rule: a live session, the window on screen, and a picture
    /// that is wanted (not paused, not Live Text, no cover). While it is false
    /// the clock is idle and any stall is dropped: a covered or paused picture
    /// has no "live" claim to be wrong about.
    var expectsFrames: Bool {
        guard !isPaused, !liveText.isActive, !linkIsDown, !isOpening,
              let window, window.isVisible, !window.isMiniaturized,
              !isWindowOccluded else { return false }
        return true
    }

    /// Tests and the e2e replace the WindowServer's occlusion state (a test
    /// process cannot cover its own window, and the quiet e2e run may not put
    /// another app's window over it). nil means the real state.
    var occlusionVisibleOverride: Bool?

    /// The WindowServer's answer, with the test override on top. A covered
    /// window keeps its last frame on screen but is not a live picture: AppKit
    /// throttles an occluded app, so its silence says nothing about the phone.
    var isWindowOccluded: Bool {
        if let occlusionVisibleOverride { return !occlusionVisibleOverride }
        guard let window else { return true }
        return !window.occlusionState.contains(.visible)
    }

    /// The e2e's `occlude` command: the WindowServer state a quiet run cannot
    /// produce. Tests set `occlusionVisibleOverride` and drive the clock.
    func setOcclusionVisible(_ visible: Bool?) {
        occlusionVisibleOverride = visible
        tickFrameWatchdog()
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
        // The app sets this window's frame itself (a stream's size, a phone's
        // turn): the backstop leaves those frames to the delegate above.
        WindowFrameLimit.owns(window)
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
        opening = OpeningCover(startedAt: now())
        stateFile = manager.chromeStateFile
        startOpeningCover()
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
        mapper.onStyleToggle = { [weak self] in self?.toggleStyle() }
        mapper.send = { [weak self] command in self?.handle(command) }
        // The bar's own keys, before the phone's: ⌃Tab takes the keyboard to
        // the bar, and while it is there the bar's keys never reach the phone
        // (MIRROR-13).
        mapper.barKey = { [weak self] event in self?.handleBarKey(event) ?? false }
        mapper.barKeyUp = { [weak self] event in self?.handleBarKey(event) ?? false }
        mapper.touchPointsChanged = { [weak self] points in self?.videoView.showTouchPoints(points) }
        mapper.hoverEnabled = { [weak self] in self?.manager.hoverEnabled ?? false }
        mapper.secondaryClick = { [weak self] in self?.manager.secondaryClick ?? .longPress }
        videoView.onDroppedFiles = { [weak manager] urls in manager?.onFilesDropped?(urls) }
        videoView.onPointerDown = { [weak self] in self?.resetBarFocus() }
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
        // The picture watchdog's clock.
        let stall = Timer(timeInterval: FrameWatchdog.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickFrameWatchdog() }
        }
        RunLoop.main.add(stall, forMode: .common)
        stallTimer = stall
        startBarKeyMonitor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        stallTimer?.invalidate()
        openingTimer?.invalidate()
        settleTimer?.invalidate()
        if let barKeyMonitor { NSEvent.removeMonitor(barKeyMonitor) }
    }

    /// The defaults key this window's style is remembered under; nil while the
    /// window does not know the app it shows (a link window before the phone
    /// reports it). Written by every switch the window itself makes.
    var styleKey: String? { nil }

    /// The window kind's actions, at the bar's right end (the phone window's
    /// Back/Home/Recents), also inside the immersive pill.
    func headerActions() -> [HeaderAction] { [] }

    // MARK: Opening cover

    /// The cover is up from the open: its clock moves it from the opening
    /// state to the slow one at 5 s and to the failure at 20 s; the first
    /// frame, the phone's refusal and Cancel are the other events.
    private func startOpeningCover() {
        guard showsOpeningCover else { return }
        chrome.openingCover.onCancel = { [weak self] in self?.cancelOpening() }
        chrome.openingCover.onClose = { [weak self] in self?.window?.close() }
        openingPhase = opening.phase(at: now())
        showOpeningPhase()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickOpeningCover() }
        }
        RunLoop.main.add(timer, forMode: .common)
        openingTimer = timer
    }

    private func tickOpeningCover() {
        guard isOpening else {
            openingTimer?.invalidate()
            openingTimer = nil
            return
        }
        guard let actions = opening.handle(.tick(now()), at: now()) else { return }
        openingPhase = opening.phase(at: now())
        showOpeningPhase()
        writeChromeState()
        run(actions)
    }

    /// The title and the failure's wording use the phone's display name.
    private var openingPhone: String { manager.phoneName }

    /// The app's label or the phone's name arrived while the cover is up: the
    /// title says it now instead of at the next phase change.
    func refreshOpeningCover() {
        guard showsOpeningCover, opening.isUp else { return }
        openingPhase = opening.phase(at: now())
        showOpeningPhase()
    }

    private func showOpeningPhase() {
        let display = OpeningCover.display(openingPhase, name: openingName,
                                           phone: openingPhone, phoneMode: openingIsPhone)
        chrome.openingCover.show(display, icon: openingIcon)
        // The cover's ground takes the bar's haze with it (WIN-40).
        chrome.updateBarHaze()
        // The cover is a frozen mode: the bar's phone-side controls dim with
        // it, from the first moment to a refusal (WIN-22, item M9).
        updateFrozen()
    }

    /// The stream's first frame arrived (WindowManager); once per window.
    func noteFirstFrame() {
        guard showsOpeningCover, let actions = opening.handle(.firstFrame, at: now()) else { return }
        openingTimer?.invalidate()
        openingTimer = nil
        openingPhase = nil
        showOpeningPhase()
        Log.video.notice("stream \(self.stream, privacy: .public): first frame, opening cover off")
        // The extension view builds its backdrop once the stream it mirrors has
        // a frame: turn its radius up now that it exists (WIN-40). This is also
        // where a macOS without the filter gets its one fact line.
        chrome.reapplyBarBlur(reportMissing: true)
        updateFrozen()
        tickFrameWatchdog()
        run(actions)
    }

    /// Cancel on the slow cover: closing the window cancels the open on the
    /// phone too (its `window.close`), so the phone does not keep launching.
    func cancelOpening() {
        guard showsOpeningCover, let actions = opening.handle(.cancel, at: now()) else { return }
        Log.video.notice("stream \(self.stream, privacy: .public): opening cancelled by the person")
        run(actions)
    }

    /// The phone refused the open (an `error` code): the cover greys out, says
    /// why once and offers Close alone. A code the cover cannot explain has no
    /// reason line; nothing is resent.
    func refuseOpening(_ code: String) {
        guard showsOpeningCover, let actions = opening.handle(.refused(code), at: now()) else { return }
        openingTimer?.invalidate()
        openingTimer = nil
        openingPhase = opening.phase(at: now())
        showOpeningPhase()
        writeChromeState()
        updateFrozen()
        Log.video.notice("stream \(self.stream, privacy: .public): opening refused")
        run(actions)
    }

    /// Runs the machine's actions: the transition never touches a window.
    private func run(_ actions: [OpeningCover.Action]) {
        for action in actions {
            switch action {
            case .closeWindow:
                window?.close()
            }
        }
    }

    /// The chrome state's `loading=`: 1 while the cover is up, failed when it
    /// gave up or the phone refused, 0 once the frame is in (or for a window
    /// with no cover).
    private var openingState: String {
        guard showsOpeningCover else { return "0" }
        switch opening.phase(at: now()) {
        case .opening?, .slow?: return "1"
        case .failed?: return "failed"
        case nil: return "0"
        }
    }

    /// The cover's buttons, as the view shows them: `none`, `cancel` or
    /// `close`. The e2e's proof that a failure cannot be asked again.
    private var openingButtons: String {
        guard showsOpeningCover, let phase = opening.phase(at: now()) else { return "none" }
        switch phase {
        case .opening: return "none"
        case .slow: return "cancel"
        case .failed: return "close"
        }
    }

    /// The cover's phase on screen: opening, slow, failed, 0 for no cover.
    private var openingCoverPhase: String {
        guard showsOpeningCover, let phase = opening.phase(at: now()) else { return "0" }
        switch phase {
        case .opening: return "opening"
        case .slow: return "slow"
        case .failed: return "failed"
        }
    }

    // MARK: Bar keyboard focus

    /// ⌃Tab, ←/→, Tab, Return, Space and Esc while the bar has the keyboard
    /// (MIRROR-13). True when the bar took the event: it never reaches the
    /// phone. Keys the machine ignores in that state are still the bar's, so a
    /// focused bar cannot type on the phone by accident.
    ///
    /// Called from a local key monitor, before AppKit's own Tab and key-view
    /// handling (a Mac with Full Keyboard Access on takes Tab in the window's
    /// focus machinery, so it never reaches the view's keyDown), and from the
    /// mapper for an event the monitor let through.
    func handleBarKey(_ event: NSEvent) -> Bool {
        guard let barEvent = BarFocus.event(keyCode: event.keyCode,
                                            control: event.modifierFlags.contains(.control),
                                            shift: event.modifierFlags.contains(.shift))
        else { return false }
        // A release is the bar's only while the bar has the focus: the phone
        // must never see an up without its down.
        if event.type == .keyUp { return barFocus.isOnBar }
        let before = barFocus
        let routing = barFocus.route(barEvent, focusable: chrome.focusableBarIndices)
        if barFocus != before {
            let fromIndex = before.index ?? -1
            let toIndex = barFocus.index ?? -1
            Log.video.notice("bar focus: from=\(fromIndex, privacy: .public) to=\(toIndex, privacy: .public)")
        }
        applyBarFocus(routing.action)
        return routing.consumed
    }

    /// The local monitor that sees the bar's keys first (MIRROR-13).
    private func startBarKeyMonitor() {
        guard barKeyMonitor == nil else { return }
        barKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) {
            [weak self] event in
            guard let self, let window = self.window, window.isKeyWindow else { return event }
            return self.handleBarKey(event) ? nil : event
        }
    }

    /// The ring follows the machine, and Return/Space run the button it names
    /// (the action the mouse runs, through the same policy gate).
    private func applyBarFocus(_ action: BarFocus.Action?) {
        switch action {
        case .focus(let index):
            chrome.setBarFocus(index)
            writeChromeState()
        case .picture:
            chrome.setBarFocus(nil)
            writeChromeState()
        case .press(let index):
            guard let action = chrome.barAction(at: index),
                  HeaderActionPolicy.isEnabled(action.kind, frozen: frozen,
                                               offline: phoneControlsOffline) else { return }
            Log.video.notice("bar focus: press \(index, privacy: .public)")
            action.perform()
        case nil:
            // No transition: the ring is where the machine already put it.
            chrome.setBarFocus(barFocus.index)
        }
    }

    /// A click on the picture, or the window losing the keyboard, gives it back
    /// to the phone: the bar's ring goes.
    func resetBarFocus() {
        guard barFocus.isOnBar else { return }
        barFocus = BarFocus()
        chrome.setBarFocus(nil)
        writeChromeState()
        Log.video.notice("bar focus: from=\(-1, privacy: .public) to=\(-1, privacy: .public) (reset)")
    }

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

    /// The window's resize requests, coalesced: one in flight, at most one
    /// waiting (ResizeCoalescer). A person's burst of ⌘+/⌘- presses used to
    /// send every value, and every request re-attaches the phone's encoder.
    private var resizes = ResizeCoalescer()

    /// How long the Mac waits for the phone to answer one resize before it
    /// counts it settled (ResizeCoalescer `.settleTimeout`). The NFR stall limit
    /// (`density_burst_stall_ms`), the same 1.5 s the window's own "Not
    /// responding" rule uses. A bound on a protocol wait, not a debounce of
    /// layout input: a request still goes out the moment the machine allows.
    static let resizeSettleTimeout: TimeInterval = FrameWatchdog.staleAfter

    /// Posts `.settleTimeout` while a request is in flight; restarted by every
    /// send and dropped when nothing is in flight.
    private var settleTimer: Timer?
    /// The stall was said once for this window: a phone that never answers must
    /// not fill the log with the same line.
    private var resizeStallLogged = false

    private func resizeRequest() -> ResizeRequest {
        let pixels = displayPixels()
        return ResizeRequest(w: Int(pixels.width), h: Int(pixels.height),
                             dpi: Int(dpi().rounded()))
    }

    func sendResize() {
        #if PD_TEST_HOOKS
        // Every coalescer event is applied on main (WindowManager.handleVideo
        // hops): the window's view state is main-thread state.
        dispatchPrecondition(condition: .onQueue(.main))
        #endif
        send(resizes.apply(.request(resizeRequest())))
    }

    /// The phone answered a resize: its `window.resize.ack`, or the
    /// VIDEO_CONFIG that follows one. The value that waited goes out now.
    func resizeSettled(_ request: ResizeRequest? = nil) {
        #if PD_TEST_HOOKS
        dispatchPrecondition(condition: .onQueue(.main))
        #endif
        guard let settled = request ?? resizes.inFlight else { return }
        send(resizes.apply(.settled(settled)))
    }

    private func send(_ actions: [ResizeCoalescer.Action]) {
        for action in actions {
            switch action {
            case .send(let request):
                session.resizeWindow(stream: stream, width: request.w, height: request.h,
                                     dpi: Double(request.dpi))
                armSettleTimer()
            }
        }
        if resizes.inFlight == nil {
            settleTimer?.invalidate()
            settleTimer = nil
        }
    }

    private func armSettleTimer() {
        settleTimer?.invalidate()
        let timer = Timer(timeInterval: Self.resizeSettleTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.settleTimedOut() }
        }
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    /// The phone did not answer in time: the machine counts the request as
    /// settled and sends what waited (a phone that predates the ack sends none,
    /// and a paused or refused resize carries no new CONFIG either).
    private func settleTimedOut() {
        settleTimer = nil
        guard resizes.inFlight != nil else { return }
        if !resizeStallLogged {
            resizeStallLogged = true
            Log.video.notice("stream \(self.stream, privacy: .public): resize unanswered, moving on")
        }
        send(resizes.apply(.settleTimeout))
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
        // A window that opted out of full screen cannot keep the Window menu's
        // item disabled once it is gone: nothing may become key after it in a
        // quiet app, and the answer it published would stay behind.
        if self is PhoneWindowController || (window?.isKeyWindow ?? false) {
            StreamMenuState.shared.fullScreenAllowed = true
            StreamMenuState.shared.fullScreen = false
        }
        liveText.exit(.close)
        openingTimer?.invalidate()
        openingTimer = nil
        dwellTimer?.invalidate()
        stopDwellFeed()
        resizeWork?.cancel()
        settleTimer?.invalidate()
        settleTimer = nil
        if !closingFromRemote { sendClose() }
        manager.remove(stream: stream)
    }

    // MARK: Resize

    /// The person is dragging a corner: only the drag sets the frame until it
    /// ends. A stream event (a rotation) must not move the window under the
    /// hand; it waits for `windowDidEndLiveResize`.
    private(set) var isLiveResizing = false

    func windowWillStartLiveResize(_ notification: Notification) {
        isLiveResizing = true
    }

    /// The proposed size a person's drag or an Accessibility resize asks for,
    /// kept inside the screen the window is on (CONV-MAC-12). The app's own
    /// `setFrame` — a stream's size, the phone's turn — does not come through
    /// here and keeps its size on the e2e's virtual display.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        WindowFrameLimit.size(frameSize, for: sender)
    }

    /// One step of the e2e's scripted drag: the same delegate call AppKit makes
    /// for a mouse move, then the frame it returns.
    func liveResizeStep(to proposed: NSSize) {
        guard let window else { return }
        let snapped = windowWillResize(window, to: proposed)
        window.setFrame(NSRect(origin: window.frame.origin, size: snapped), display: true)
    }

    func windowDidResize(_ notification: Notification) {
        // A stream window changing shape cannot keep a frozen frame: the new
        // picture would be a different size under the same overlay.
        liveText.exit(.resize)
        chrome.placeTrafficLights()
        scheduleResize(after: 0.3)
        writeChromeState()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        isLiveResizing = false
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
        // The watchdog's clock must not carry the covered time across: the
        // notification also reaches a window whose timer AppKit has throttled.
        tickFrameWatchdog()
    }

    /// Minimized windows are never "visible", and AppKit can briefly report a
    /// visible occlusion state while miniaturizing; both fold into one flag.
    /// `occlusionState` can spuriously report !visible for the frontmost window,
    /// which would detach its encoder; the key/main window never pauses.
    private var shouldPause: Bool {
        guard let window else { return false }
        return StreamPause.shouldPause(miniaturized: window.isMiniaturized,
                                       key: window.isKeyWindow,
                                       main: window.isMainWindow,
                                       occludedVisible: window.occlusionState.contains(.visible),
                                       menuTracking: MenuTracking.isTracking)
    }

    func setPaused(_ paused: Bool) {
        let changed = paused != self.isPaused
        Log.video.info("setPaused paused=\(paused) was=\(self.isPaused) changed=\(changed) mini=\(self.window?.isMiniaturized ?? false) key=\(self.window?.isKeyWindow ?? false)")
        guard !manager.shuttingDown, !closingFromRemote else { return }
        guard changed else { return }
        self.isPaused = paused
        if paused { session.pauseWindow(stream: stream) } else { session.resumeWindow(stream: stream) }
    }

    /// Re-decides pause (a menu stopped tracking, or the app came back): the
    /// caller has no new state of its own.
    func reevaluatePause() {
        setPaused(shouldPause)
    }

    // MARK: Focus

    func windowDidBecomeKey(_ notification: Notification) {
        let state = StreamMenuState.shared
        state.hasStream = true
        state.showTouches = manager.showTouches
        state.style = style
        state.fullScreen = window?.styleMask.contains(.fullScreen) ?? false
        state.fullScreenAllowed = FullScreenMenu.allowsFullScreen(window)
        state.densityPackage = densityPackage
        state.densityOverride = densityOverride
        state.settingsDensity = manager.defaultDensity
        state.liveText = liveText.isActive
        state.frozen = frozen
        state.phoneOffline = phoneControlsOffline
        state.phoneWindow = self is PhoneWindowController
        state.panelOff = (self as? PhoneWindowController)?.panelOffShown ?? false
        state.revealDelay = manager.revealDelay
        // The View menu's pair is enabled from here on. It is corrected when
        // the menu opens too, but a disabled menu item eats its key equivalent:
        // ⌥⌘F is on the pair and must work without the menu being opened.
        MenuMarks.apply(to: NSApp.mainMenu)
    }

    func windowDidResignKey(_ notification: Notification) {
        // The keyboard left the window: the bar's ring goes with it, and its
        // keys are the phone's again when the window comes back.
        resetBarFocus()
        let state = StreamMenuState.shared
        state.hasStream = false
        state.fullScreen = false
        // The window that takes over is the Deck or another stream window, and
        // both may go full screen; a phone window publishes its own refusal
        // when it becomes key.
        state.fullScreenAllowed = true
        state.densityPackage = nil
        state.densityOverride = nil
        state.liveText = false
        state.frozen = false
        state.phoneWindow = false
        state.panelOff = false
        videoView.windowResignedKey()
        // The pair acts on the key stream window: disabled again once none is.
        MenuMarks.apply(to: NSApp.mainMenu)
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
        if window?.isKeyWindow ?? false {
            StreamMenuState.shared.frozen = frozen
            StreamMenuState.shared.phoneOffline = phoneControlsOffline
        }
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
        // The state reports the picture as the window is now: the view must
        // have taken the new size before the gap is measured (a did-resize
        // notification can arrive before AppKit's layout pass).
        videoView.layoutSubtreeIfNeeded()
        let lights = window?.standardWindowButton(.closeButton).map { !$0.isHidden } ?? false
        let pillUp = chrome.showsPill
        let titleUp = window?.titleVisibility == .visible
        let managed = chrome.lightsManagedByAppKit ? "appkit" : "us"
        let fullScreen = window?.styleMask.contains(.fullScreen) ?? false
        // The disconnection overlay is the visible part of a stall or a
        // dropped link: it must be in the view tree, with its icon and its
        // lines (the state's `stall=` is only the flag). The e2e asserts this,
        // so a window that stops the picture without telling the person fails.
        let overlay = chrome.stallOverlay
        // The picture's drawn rect in window points, top-left origin: the band
        // check reads the screenshot inside it.
        let picture = videoView.convert(videoView.videoRect(), to: nil)
        let pictureTop = (window?.frame.height ?? 0) - picture.maxY
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
            + " panel_off=\(chrome.panelOff ? 1 : 0) panel_pill=\(chrome.showsPanelStatus ? 1 : 0)"
            + " panel_pill_failed=\(chrome.showsPanelStatus && chrome.panelPillText == PhoneScreenOverlay.panelFailedText ? 1 : 0)"
            + " panel_click_at=\((self as? PhoneWindowController)?.panelClickedAtMs ?? 0)"
            + " panel_glyph_at=\((self as? PhoneWindowController)?.panelGlyphAtMs ?? 0)"
            + " panel_requests=\((self as? PhoneWindowController)?.panelRequestCount ?? 0)"
            + " stall=\(isStalled ? 1 : 0) stall_overlay=\(overlay.isShowing ? 1 : 0)"
            + " stall_icon=\(overlay.hasIcon ? 1 : 0)"
            + " drop_pill=\(dropPill?.fadeTarget == 1 ? "shown" : "hidden")"
            + " loading=\(openingState)"
            + " cover_phase=\(openingCoverPhase)"
            + " cover_buttons=\(openingButtons)"
            + " bar_offline=\(phoneControlsOffline ? 1 : 0)"
            + " bar_enabled=\(chrome.enabledHeaderKinds.isEmpty ? "none" : chrome.enabledHeaderKinds.joined(separator: ","))"
            + " bar_focus=\(barFocusState)"
            + " key=\(window?.isKeyWindow == true ? 1 : 0)"
            + " responder_video=\(window?.firstResponder === videoView ? 1 : 0)"
            + " frame=\(Int((window?.frame.width ?? 0).rounded()))x\(Int((window?.frame.height ?? 0).rounded()))"
            + " video_gap=\(Int(videoView.videoGap().rounded()))"
            + " video=\(Int(picture.minX.rounded())),\(Int(pictureTop.rounded())),\(Int(picture.width.rounded())),\(Int(picture.height.rounded()))\n"
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
        tickFrameWatchdog(at: ProcessInfo.processInfo.systemUptime)
    }

    /// The tick with the clock passed in, so a test can drive the window's
    /// rule (expectation changes included) without waiting in real time.
    func tickFrameWatchdog(at now: TimeInterval) {
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
        tickPicture(at: now)
    }

    /// The link's clock: the same 0.25 s tick moves "Reconnecting…" and "Phone
    /// offline", so a test drives them without waiting (WIN-16).
    func tickPicture(at now: TimeInterval) {
        applyPicture(.tick(now), at: now)
    }

    /// The phone reported `power.locked` (its own power press with our streams
    /// up): the VD group re-lights and the picture can be quiet for a moment.
    /// Hold the last frame — no "Not responding" pill, no input block — for
    /// the watchdog's grace; a real stall after it still says so.
    func powerLocked() {
        powerLocked(at: ProcessInfo.processInfo.systemUptime)
    }

    /// The clock-explicit half, so a test drives the rule without waiting.
    func powerLocked(at now: TimeInterval) {
        setStalled(false)
        watchdog.powerLocked(at: now)
        writeChromeState()
    }

    /// The picture stopped (or came back): the machine's stall event. A stall
    /// is a frozen mode: input and the phone-side actions stop too.
    private func setStalled(_ stalled: Bool) {
        applyPicture(.stall(stalled), at: now())
    }

    /// One transition of the picture's machine: log the path, run its actions
    /// and let the frozen state and the chrome state follow.
    private func applyPicture(_ event: PictureState.Event, at time: TimeInterval) {
        let from = PictureState.label(picture.state)
        guard let actions = picture.handle(event, at: time) else { return }
        let state = "\(from) --\(event)--> \(PictureState.label(picture.state))"
        Log.video.notice("picture: \(state, privacy: .public)")
        for action in actions { run(action) }
        // `updateFrozen` writes the chrome state, so the transition lands there
        // once.
        updateFrozen()
    }

    /// The overlay came or went (WIN-39).
    private func run(_ action: PictureState.Action) {
        switch action {
        case .present(let kind):
            let display = StallOverlayDisplay(kind: kind, phone: manager.phoneName)
            chrome.stallOverlay.show(display, icon: openingIcon)
            chrome.layoutChrome()
            Log.video.notice("stream \(self.stream, privacy: .public): stall=1")
        case .dismiss:
            chrome.stallOverlay.hide()
            chrome.layoutChrome()
            Log.video.notice("stream \(self.stream, privacy: .public): stall=0")
        }
    }

    // MARK: Link state

    /// The link dropped or came back: the overlay says so after 1 s (a blip
    /// shows nothing), and "Phone offline" 15 s after the drop.
    func setLinkDown(_ down: Bool) {
        setLinkDown(down, at: now())
    }

    /// The clock-explicit half, so a test drives the two steps without waiting.
    func setLinkDown(_ down: Bool, at time: TimeInterval) {
        phoneControlsOffline = down
        chrome.setOffline(down)
        if down {
            liveText.exit(.disconnect)
            applyPicture(.linkDown, at: time)
        } else {
            applyPicture(.linkUp, at: time)
        }
        writeChromeState()
    }

    // MARK: File-drop pill (docs/design/dragdrop.md)

    private var dropPill: GlassPillView?

    /// Over the last frame: "Sending report.pdf… 43 %", then the outcome.
    /// nil hides the pill (a finished transfer fades when the state times out).
    func setDropPill(_ state: (text: String, showsProgress: Bool)?) {
        guard let state else {
            dropPill?.fade(to: 0)
            writeChromeState()
            return
        }
        let pill = dropPill ?? GlassPillView(text: state.text, showsProgress: state.showsProgress)
        if dropPill == nil {
            dropPill = pill
            videoView.addSubview(pill)
            pill.alphaValue = 0
        }
        pill.setText(state.text, showsProgress: state.showsProgress)
        layoutDropPill()
        pill.fade(to: 1)
        writeChromeState()
    }

    private func layoutDropPill() {
        guard let dropPill else { return }
        let size = dropPill.fittingSize
        dropPill.frame = NSRect(x: (videoView.bounds.width - size.width) / 2,
                                y: videoView.bounds.height - size.height - 24,
                                width: size.width, height: size.height)
        dropPill.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
    }

    // MARK: Density

    /// ⌘+/⌘-: one step on the focused window's app override, created from the
    /// value it shows now when the app had none (View ▸ Density does the same
    /// for an exact option).
    func adjustDensity(_ delta: Double) {
        guard usesDensity, let pkg = densityPackage else { return }
        let next = DensityRules.stepped(from: density, by: delta)
        guard next != density else {
            // At the clamp the press cannot change anything, and a request
            // equal to the last one re-attached the phone's encoder for nothing
            // (the 10-27 burst). The press is a no-op: nothing is sent.
            Log.video.info("density press: the window is at the clamp, nothing to send")
            return
        }
        manager.setDensity(next, forPackage: pkg)
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
        guard HeaderActionPolicy.allowsPhoneShortcut(frozen: frozen,
                                                     offline: phoneControlsOffline) else { return }
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
