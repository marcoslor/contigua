// One app stream = one freely resizable Mac window (many can be open at once).

import AppKit

final class AppWindowController: StreamWindowController {
    let pkg: String
    let activity: String?
    /// The app label the window title names (WindowManager appends the phone).
    private(set) var subject: String

    /// The stream is 900 × 600; the window adds the bar above it.
    static let defaultContentSize = NSSize(width: 900, height: 600)

    /// This window's style is remembered for the app it shows.
    override var styleKey: String? { WindowStyleStore.key(forPackage: pkg) }

    /// So is its density override.
    override var densityPackage: String? { pkg }

    /// The cover before the first frame: the app's cached icon and its label.
    override var showsOpeningCover: Bool { true }
    override var openingName: String { subject }
    override var openingIcon: NSImage? { manager.icons[pkg] }

    init(stream: UInt32, pkg: String, activity: String?, label: String, manager: WindowManager) {
        self.pkg = pkg
        self.activity = activity
        subject = label
        super.init(stream: stream, contentSize: Self.defaultContentSize, manager: manager,
                   styleKey: WindowStyleStore.key(forPackage: pkg))
        window?.title = manager.titled(label)
        window?.minSize = style.windowSize(stream: NSSize(width: 320, height: 240))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func sendOpen() {
        let pixels = displayPixels()
        session.openApp(stream: stream, pkg: pkg, activity: activity,
                        width: Int(pixels.width), height: Int(pixels.height), dpi: dpi())
    }

    override var frameKey: String { "app.\(pkg)" }

    /// A new subject (the app label, or what the phone reports as the title).
    func setSubject(_ label: String) {
        subject = label
        window?.title = manager.titled(label)
    }

    override func retitle() {
        window?.title = manager.titled(subject)
    }
}
