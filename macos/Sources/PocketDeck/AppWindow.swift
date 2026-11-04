// One app stream = one freely resizable Mac window (many can be open at once,
// one per task on the phone: WIN-25).

import AppKit

final class AppWindowController: StreamWindowController {
    let pkg: String
    let activity: String?
    /// The phone this window's stream belongs to (phase 2 has one; the key of
    /// the multi-phone epic's `WindowKey`).
    let deviceId: String
    /// The label the app list gave the package — the window's name while the
    /// app has one window, and the fallback for its task's label.
    private(set) var appLabel: String
    /// The task's own label, as the phone reported it for this window's task
    /// (`window.title` on an app stream; WIN-28). nil until it says one.
    private(set) var taskLabel: String?
    /// The phone's task id for this window's display (`window.opened`,
    /// `taskId`); kept to name and close the right window, never assumed
    /// stable across a reconnect.
    var taskId: Int?

    /// The stream is 900 × 600; the window adds the bar above it.
    static let defaultContentSize = NSSize(width: 900, height: 600)

    /// This window's style is remembered for the app it shows.
    override var styleKey: String? { WindowStyleStore.key(forPackage: pkg) }

    /// So is its density override.
    override var densityPackage: String? { pkg }

    /// A drop on an app window shares straight to the app it shows (SHARE-17).
    override var dropTargetPackage: String? { pkg }

    /// The cover before the first frame: the app's cached icon and its label.
    override var showsOpeningCover: Bool { true }
    override var openingName: String { appLabel }
    override var openingIcon: NSImage? { manager.icons[pkg] }

    /// Only an app's first window is where the app's frame is remembered; an
    /// added window cascades from it and forgets its own place (WIN-13).
    private var storedRemembersFrame = true
    override var remembersFrame: Bool {
        get { storedRemembersFrame }
        set { storedRemembersFrame = newValue }
    }

    /// Where this window opens when it is placed relative to another (an added
    /// window): set before `present()`.
    private var storedPlacement: NSRect?
    override var placementOverride: NSRect? {
        get { storedPlacement }
        set { storedPlacement = newValue }
    }

    init(stream: UInt32, pkg: String, activity: String?, label: String,
         deviceId: String = "", manager: WindowManager) {
        self.pkg = pkg
        self.activity = activity
        self.deviceId = deviceId
        appLabel = label
        super.init(stream: stream, contentSize: Self.defaultContentSize, manager: manager,
                   styleKey: WindowStyleStore.key(forPackage: pkg))
        window?.minSize = style.windowSize(stream: NSSize(width: 320, height: 240))
        retitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func sendOpen() {
        sendOpen(newInstance: false)
    }

    /// One `window.open`: `newInstance` asks for another task of the app on
    /// this display (WIN-25, WIN-34).
    func sendOpen(newInstance: Bool) {
        let pixels = displayPixels()
        session.openApp(stream: stream, pkg: pkg, activity: activity,
                        width: Int(pixels.width), height: Int(pixels.height), dpi: dpi(),
                        newInstance: newInstance)
    }

    override var frameKey: String { "app.\(pkg)" }

    /// The app list arrived (or was corrected): the window's short name.
    func setAppLabel(_ label: String) {
        guard label != appLabel else { return }
        appLabel = label
        retitle()
        refreshOpeningCover()
    }

    /// The phone reported this window's task label. True when it changed, so
    /// the caller can retitle the set and the menus.
    @discardableResult
    func setTaskLabel(_ label: String?) -> Bool {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let value = trimmed.isEmpty ? nil : trimmed
        guard value != taskLabel else { return false }
        taskLabel = value
        retitle()
        return true
    }

    /// "<App> (<phone>)" alone, "<App> — <task> (<phone>)" while its app has
    /// two or more windows on this phone (WIN-3, WIN-28). The task label is
    /// phone content: it is never logged.
    override func retitle() {
        let count = manager.appWindows(pkg: pkg, deviceId: deviceId).count
        let title = WindowTitles.title(app: appLabel, label: taskLabel,
                                       phone: manager.phoneName, windowCount: count)
        if window?.title != title { window?.title = title }
    }
}
