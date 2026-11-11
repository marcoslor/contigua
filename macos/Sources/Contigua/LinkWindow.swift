// A link stream: the phone picks the app (`link.open`) and the window follows.

import AppKit

/// A window opened for a link: the phone picks the app (`link.open`), and the
/// title follows whichever app ends up on top of its display.
final class LinkWindowController: StreamWindowController {
    let url: String
    /// What the title names: the host, later the app the phone reported.
    private(set) var subject: String

    /// The package the phone displays for the link, once its `window.title`
    /// names it: the window's Dock identity stands for that app
    /// (docs/design/dock.md §Lifecycle). Even the style follows then.
    private(set) var pkg: String?

    /// The link wears the style the package remembers, once it is known.
    override var styleKey: String? { pkg.map { WindowStyleStore.key(forPackage: $0) } }

    /// The bar names the app once the phone has reported its package; before
    /// that it shows nothing — never the host or the URL (WIN-68).
    override var barTitle: String? {
        BarTitleName.adoptedApp(pkg.flatMap { manager.appsByPkg[$0]?.label })
    }

    /// And its density override, under the same package key.
    override var densityPackage: String? { pkg }

    init(stream: UInt32, url: String, manager: WindowManager) {
        self.url = url
        subject = Self.title(for: url)
        super.init(stream: stream, contentSize: AppWindowController.defaultContentSize, manager: manager, styleKey: nil)
        window?.title = manager.titled(subject)
        window?.minSize = style.windowSize(stream: NSSize(width: 320, height: 240))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The host for web links ("example.com"), the whole link otherwise ("tel:+351…").
    static func title(for url: String) -> String {
        URLComponents(string: url)?.host.flatMap { $0.isEmpty ? nil : $0 } ?? url
    }

    override func sendOpen() {
        let pixels = displayPixels()
        session.openLink(stream: stream, url: url,
                         width: Int(pixels.width), height: Int(pixels.height), dpi: dpi())
    }

    override var frameKey: String { "link" }

    /// A new subject (the host, or the app title the phone reports).
    func setSubject(_ label: String) {
        subject = label
        window?.title = manager.titled(label)
    }

    /// The phone reported the app that displays the link.
    func adopt(pkg: String) {
        guard self.pkg == nil, !pkg.isEmpty else { return }
        self.pkg = pkg
        reapplyStoredStyle()
        reapplyStoredDensity()
        refreshBarTitle()
    }

    override func retitle() {
        window?.title = manager.titled(subject)
        refreshBarTitle()
    }
}
