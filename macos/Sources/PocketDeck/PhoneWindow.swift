// Phone-mode window: shows the phone's own launcher (PocketDeck launcher
// activity) in a phone-shaped window whose video keeps the phone's aspect
// ratio, with hover chrome.

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
        let videoHeight = (visibleHeight * 0.75).rounded()
        let width = (videoHeight * self.phoneScreen.width / self.phoneScreen.height).rounded()
        let reserved = TitleStrip.reservedHeight(titlebar: TitleStrip.fallbackHeight,
                                                 enabled: manager.titleStrip(forKey: "phone"))
        super.init(stream: stream, contentSize: NSSize(width: width, height: videoHeight + reserved), manager: manager)
        window?.title = phone?.name ?? "Phone"
        updateMinSize()
        videoView.onHoverChange = { [weak self] visible in self?.showChrome(visible) }
        videoView.inputMapper?.isPhoneMode = true
        buildChrome()
        layoutChrome()
        showChrome(false, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static let minVideoWidth: CGFloat = 240

    /// The strip is not part of the picture: the window is as much taller than
    /// the video as the strip, and the video keeps the phone's aspect ratio.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        TitleStrip.phoneFrame(proposed: frameSize, current: sender.frame.size, phone: phoneScreen,
                              reserved: reservedHeight)
    }

    private var reservedHeight: CGFloat {
        TitleStrip.reservedHeight(titlebar: titlebarHeight, enabled: strip.titleStrip)
    }

    private func updateMinSize() {
        window?.minSize = NSSize(width: Self.minVideoWidth,
                                 height: Self.minVideoWidth * phoneScreen.height / phoneScreen.width + reservedHeight)
    }

    /// Toggling the strip keeps the video the size it was: the window grows or
    /// shrinks by the strip, from its top edge.
    override func titleStripDidChange() {
        guard let window else { return }
        let delta = TitleStrip.reservedHeight(titlebar: titlebarHeight, enabled: true)
        var frame = window.frame
        let change = strip.titleStrip ? delta : -delta
        frame.size.height += change
        frame.origin.y -= change
        window.setFrame(frame, display: true)
        updateMinSize()
        layoutChrome()
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

    // MARK: Chrome

    private func buildChrome() {
        let bar = PhoneBarView(back: { [weak self] in self?.navBack() },
                               home: { [weak self] in self?.navHome() },
                               recents: { [weak self] in self?.navRecents() })
        videoView.addSubview(bar, positioned: .above, relativeTo: nil)
        bar.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        chrome = bar
    }

    /// 8 pt under the titlebar, centred; follows the top edge on resize. With
    /// the strip on, the video starts under the titlebar already.
    private func layoutChrome() {
        let video = videoBounds()
        let covered = strip.titleStrip ? 0 : titlebarHeight
        chrome?.frame = NSRect(x: (video.width - PhoneBarView.size.width) / 2,
                               y: video.height - covered - 8 - PhoneBarView.size.height,
                               width: PhoneBarView.size.width, height: PhoneBarView.size.height)
        // The top 84 pt of the window, as the titlebar counts for it.
        videoView.hoverZoneHeight = 84 - (strip.titleStrip ? titlebarHeight : 0)
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
