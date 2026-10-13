// Phone-mode window: shows the phone's own launcher (PocketDeck launcher
// activity) in a phone-shaped, aspect-locked window with hover chrome.

import AppKit

final class PhoneWindowController: StreamWindowController {
    let phoneScreen: CGSize
    let phoneDpi: Double
    private var chrome: PhoneBarView?
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
        window?.aspectRatio = NSSize(width: self.phoneScreen.width, height: self.phoneScreen.height)
        window?.minSize = NSSize(width: 240, height: 240 * self.phoneScreen.height / self.phoneScreen.width)
        videoView.hoverZoneHeight = 84
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

    override var frameKey: String { "phone" }

    // MARK: Chrome

    private func buildChrome() {
        let bar = PhoneBarView(back: { [weak self] in self?.navBack() },
                               home: { [weak self] in self?.navHome() },
                               recents: { [weak self] in self?.navRecents() })
        videoView.addSubview(bar, positioned: .above, relativeTo: nil)
        // 8 pt under the titlebar, centred; follows the top edge on resize.
        bar.frame = NSRect(x: (videoView.bounds.width - PhoneBarView.size.width) / 2,
                           y: videoView.bounds.height - 28 - 8 - PhoneBarView.size.height,
                           width: PhoneBarView.size.width, height: PhoneBarView.size.height)
        bar.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        chrome = bar
    }

    private var hideChromeWork: DispatchWorkItem?

    private func showChrome(_ visible: Bool, animated: Bool = true) {
        hideChromeWork?.cancel()
        guard chromeVisible != visible || !animated else { return }
        if visible || !animated {
            apply(visible, animated: animated)
        } else {
            // Fades out 1 s after the pointer leaves the top strip.
            let work = DispatchWorkItem { [weak self] in self?.apply(false, animated: true) }
            hideChromeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        }
    }

    private func apply(_ visible: Bool, animated: Bool) {
        chromeVisible = visible
        guard animated else {
            chrome?.alphaValue = visible ? 1 : 0
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.2 : 0.3
            chrome?.animator().alphaValue = visible ? 1 : 0
        }
    }

    private func navBack() { session.nav(stream: stream, action: "back") }
    private func navHome() { session.nav(stream: stream, action: "home") }
    private func navRecents() { session.nav(stream: stream, action: "recents") }
}
