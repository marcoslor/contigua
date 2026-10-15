// The window "Continue on Mac" opens (docs/ROADMAP.md #9): the phone moved the
// app that was in the foreground on its own screen onto this window's virtual
// display. Never dockable — it stands for "whatever was in front on the
// phone", not for one app.

import AppKit

final class HandoffWindowController: StreamWindowController {
    /// The window's subject until the phone reports the top app ("Continue on Mac").
    private(set) var subject: String

    /// The app the phone reports on this display (`window.title`). A later
    /// re-open (after a reconnect; the old display is gone) launches that app
    /// instead of moving whatever is in the foreground then.
    private(set) var pkg: String?

    init(stream: UInt32, manager: WindowManager) {
        subject = "Continue on Mac"
        super.init(stream: stream, contentSize: AppWindowController.defaultContentSize, manager: manager, styleKey: nil)
        window?.title = manager.titled(subject)
        window?.minSize = style.windowSize(stream: NSSize(width: 320, height: 240))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The handoff window shows one app once the phone names it; that app's
    /// remembered style applies.
    override var styleKey: String? { pkg.map { WindowStyleStore.key(forPackage: $0) } }

    override func sendOpen() {
        let pixels = displayPixels()
        if let pkg {
            // Reopened after a reconnect: the display is gone and the task with
            // it; put the app back rather than moving whatever is foreground now.
            session.openApp(stream: stream, pkg: pkg, activity: nil,
                            width: Int(pixels.width), height: Int(pixels.height), dpi: dpi())
        } else {
            session.continueTask(stream: stream,
                                 width: Int(pixels.width), height: Int(pixels.height), dpi: dpi())
        }
    }

    override var frameKey: String { "handoff" }

    /// A new subject: the app label the phone reports (WindowManager appends the phone).
    func setSubject(_ label: String) {
        subject = label
        window?.title = manager.titled(label)
    }

    /// The phone reported the app that ended up on this display: even the
    /// style follows the package's remembered choice.
    func adopt(pkg: String) {
        guard self.pkg == nil, !pkg.isEmpty, pkg != "dev.pocketdeck" else { return }
        self.pkg = pkg
        reapplyStoredStyle()
    }

    override func retitle() {
        window?.title = manager.titled(subject)
    }

    /// The fallback launched the app fresh: a standing note in the window
    /// (docs/PROTOCOL.md window.opened `started: "fresh"`).
    func showFreshNotice() {
        let pill = GlassPillView(text: "Opened fresh: the app couldn't be moved", showsProgress: false)
        videoView.addSubview(pill)
        pill.alphaValue = 1
        let size = pill.fittingSize
        pill.frame = NSRect(x: (videoView.bounds.width - size.width) / 2, y: 24,
                            width: size.width, height: size.height)
        pill.autoresizingMask = [.minXMargin, .maxXMargin]
    }
}
