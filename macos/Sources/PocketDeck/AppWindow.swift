// One app stream = one freely resizable Mac window (many can be open at once).

import AppKit

final class AppWindowController: StreamWindowController {
    let pkg: String
    let activity: String?

    /// The stream is 900 × 600; the window adds the hover padding around it.
    static let defaultContentSize = NSSize(width: 900, height: 600)

    init(stream: UInt32, pkg: String, activity: String?, label: String, manager: WindowManager) {
        self.pkg = pkg
        self.activity = activity
        super.init(stream: stream, contentSize: Self.defaultContentSize, manager: manager)
        window?.title = label
        window?.minSize = WindowChrome.windowSize(stream: NSSize(width: 320, height: 240))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func sendOpen() {
        let pixels = displayPixels()
        session.openApp(stream: stream, pkg: pkg, activity: activity,
                        width: Int(pixels.width), height: Int(pixels.height), dpi: dpi())
    }

    override var frameKey: String { "app.\(pkg)" }

    func setTitle(_ label: String) {
        window?.title = label
    }
}

/// A window opened for a link: the phone picks the app (`link.open`), and the
/// title follows whichever app ends up on top of its display.
final class LinkWindowController: StreamWindowController {
    let url: String

    /// The package the phone displays for the link, once its `window.title`
    /// names it: the window's Dock identity stands for that app
    /// (docs/design/dock.md §Lifecycle).
    private(set) var pkg: String?

    init(stream: UInt32, url: String, manager: WindowManager) {
        self.url = url
        super.init(stream: stream, contentSize: AppWindowController.defaultContentSize, manager: manager)
        window?.title = Self.title(for: url)
        window?.minSize = WindowChrome.windowSize(stream: NSSize(width: 320, height: 240))
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

    func setTitle(_ label: String) {
        window?.title = label
    }

    /// The phone reported the app that displays the link.
    func adopt(pkg: String) {
        guard self.pkg == nil, !pkg.isEmpty else { return }
        self.pkg = pkg
    }
}
