// Phone-mode window: a 1:1 mirror of the phone's own screen in a window whose
// video keeps the phone's aspect ratio and turns when the phone rotates.
// Back / Home / Recents are small icons at the bar's right end (framed) or in
// the dwell pill (immersive).

import AppKit

final class PhoneWindowController: StreamWindowController {
    /// The phone's screen as it is turned now; the window's aspect follows it.
    private(set) var phoneScreen: CGSize
    let phoneDpi: Double
    /// What the phone last reported as this window's title (nil until it does):
    /// before that the window names the phone itself.
    private(set) var subject: String?

    /// `state.screen` and the overlay it drives (PhoneScreenOverlay.swift).
    private(set) var screenModel = PhoneScreenOverlay()

    static let fallbackScreen = CGSize(width: 1080, height: 2340)
    static let fallbackDpi: Double = 420

    init(stream: UInt32, phone: PhoneInfo?, manager: WindowManager) {
        let screen = phone?.screenSize ?? Self.fallbackScreen
        self.phoneScreen = screen.width > 0 && screen.height > 0 ? screen : Self.fallbackScreen
        self.phoneDpi = Double(phone?.screenDpi ?? Int(Self.fallbackDpi))
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 900
        let videoHeight = (visibleHeight * 0.75).rounded()
        let width = (videoHeight * self.phoneScreen.width / self.phoneScreen.height).rounded()
        super.init(stream: stream, contentSize: NSSize(width: width, height: videoHeight), manager: manager,
                   styleKey: WindowStyleStore.phoneKey)
        // The phone window names the phone itself: its display name (the
        // nickname, else the phone's own name), and what the phone reports
        // once it sends `window.title` for this stream.
        window?.title = Self.title(name: manager.phoneName, phone: phone)
        let minWidth = minWindowWidth
        window?.minSize = style.windowSize(stream: NSSize(
            width: minWidth, height: minWidth * phoneScreen.height / phoneScreen.width))
        videoView.inputMapper?.isPhoneMode = true
        // The mirror's letterbox is the phone's fixed screen, never a crop.
        videoView.isPhoneMode = true
        // And its box keeps the fixed 16 px / 2560 rule: the phone picks the
        // frame from the screen's aspect inside it (MIRROR), so the app
        // window's exact-pixel rule does not apply to the box (ISS-39).
        videoView.encoder = nil
        // No full screen for the phone window: a phone mirror filling a whole
        // display is letterboxed or stretched, and the person's report is that
        // it looks bad. Without .fullScreenPrimary (and with .fullScreenNone)
        // AppKit neither offers the mode nor the Window menu's item; the green
        // button zooms to the phone's aspect fit instead
        // (windowWillUseStandardFrame).
        window?.collectionBehavior = [.fullScreenNone]
        chrome.phoneOverlay.onWake = { [weak self] in self?.wakeFromOverlay() }
        rotationObserver = NotificationCenter.default.addObserver(
            forName: VideoLayerView.videoSizeDidChange, object: videoView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.followRotation()
                self?.refitToPicture()
            }
        }
        // The black-frame fallback for phones that do not report `state.secure`
        // yet: a look at the displayed frame five times a second.
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sampleFrameForBlackCover()
                self?.tickPanelPill()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        blackTimer = timer
    }

    deinit {
        blackTimer?.invalidate()
        if let rotationObserver { NotificationCenter.default.removeObserver(rotationObserver) }
    }

    /// A cover over the mirror (sleeping panel or secure surface) freezes it
    /// exactly as Live Text does: the shortcuts, the bar's buttons, the
    /// Navigate menu and every input path. Only the cover's Wake Screen button
    /// stays allowed.
    override var frozen: Bool { super.frozen || screenModel.isShowing }

    /// No frames are expected while the cover is up: the panel sleeps or
    /// Android blanks a secure surface. The watchdog's clock starts again when
    /// the cover comes off.
    override var expectsFrames: Bool {
        guard super.expectsFrames else { return false }
        return screenModel.cover == nil
    }

    private var rotationObserver: NSObjectProtocol?
    private var blackTimer: Timer?
    /// The edge a person is dragging (ISS-64), read once at the live resize's
    /// start and cleared at its end. `none` for a resize AppKit or a tiler did
    /// without a mouse: those keep the v104 larger-area rule.
    private(set) var dragEdge = PhoneWindowEdge.none

    /// The Mac's memory of the panel edge for this phone (docs/specs/controls.md):
    /// the value the phone received last, so a reconnect or a reopened mirror
    /// does not put a screen the person woke back out.
    private lazy var panelIntent = ControlIntentRecorder(
        store: ControlIntentStore(defaults: manager.profileDefaults, control: .panel))

    private var panelDeviceId: String? {
        guard let id = manager.phone?.id, !id.isEmpty else { return nil }
        return id
    }

    /// One phone.panel edge: the machine decides from this phone's memory, and
    /// only a value it has not had is sent. True when `phone.panel` went out.
    @discardableResult
    private func applyPanel(_ off: Bool, edge: ControlIntentEvent) -> Bool {
        guard let id = panelDeviceId else { return false }
        var sent = false
        for action in panelIntent.record(edge, deviceId: id) {
            guard case .send(let value) = action, let panel = PhonePanel(rawValue: value) else { continue }
            session.setPhonePanel(off: panel == .off, ignorePower: panelIgnorePower)
            panelRequestCount += 1
            sent = true
        }
        return sent
    }

    /// The phone turned: the stream now has the other orientation, so the window
    /// turns too, keeping its top-left corner and its picture's area. A drag in
    /// progress owns the frame; the turn waits for `windowDidEndLiveResize`.
    func followRotation() {
        let video = videoView.videoSize
        guard let window, !isLiveResizing,
              let turned = PhoneChrome.turnedPhone(phone: phoneScreen, video: video) else { return }
        phoneScreen = turned
        let current = style.streamSize(window: window.frame.size)
        let size = style.windowSize(stream: CGSize(width: current.height, height: current.width))
        let frame = window.frame
        let minWidth = minWindowWidth
        window.minSize = style.windowSize(stream: turned.width < turned.height
            ? CGSize(width: minWidth, height: minWidth * turned.height / turned.width)
            : CGSize(width: minWidth * turned.width / turned.height, height: minWidth))
        window.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height),
                        display: true, animate: false)
    }

    /// The first picture of a stream, or any picture whose shape no longer
    /// matches the window's video area: refit the window to the picture, keeping
    /// its top-left and height (ISS-63). A picture that arrives under the
    /// person's hand waits for `windowDidEndLiveResize`.
    func refitToPicture() {
        guard let window else { return }
        let video = style.streamSize(window: window.frame.size)
        let picture = videoView.videoSize
        switch PhoneChrome.PictureFit.decide(video: video, picture: picture, isDragging: isLiveResizing) {
        case .none:
            return
        case .refitAtDragEnd:
            return
        case .refitNow:
            window.setFrame(PhoneChrome.refitFrame(current: window.frame, picture: picture, style: style),
                            display: true, animate: false)
        }
    }

    /// The visible frame of the screen the remembered frame sat on: the mirror
    /// restores onto that screen, not always the main one (CONV-MAC-12).
    private func visibleFrame(containing frame: NSRect) -> NSRect {
        let screens = NSScreen.screens.map(\.visibleFrame)
        return screens.first { $0.intersects(frame) } ?? screens.first
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// A remembered frame is fitted to the phone's shape before the window
    /// opens: `clampedToScreen` sizes width and height apart, so it can leave a
    /// mirror too wide (ISS-63).
    override func openingFrame(_ frame: NSRect) -> NSRect {
        PhoneChrome.restoredFrame(saved: frame, phone: phoneScreen, style: style,
                                  visible: visibleFrame(containing: frame),
                                  minimum: window?.minSize ?? .zero)
    }

    /// The display name, or the remembered phone name while unknown.
    private static func title(name: String, phone: PhoneInfo?) -> String {
        if !name.isEmpty { return name }
        return phone?.name.isEmpty == false ? phone!.name : "Phone"
    }

    /// Host uptime in whole milliseconds: the clock the e2e's click -> glyph
    /// measurement uses (monotonic, unlike wall time).
    private static func uptimeMs() -> Int {
        Int((ProcessInfo.processInfo.systemUptime * 1000).rounded())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The phone window's style lives under its own key.
    override var styleKey: String? { WindowStyleStore.phoneKey }

    /// Its dpi keeps the phone's dp width, so the density setting never
    /// applies here and it gets no override of its own.
    override var usesDensity: Bool { false }

    /// The cover before the first frame: the phone, by name.
    override var showsOpeningCover: Bool { true }
    override var openingIsPhone: Bool { true }
    override var openingName: String { manager.phoneName.isEmpty ? "Your phone" : manager.phoneName }
    override var openingIcon: NSImage? {
        NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 46, weight: .regular))
    }

    /// The bar names the phone, never the mirrored app or a task (MIRROR-26).
    override var barTitle: String? {
        BarTitleName.phone(displayName: manager.phoneName, fallback: manager.phone?.name)
    }

    private static let minVideoWidth: CGFloat = 240

    /// The window's narrowest width: the video's own minimum, or the bar's
    /// (the lights, the gap, the action row and the Live Text button), so the
    /// phone's fourth bar control never sits over the traffic lights.
    private var minWindowWidth: CGFloat {
        max(Self.minVideoWidth, HeaderBar.minimumWidth(for: headerActions()))
    }

    override func headerActions() -> [HeaderAction] {
        [.back { [weak self] in self?.navigateBack(nil) },
         .home { [weak self] in self?.navigateHome(nil) },
         .recents { [weak self] in self?.navigateRecents(nil) },
         // "Turn Off Phone Screen" in the bar: the same control as the Navigate
         // menu item, and the subtle indicator while it is on (`iphone.slash`).
         HeaderAction(kind: .custom,
                      customSymbol: panelOffShown ? "iphone.slash" : "iphone",
                      help: panelOffShown ? "Phone Screen Off" : "Turn Off Phone Screen") { [weak self] in
             self?.togglePanelOff()
         }]
    }

    /// The check and the bar glyph follow the phone's `state.panel`, never a
    /// local guess: the phone is the one that holds the panel.
    var panelOffShown: Bool { screenModel.panelOff }

    /// e2e timing of the last "Turn Off Phone Screen" request (host uptime ms):
    /// the click that asked, and the `state.panel` that redrew the glyph. The
    /// chrome state reports both so the mirror check measures click -> glyph.
    private(set) var panelClickedAtMs = 0
    private(set) var panelGlyphAtMs = 0
    /// How many `phone.panel` requests this window has sent: the e2e's proof
    /// that a click on a disabled tile sends nothing.
    private(set) var panelRequestCount = 0

    /// "Turn Off Phone Screen": the phone holds its own panel's power off while
    /// this mirror keeps rendering. Remembered per phone, because it is a
    /// choice about that phone: the click is the Mac-side edge that applies it.
    func setPanelOff(_ off: Bool) {
        guard panelOffShown != off else { return }
        panelClickedAtMs = Self.uptimeMs()
        if let id = manager.phone?.id { PhonePanelOffSetting.write(off, for: id, to: manager.profileDefaults) }
        applyPanel(off, edge: .personAction(off ? PhonePanel.off.rawValue : PhonePanel.on.rawValue))
        // The phone answers with a `state.panel`; if it does not within 2 s the
        // window says the request failed instead of pretending it worked.
        if off { screenModel.requestPanelOff(at: ProcessInfo.processInfo.systemUptime) }
        applyPanelState()
    }

    /// Settings ▸ Phones, per phone: a power press on the phone does not end
    /// the hold; the screen lights until the next keep-alive step re-applies it.
    private var panelIgnorePower: Bool {
        guard let id = manager.phone?.id else { return false }
        return PhonePanelIgnorePowerSetting.read(from: manager.profileDefaults, deviceId: id)
    }

    func togglePanelOff() {
        // A request into a dead session, or into a frozen cover, does nothing.
        guard !phoneControlsOffline, !frozen else { return }
        setPanelOff(!panelOffShown)
    }

    /// Phone ▸ Turn Off Phone Screen: the menu item's action, through the
    /// responder chain (a nil target), so the e2e drives the same route.
    @objc func togglePanelOffMenuAction(_ sender: Any?) { togglePanelOff() }

    /// `state.panel` from the session: the check, the bar glyph and the pill.
    /// The report also moves the panel machine: a phone that reports `on` after
    /// we asked for `off` ended the hold itself, so its value stands.
    func setPhonePanel(_ panel: PhonePanel?) {
        if let panel, let id = panelDeviceId {
            panelIntent.record(.phoneReported(panel.rawValue), deviceId: id)
        }
        let changed = screenModel.setPanel(panel, at: ProcessInfo.processInfo.systemUptime)
        guard changed else { return }
        panelGlyphAtMs = Self.uptimeMs()
        applyPanelState()
    }

    /// The phone answered `phone.panel` with an error: it never turned the
    /// screen off, so the button stays unchecked and a short pill says why.
    func panelRequestFailed() {
        guard screenModel.panelRequestFailed(at: ProcessInfo.processInfo.systemUptime) else { return }
        applyPanelState()
    }

    private func applyPanelState() {
        chrome.setPanelOff(screenModel.panelOff)
        chrome.setPanelPill(screenModel.panelPill)
        chrome.setActions(headerActions())
        if window?.isKeyWindow ?? false {
            refreshMenuState()
        }
        writeChromeState()
    }

    override func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // The dragged edge leads the phone's aspect rule (ISS-64), then the
        // screen: a person's drag, an Accessibility resize or a tiler can only
        // make it as large as the screen allows (CONV-MAC-12).
        WindowFrameLimit.aspectFitted(
            PhoneChrome.frame(proposed: frameSize, phone: phoneScreen, style: style, edge: dragEdge),
            for: sender)
    }

    override func windowWillStartLiveResize(_ notification: Notification) {
        // Read the edge before the frame moves: a mouse drag names the side
        // under the pointer, a resize without a mouse event names none.
        dragEdge = currentDragEdge()
        super.windowWillStartLiveResize(notification)
    }

    override func windowDidEndLiveResize(_ notification: Notification) {
        dragEdge = .none
        super.windowDidEndLiveResize(notification)
        // A rotation the phone reported during the drag applies now, and a
        // picture that arrived under the hand refits now.
        followRotation()
        refitToPicture()
    }

    /// The edge under the pointer at this live resize's start, or `none` when
    /// the resize did not come from the mouse (Accessibility, a tiler, zoom).
    private func currentDragEdge() -> PhoneWindowEdge {
        guard let window, let event = NSApp.currentEvent,
              event.type == .leftMouseDown || event.type == .leftMouseDragged else { return .none }
        let point = window.convertPoint(toScreen: window.mouseLocationOutsideOfEventStream)
        return PhoneWindowEdge.at(point: point, in: window.frame)
    }

    /// The green button (and a double-click on the bar) zooms to the phone's
    /// aspect fit inside the screen, never to the whole display: this window
    /// has no full screen.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        guard let screen = window.screen ?? NSScreen.main else { return newFrame }
        return PhoneChrome.zoomFrame(phone: phoneScreen, style: style, visible: screen.visibleFrame)
    }
    /// The mirror's box is its own fixed rule, not the app window's
    /// exact-pixel one: the phone fits the screen's aspect inside it.
    override func displayPixels() -> CGSize {
        guard let window else { return .zero }
        return VideoSize.displayPixels(bounds: videoBounds(),
                                       backingScale: Double(window.backingScaleFactor))
    }

    /// dpi = phoneDpi × vdWidth / phoneScreenWidth, so the phone's dp width is
    /// preserved whatever the Mac window size is.
    override func dpi() -> Double {
        let pixels = displayPixels()
        guard phoneScreen.width > 0, pixels.width > 0 else { return phoneDpi }
        return phoneDpi * pixels.width / phoneScreen.width
    }

    /// ⇧⌘H / ⌘↑ only make sense here (home/recents are phone-mode actions).
    /// Live Text freezes them with the bar's buttons.
    @objc func navigateHome(_ sender: Any?) {
        guard HeaderActionPolicy.allowsPhoneShortcut(frozen: frozen,
                                                     offline: phoneControlsOffline) else { return }
        session.nav(stream: stream, action: "home")
    }

    @objc func navigateRecents(_ sender: Any?) {
        guard HeaderActionPolicy.allowsPhoneShortcut(frozen: frozen,
                                                     offline: phoneControlsOffline) else { return }
        session.nav(stream: stream, action: "recents")
    }

    override func sendOpen() {
        let pixels = displayPixels()
        session.openPhone(stream: stream, width: Int(pixels.width), height: Int(pixels.height), dpi: dpi())
        // Opening, re-opening or reconnecting wakes display 0; the keyguard
        // stays up and the phone's own screen timeout applies as usual.
        screenModel.opened()
        session.wakePhone()
        // "Turn Off Phone Screen" is remembered per phone, and a reopened window
        // is a connect edge: it applies the remembered value only when this
        // phone has not had it since the person ended the hold themselves
        // (docs/specs/controls.md). A hold the person's power press ended thus
        // stays ended across a reopen and a reconnect.
        if let id = manager.phone?.id,
           PhonePanelOffSetting.read(from: manager.profileDefaults, deviceId: id),
           applyPanel(true, edge: .connected(PhonePanel.off.rawValue)) {
            screenModel.requestPanelOff(at: ProcessInfo.processInfo.systemUptime)
            applyPanelState()
        }
    }

    /// `state.screen` from the session: off puts the blurred cover and its Wake
    /// Screen button over the held frame, on takes it away.
    func setPhoneScreen(_ screen: PhoneScreen?) {
        guard screenModel.set(screen: screen) else { return }
        applyCover()
    }

    /// `state.secure` from the session: the phone's PIN pad or another surface
    /// Android blanks gets the blurred cover and its sentence, with no button.
    func setPhoneSecure(_ secure: Bool) {
        guard screenModel.setSecure(secure) else { return }
        applyCover()
    }

    /// The cover follows the model: the sleeping panel offers Wake Screen, a
    /// secure surface only explains itself.
    private func applyCover() {
        let cover = screenModel.cover
        if cover != nil { videoView.inputMapper?.dropPendingInput() }
        // The sleeping picture is what the shared cover blurs; on the way down
        // the held picture is already gone, so no frame is passed.
        chrome.phoneOverlay.show(cover, heldFrame: cover == nil ? nil : videoView.copyDisplayedFrame())
        chrome.needsLayout = true
        updateFrozen()
        switch cover {
        case .screenOff:
            Log.video.notice("phone window: screen=off overlay=1")
        case .secure:
            Log.video.notice("phone window: secure=1 overlay=1")
        case nil:
            Log.video.notice("phone window: screen=on overlay=0")
        }
    }

    /// Samples the displayed frame for the black-frame fallback (phones that do
    /// not report `state.secure` yet). Only while the window shows live phone
    /// video; the pixel test is a grid, not a full scan.
    private func sampleFrameForBlackCover() {
        guard !screenModel.isShowing, screenModel.screen != .off,
              window?.isVisible == true, !videoView.isPaused else { return }
        guard let buffer = videoView.copyDisplayedFrame() else { return }
        if screenModel.frame(at: ProcessInfo.processInfo.systemUptime, black: BlackFrame.isBlack(buffer)) {
            applyCover()
        }
    }

    /// A click on the blurred frame (or its Wake Screen button).
    private func wakeFromOverlay() {
        guard screenModel.click() else { return }
        session.wakePhone()
    }

    /// The panel pill's state changed on the clock: the request failed after
    /// two silent seconds, or the pill is due to come down.
    private func tickPanelPill() {
        guard screenModel.tick(at: ProcessInfo.processInfo.systemUptime) else { return }
        applyPanelState()
    }

    /// The e2e's debug route (`wake-phone`): the same path as the button.
    func wakeScreen() {
        wakeFromOverlay()
    }

    func setSubject(_ label: String) {
        guard !label.isEmpty else { return }
        subject = label
        window?.title = manager.titled(label)
    }

    override func retitle() {
        if let subject {
            window?.title = manager.titled(subject)
            refreshBarTitle()
            return
        }
        window?.title = Self.title(name: manager.phoneName, phone: manager.phone)
        refreshBarTitle()
    }

    override var frameKey: String { "phone" }

    private func nav(_ action: String) { session.nav(stream: stream, action: action) }
}
