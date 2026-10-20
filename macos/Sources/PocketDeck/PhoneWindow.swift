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
        chrome.phoneOverlay.onWake = { [weak self] in self?.wakeFromOverlay() }
        // While the panel sleeps the frame is frozen: no click, key, scroll or
        // hover reaches the phone through any path.
        videoView.inputMapper?.inputSuspended = { [weak self] in self?.screenModel.isShowing ?? false }
        rotationObserver = NotificationCenter.default.addObserver(
            forName: VideoLayerView.videoSizeDidChange, object: videoView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.followRotation() }
        }
    }

    deinit {
        if let rotationObserver { NotificationCenter.default.removeObserver(rotationObserver) }
    }

    private var rotationObserver: NSObjectProtocol?

    /// The phone turned: the stream now has the other orientation, so the window
    /// turns too, keeping its top-left corner and its picture's area.
    private func followRotation() {
        let video = videoView.videoSize
        guard let window, let turned = PhoneChrome.turnedPhone(phone: phoneScreen, video: video) else { return }
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

    private static let minVideoWidth: CGFloat = 240

    override func headerActions() -> [HeaderAction] {
        [HeaderAction(symbol: "chevron.backward", help: "Back") { [weak self] in self?.nav("back") },
         HeaderAction(symbol: "circle", help: "Home") { [weak self] in self?.nav("home") },
         HeaderAction(symbol: "square.on.square", help: "Recents") { [weak self] in self?.nav("recents") }]
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        PhoneChrome.frame(proposed: frameSize, current: sender.frame.size, phone: phoneScreen, style: style)
    }
    /// dpi = phoneDpi × vdWidth / phoneScreenWidth, so the phone's dp width is
    /// preserved whatever the Mac window size is.
    override func dpi() -> Double {
        let pixels = displayPixels()
        guard phoneScreen.width > 0, pixels.width > 0 else { return phoneDpi }
        return phoneDpi * pixels.width / phoneScreen.width
    }

    /// ⇧⌘H / ⌘↑ only make sense here (home/recents are phone-mode actions).
    @objc func navigateHome(_ sender: Any?) {
        session.nav(stream: stream, action: "home")
    }

    @objc func navigateRecents(_ sender: Any?) {
        session.nav(stream: stream, action: "recents")
    }

    override func sendOpen() {
        let pixels = displayPixels()
        session.openPhone(stream: stream, width: Int(pixels.width), height: Int(pixels.height), dpi: dpi())
        // Opening, re-opening or reconnecting wakes display 0; the keyguard
        // stays up and the phone's own screen timeout applies as usual.
        screenModel.opened()
        session.wakePhone()
    }

    /// `state.screen` from the session: off puts the blurred cover and its Wake
    /// Screen button over the held frame, on takes it away.
    func setPhoneScreen(_ screen: PhoneScreen?) {
        guard screenModel.set(screen: screen) else { return }
        let off = screenModel.isShowing
        if off { videoView.inputMapper?.dropPendingInput() }
        chrome.phoneOverlay.isHidden = !off
        chrome.needsLayout = true
        writeChromeState()
        Log.video.notice("phone window: screen=\(off ? "off" : "on", privacy: .public) overlay=\(off ? 1 : 0, privacy: .public)")
    }

    /// A click on the blurred frame (or its Wake Screen button).
    private func wakeFromOverlay() {
        guard screenModel.click() else { return }
        session.wakePhone()
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
