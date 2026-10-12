// Phone-mode window: shows the phone's own launcher (PocketDeck launcher
// activity) in a phone-shaped, aspect-locked window with hover chrome.

import AppKit

final class PhoneWindowController: StreamWindowController {
    let phoneScreen: CGSize
    let phoneDpi: Double
    private let chrome = NSView()
    private var chromeVisible = false

    static let fallbackScreen = CGSize(width: 1080, height: 2340)
    static let fallbackDpi: Double = 420

    init(stream: UInt32, phone: PhoneInfo?, manager: WindowManager) {
        let screen = phone?.screenSize ?? Self.fallbackScreen
        self.phoneScreen = screen.width > 0 && screen.height > 0 ? screen : Self.fallbackScreen
        self.phoneDpi = Double(phone?.screenDpi ?? Int(Self.fallbackDpi))
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 900
        let height = (visibleHeight * 0.75).rounded()
        let width = (height * self.phoneScreen.width / self.phoneScreen.height).rounded()
        super.init(stream: stream, contentSize: NSSize(width: width, height: height), manager: manager)
        window?.title = phone?.name ?? "Phone"
        window?.contentAspectRatio = NSSize(width: self.phoneScreen.width, height: self.phoneScreen.height)
        window?.minSize = NSSize(width: 240, height: 240 * self.phoneScreen.height / self.phoneScreen.width)
        videoView.hoverZoneHeight = 90
        videoView.onHoverChange = { [weak self] visible in self?.showChrome(visible) }
        videoView.inputMapper?.isPhoneMode = true
        buildChrome()
        showChrome(false, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

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

    // MARK: Chrome

    private func buildChrome() {
        chrome.wantsLayer = true
        chrome.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.78).cgColor
        chrome.layer?.cornerRadius = 12
        let buttons = [
            makeButton(symbol: "chevron.backward", tip: "Back", action: #selector(navBack)),
            makeButton(symbol: "circle", tip: "Home", action: #selector(navHome)),
            makeButton(symbol: "square.on.square", tip: "Recents", action: #selector(navRecents)),
        ]
        for button in buttons { chrome.addSubview(button) }
        videoView.addSubview(chrome, positioned: .above, relativeTo: nil)
        chrome.frame = NSRect(x: videoView.bounds.midX - 110, y: videoView.bounds.height - 54,
                              width: 220, height: 44)
        let width: CGFloat = 60
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: 10 + CGFloat(index) * (width + 5), y: 6, width: width, height: 32)
        }
        chrome.autoresizingMask = [.minYMargin]
    }

    private func makeButton(symbol: String, tip: String, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.toolTip = tip
        return button
    }

    private func showChrome(_ visible: Bool, animated: Bool = true) {
        guard chromeVisible != visible || !animated else { return }
        chromeVisible = visible
        guard animated else {
            chrome.alphaValue = visible ? 1 : 0
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            chrome.animator().alphaValue = visible ? 1 : 0
        }
    }

    @objc private func navBack() { session.nav(stream: stream, action: "back") }
    @objc private func navHome() { session.nav(stream: stream, action: "home") }
    @objc private func navRecents() { session.nav(stream: stream, action: "recents") }
}
