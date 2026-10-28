// A Dock app's executable (docs/design/dock.md): a windowless regular app whose
// only job is to be one phone app's Dock/⌘-Tab identity. It asks PocketDeck to
// open the window, shows the app's window menu on a secondary click, and exits
// when the window closes.
//
// The menu's content is the host's: PocketDeck sends the app's rows (New <App>
// Window, then one item per open window with the front one checked — WIN-26)
// whenever they change, and this shim only renders them. A pick goes back as
// one message; the host raises or opens. That keeps one rule for the menu in
// the host, where the windows and the phone's cap live.

import AppKit

final class ShimDelegate: NSObject, NSApplicationDelegate {
    private let center = DistributedNotificationCenter.default()
    private let pid = Int(ProcessInfo.processInfo.processIdentifier)
    private let deviceId: String
    private let pkg: String
    private let profile: String
    private let token: String
    private let hostURL: URL?
    /// e2e only: where the built menu is dumped and a press read (Info.plist).
    private let menuDebugDir: String?
    private var acknowledged = false
    private var startedAt = Date()
    private var launchedHost = false
    private var retry: Timer?
    /// The app's window menu, front to back (the host's rows).
    private var rows: [AppWindowMenuRow] = []
    private var debugTimer: Timer?

    override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        deviceId = info[DockMessage.plistDeviceId] as? String ?? ""
        pkg = info[DockMessage.plistPackage] as? String ?? ""
        profile = info[DockMessage.plistProfile] as? String ?? "default"
        token = info[DockMessage.plistToken] as? String ?? ""
        hostURL = (info[DockMessage.plistHostPath] as? String).map { URL(fileURLWithPath: $0) }
        menuDebugDir = info[DockMessage.plistMenuDebugDir] as? String
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !deviceId.isEmpty, !pkg.isEmpty else { NSApp.terminate(nil); return }
        center.addObserver(self, selector: #selector(opened(_:)), name: DockMessage.opened,
                           object: profile, suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(closed(_:)), name: DockMessage.closed,
                           object: profile, suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(menuReceived(_:)), name: DockMessage.menu,
                           object: profile, suspensionBehavior: .deliverImmediately)
        if menuDebugDir != nil { startDebugPoll() }
        requestOpen()
    }

    /// Dock click while running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        requestOpen()
        return false
    }

    /// ⌘-Tab to the shim: the window it stands for comes forward.
    func applicationDidBecomeActive(_ notification: Notification) {
        if acknowledged { post(DockMessage.open) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        post(DockMessage.quit)
    }

    // MARK: The Dock menu (WIN-26)

    /// What a secondary click on the Dock icon shows: New <App> Window ⌘N, a
    /// rule, then one item per open window, the front one checked. A disabled
    /// item carries the host's sentence as its tooltip and sends nothing.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard !rows.isEmpty else { return nil }
        return buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        for (index, row) in rows.enumerated() {
            if index == 1 { menu.addItem(.separator()) }
            let item = NSMenuItem(title: row.title, action: #selector(pick(_:)),
                                  keyEquivalent: row.key ?? "")
            if let key = row.key, !key.isEmpty { item.keyEquivalentModifierMask = .command }
            item.target = self
            item.tag = index
            item.isEnabled = row.enabled
            item.state = row.checked ? .on : .off
            item.toolTip = row.help
            menu.addItem(item)
        }
        return menu
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard rows.indices.contains(sender.tag) else { return }
        postPick(rows[sender.tag])
    }

    private func postPick(_ row: AppWindowMenuRow) {
        center.postNotificationName(DockMessage.pick, object: profile,
                                    userInfo: [DockMessage.deviceIdKey: deviceId,
                                               DockMessage.pkgKey: pkg,
                                               DockMessage.pidKey: pid,
                                               DockMessage.tokenKey: token,
                                               DockMessage.rowsKey: [row.message]],
                                    deliverImmediately: true)
    }

    @objc private func menuReceived(_ notification: Notification) {
        guard isMine(notification),
              let messages = notification.userInfo?[DockMessage.rowsKey] as? [[String: Any]]
        else { return }
        rows = messages.compactMap(AppWindowMenuRow.init(message:))
        writeMenuDump()
    }

    // MARK: e2e (`--debug-control`): the built menu, and a press through it

    /// A quiet e2e run cannot right-click the Dock. With a debug directory the
    /// shim dumps the menu it builds (the same `buildMenu` the Dock is handed)
    /// and, when the check writes `-press.cmd` with an index, presses that item
    /// through `performActionForItem` — the item's own target and action, not
    /// the host's code.
    private func menuDumpPath() -> String? {
        menuDebugDir.map { ($0 as NSString).appendingPathComponent("dockmenu-\(pkg).json") }
    }

    private func writeMenuDump() {
        guard let path = menuDumpPath() else { return }
        let menu = buildMenu()
        let items: [[String: Any]] = menu.items.map { item in
            if item.isSeparatorItem { return ["separator": true] }
            return ["title": item.title, "enabled": item.isEnabled,
                    "checked": item.state == .on, "key": item.keyEquivalent,
                    "help": item.toolTip ?? ""]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func startDebugPoll() {
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollPress()
                self?.pollShow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        debugTimer = timer
    }

    /// e2e (`--debug-control`): `dockmenu-<pkg>-show` pops the menu the Dock
    /// hands it for the seconds in the file. The Dock owns a secondary click on
    /// its own icon, so a check cannot post a person's right click; this shows
    /// the same `buildMenu`, for the review's shot.
    private func pollShow() {
        guard let directory = menuDebugDir else { return }
        let path = (directory as NSString).appendingPathComponent("dockmenu-\(pkg)-show")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: path)
        guard let seconds = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds > 0, seconds <= 30, !rows.isEmpty else { return }
        let menu = buildMenu()
        // The tracking loop owns this thread until the timer cancels it, so the
        // timer goes in before the menu is up.
        let close = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { menu.cancelTracking() }
        }
        RunLoop.main.add(close, forMode: .common)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: screen.maxX - 120, y: screen.minY + 120), in: nil)
    }

    private func pollPress() {
        guard let directory = menuDebugDir else { return }
        // No `.cmd` suffix: the host's own debug-control route owns those
        // files, and it would consume this one first.
        let path = (directory as NSString).appendingPathComponent("dockmenu-\(pkg)-press")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: path)
        guard let index = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              buildMenu().items.indices.contains(index) else { return }
        buildMenu().performActionForItem(at: index)
    }

    // MARK: Host messages

    private func requestOpen() {
        acknowledged = false
        startedAt = Date()
        post(DockMessage.open)
        retry?.invalidate()
        retry = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryOpen() }
        }
    }

    private func retryOpen() {
        guard !acknowledged else { retry?.invalidate(); return }
        let waited = Date().timeIntervalSince(startedAt)
        if waited > 30 { NSApp.terminate(nil); return }
        if waited >= 2, !launchedHost { launchHostIfNeeded() }
        post(DockMessage.open)
    }

    private func launchHostIfNeeded() {
        launchedHost = true
        guard let hostURL else { return }
        let running = NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.standardizedFileURL == hostURL.standardizedFileURL
        }
        guard !running else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--profile", profile]
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: hostURL, configuration: configuration) { _, _ in }
    }

    private func post(_ name: Notification.Name) {
        center.postNotificationName(name, object: profile,
                                    userInfo: [DockMessage.deviceIdKey: deviceId, DockMessage.pkgKey: pkg,
                                               DockMessage.pidKey: pid, DockMessage.tokenKey: token],
                                    deliverImmediately: true)
    }

    private func isMine(_ notification: Notification) -> Bool {
        (notification.userInfo?[DockMessage.pidKey] as? Int) == pid
    }

    @objc private func opened(_ notification: Notification) {
        guard isMine(notification) else { return }
        acknowledged = true
        retry?.invalidate()
    }

    @objc private func closed(_ notification: Notification) {
        guard isMine(notification) else { return }
        exit(0)
    }
}

let delegate = ShimDelegate()
NSApplication.shared.delegate = delegate
// A background-mode (e2e) shim is built as an agent and stays one.
if Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool != true {
    NSApp.setActivationPolicy(.regular)
}
NSApp.run()
