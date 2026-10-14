// Phone-mode window: shows the phone's own launcher (PocketDeck launcher
// activity) in a phone-shaped window whose video keeps the phone's aspect
// ratio. Back / Home / Recents sit at the right of the hover header.

import AppKit

final class PhoneWindowController: StreamWindowController {
    let phoneScreen: CGSize
    let phoneDpi: Double

    static let fallbackScreen = CGSize(width: 1080, height: 2340)
    static let fallbackDpi: Double = 420

    init(stream: UInt32, phone: PhoneInfo?, manager: WindowManager) {
        let screen = phone?.screenSize ?? Self.fallbackScreen
        self.phoneScreen = screen.width > 0 && screen.height > 0 ? screen : Self.fallbackScreen
        self.phoneDpi = Double(phone?.screenDpi ?? Int(Self.fallbackDpi))
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 900
        let videoHeight = (visibleHeight * 0.75).rounded()
        let width = (videoHeight * self.phoneScreen.width / self.phoneScreen.height).rounded()
        super.init(stream: stream, contentSize: NSSize(width: width, height: videoHeight), manager: manager)
        window?.title = phone?.name ?? "Phone"
        window?.minSize = WindowChrome.windowSize(stream: NSSize(
            width: Self.minVideoWidth, height: Self.minVideoWidth * phoneScreen.height / phoneScreen.width))
        videoView.inputMapper?.isPhoneMode = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static let minVideoWidth: CGFloat = 240

    override func headerActions() -> [HeaderAction] {
        [HeaderAction(symbol: "chevron.backward", help: "Back") { [weak self] in self?.nav("back") },
         HeaderAction(symbol: "circle", help: "Home") { [weak self] in self?.nav("home") },
         HeaderAction(symbol: "square.on.square", help: "Recents") { [weak self] in self?.nav("recents") }]
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        WindowChrome.phoneFrame(proposed: frameSize, current: sender.frame.size, phone: phoneScreen)
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
    }

    func setTitle(_ label: String) {
        guard !label.isEmpty else { return }
        window?.title = label
    }

    override var frameKey: String { "phone" }

    private func nav(_ action: String) { session.nav(stream: stream, action: action) }
}
