// One app stream = one freely resizable Mac window (many can be open at once).

import AppKit

final class AppWindowController: StreamWindowController {
    let pkg: String
    let activity: String?

    static let defaultContentSize = NSSize(width: 900, height: 600)

    init(stream: UInt32, pkg: String, activity: String?, label: String, manager: WindowManager) {
        self.pkg = pkg
        self.activity = activity
        super.init(stream: stream, contentSize: Self.defaultContentSize, manager: manager)
        window?.title = label
        window?.minSize = NSSize(width: 320, height: 240)
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
