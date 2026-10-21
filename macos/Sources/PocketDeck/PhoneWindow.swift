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
        window?.minSize = style.windowSize(stream: NSSize(
            width: Self.minVideoWidth, height: Self.minVideoWidth * phoneScreen.height / phoneScreen.width))
        videoView.inputMapper?.isPhoneMode = true
        // The mirror's letterbox is the phone's fixed screen, never a crop.
        videoView.isPhoneMode = true
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
            MainActor.assumeIsolated { self?.followRotation() }
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
        window.minSize = style.windowSize(stream: turned.width < turned.height
            ? CGSize(width: Self.minVideoWidth, height: Self.minVideoWidth * turned.height / turned.width)
            : CGSize(width: Self.minVideoWidth * turned.width / turned.height, height: Self.minVideoWidth))
        window.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height),
                        display: true, animate: false)
    }

    /// The display name, or the remembered phone name while unknown.
    private static func title(name: String, phone: PhoneInfo?) -> String {
        if !name.isEmpty { return name }
        return phone?.name.isEmpty == false ? phone!.name : "Phone"
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

    private static let minVideoWidth: CGFloat = 240

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

    /// "Turn Off Phone Screen": the phone holds its own panel's power off while
    /// this mirror keeps rendering. Remembered per phone, because it is a
    /// choice about that phone.
    func setPanelOff(_ off: Bool) {
        guard panelOffShown != off else { return }
        if let id = manager.phone?.id { PhonePanelOffSetting.write(off, for: id, to: manager.profileDefaults) }
        session.setPhonePanel(off: off)
    }

    func togglePanelOff() { setPanelOff(!panelOffShown) }

    /// Navigate ▸ Turn Off Phone Screen: the menu item's action, through the
    /// responder chain (a nil target), so the e2e drives the same route.
    @objc func togglePanelOffMenuAction(_ sender: Any?) { togglePanelOff() }

    /// `state.panel` from the session: the check, the bar glyph and the pill.
    func setPhonePanel(_ panel: PhonePanel?) {
        let changed = screenModel.setPanel(panel, at: ProcessInfo.processInfo.systemUptime)
        guard changed else { return }
        applyPanelState()
    }

    private func applyPanelState() {
        chrome.setPanelOff(screenModel.panelOff)
        chrome.setPanelPill(screenModel.panelPill)
        chrome.setActions(headerActions())
        if window?.isKeyWindow ?? false {
            StreamMenuState.shared.panelOff = screenModel.panelOff
        }
        writeChromeState()
    }

    override func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        PhoneChrome.frame(proposed: frameSize, phone: phoneScreen, style: style)
    }

    override func windowDidEndLiveResize(_ notification: Notification) {
        super.windowDidEndLiveResize(notification)
        // A rotation the phone reported during the drag applies now.
        followRotation()
    }

    /// The green button (and a double-click on the bar) zooms to the phone's
    /// aspect fit inside the screen, never to the whole display: this window
    /// has no full screen.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        guard let screen = window.screen ?? NSScreen.main else { return newFrame }
        return PhoneChrome.zoomFrame(phone: phoneScreen, style: style, visible: screen.visibleFrame)
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
        guard HeaderActionPolicy.allowsPhoneShortcut(frozen: frozen) else { return }
        session.nav(stream: stream, action: "home")
    }

    @objc func navigateRecents(_ sender: Any?) {
        guard HeaderActionPolicy.allowsPhoneShortcut(frozen: frozen) else { return }
        session.nav(stream: stream, action: "recents")
    }

    override func sendOpen() {
        let pixels = displayPixels()
        session.openPhone(stream: stream, width: Int(pixels.width), height: Int(pixels.height), dpi: dpi())
        // Opening, re-opening or reconnecting wakes display 0; the keyguard
        // stays up and the phone's own screen timeout applies as usual.
        screenModel.opened()
        session.wakePhone()
        // "Turn Off Phone Screen" is remembered per phone: a window that opens
        // with it on asks the phone again (the phone ends it on the person's
        // power button, and then it stays off until they ask again).
        if let id = manager.phone?.id,
           PhonePanelOffSetting.read(from: manager.profileDefaults, deviceId: id) {
            session.setPhonePanel(off: true)
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
        chrome.phoneOverlay.show(cover)
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

    /// The panel pill's two seconds are up: take it down.
    private func tickPanelPill() {
        guard screenModel.tick(at: ProcessInfo.processInfo.systemUptime) else { return }
        chrome.setPanelPill(nil)
        writeChromeState()
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
            return
        }
        window?.title = Self.title(name: manager.phoneName, phone: manager.phone)
    }

    override var frameKey: String { "phone" }

    private func nav(_ action: String) { session.nav(stream: stream, action: action) }
}
