// A Dock app's executable (docs/design/dock.md): a windowless regular app whose
// only job is to be one phone app's Dock/⌘-Tab identity. It asks PocketDeck to
// open the window, shows the app's window menu on a secondary click, and exits
// when the window closes. The lifecycle itself is DockShimMachine
// (DockMessages.swift), which is also unit-tested by K2: this file only reads
// the bundle, drives the machine and performs its actions.
//
// The menu's content is the host's: PocketDeck sends the app's rows (New <App>
// Window, then one item per open window with the front one checked — WIN-26)
// whenever they change, and this shim only renders them. A pick goes back as
// one message; the host raises or opens. That keeps one rule for the menu in
// the host, where the windows and the phone's cap live.

import AppKit
import Dispatch
import os

private let shimLog = Logger(subsystem: "dev.pocketdeck.mac", category: "shim")

final class ShimDelegate: NSObject, NSApplicationDelegate {
    private let center = DistributedNotificationCenter.default()
    private let pid = Int(ProcessInfo.processInfo.processIdentifier)
    private let deviceId: String
    private let pkg: String
    private let profile: String
    private let token: String
    private let hostURL: URL?
    /// An automatic launch does not ask for a window (`--no-open`).
    private let automatic = CommandLine.arguments.contains("--no-open")
    private var state = DockShimMachine.State.starting
    private var retry: Timer?
    private var listening = false
    /// When the observers were registered: the host's answer is measured from it.
    private var listenStartedAt: Date?
    /// Whether this shim has seen the host running (at listen, after its own
    /// launch, or when `opened` arrived). A host exit is only news after that.
    private var hostSeen = false
    /// The host pid's exit watch. `didTerminateApplication` is the named
    /// source (DOCK-19), but LaunchServices does not post it for every launch
    /// (the e2e starts the app by exec); a process source fires for SIGTERM
    /// and SIGKILL alike and is the guarantee.
    private var hostWatch: DispatchSourceProcess?
    /// e2e only: where the built menu is dumped and a press read (Info.plist).
    private let menuDebugDir: String?
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
        guard !deviceId.isEmpty, !pkg.isEmpty else { return }
        // As early as possible: the bind answers once, and a late registration
        // misses it. --dock-debug-listen-delay (e2e) holds this back on purpose.
        let delay = info[DockMessage.plistListenDelay] as? Double ?? 0
        if delay > 0 {
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.startListening() }
            }
        } else {
            startListening()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !deviceId.isEmpty, !pkg.isEmpty else { NSApp.terminate(nil); return }
    }

    /// Dock click while running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        apply(.reopen(now: Date()))
        return false
    }

    /// ⌘-Tab to the shim: the window it stands for comes forward.
    func applicationDidBecomeActive(_ notification: Notification) {
        apply(.activate)
    }

    func applicationWillTerminate(_ notification: Notification) {
        apply(.terminate)
    }

    private func startListening() {
        guard !listening else { return }
        listening = true
        listenStartedAt = Date()
        center.addObserver(self, selector: #selector(opened(_:)), name: DockMessage.opened,
                           object: profile, suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(closed(_:)), name: DockMessage.closed,
                           object: profile, suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(menuReceived(_:)), name: DockMessage.menu,
                           object: profile, suspensionBehavior: .deliverImmediately)
        if menuDebugDir != nil { startDebugPoll() }
        // DOCK-19 (ISS-6): the host's process is the shim's reason to exist. A
        // quit, a crash and a force quit all post this; matching the bundle
        // (not a pid) survives a relaunch racing the notification.
        let runningHost = runningHost()
        hostSeen = runningHost != nil
        if let runningHost { watchHost(pid: runningHost.processIdentifier) }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(hostTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        shimLog.notice("dock shim \(self.pid, privacy: .public) listening")
        // An automatic launch stands for a window that is already open: it
        // posts `ready` until the host answers, so a bind that happened before
        // this moment is not a lost answer. A manual launch asks for the window.
        apply(.launch(automatic: automatic, hostSeen: hostSeen, now: Date()))
    }

    private func apply(_ event: DockShimMachine.Event) {
        let before = state
        let (next, actions) = DockShimMachine.transition(state, event)
        state = next
        if next != before {
            shimLog.notice("dock shim \(self.pid, privacy: .public): \(before.label, privacy: .public) --\(event.label, privacy: .public)--> \(next.label, privacy: .public)")
        }
        if case .bound = next, before != .bound, let started = listenStartedAt {
            let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            shimLog.notice("dock shim \(self.pid, privacy: .public) bound, \(milliseconds, privacy: .public) ms after listening")
        }
        for action in actions { perform(action) }
    }

    private func perform(_ action: DockShimMachine.Action) {
        switch action {
        case .post(let message):
            switch message {
            case .open: post(DockMessage.open)
            case .ready: post(DockMessage.ready)
            case .quit: post(DockMessage.quit)
            }
        case .launchHost:
            launchHostIfNeeded()
        case .startRetry:
            startRetry()
        case .stopRetry:
            retry?.invalidate()
            retry = nil
        case .terminate:
            NSApp.terminate(nil)
        case .exit:
            exit(0)
        }
    }

    private func startRetry() {
        retry?.invalidate()
        retry = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply(.tick(now: Date())) }
        }
    }

    private func launchHostIfNeeded() {
        guard let hostURL else { return }
        // From here the host exists (or is about to): its exit is ours to see.
        hostSeen = true
        if let running = runningHost() {
            watchHost(pid: running.processIdentifier)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--profile", profile]
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: hostURL, configuration: configuration) { [weak self] app, _ in
            guard let self, let app else { return }
            DispatchQueue.main.async { self.watchHost(pid: app.processIdentifier) }
        }
    }

    /// The host bundle (PDHostPath), not a pid: a relaunch keeps the same URL.
    private func runningHost() -> NSRunningApplication? {
        guard let hostURL else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.standardizedFileURL == hostURL.standardizedFileURL
        }
    }

    /// A process source, not a notification: it fires for a normal quit, a
    /// crash and a force quit, and needs no LaunchServices registration of the
    /// host (the e2e starts it by exec). The host is one process; a relaunch
    /// starts its own shims.
    private func watchHost(pid: pid_t) {
        guard pid > 0 else { return }
        hostWatch?.cancel()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.hostWatch = nil
            self.apply(.hostExited)
        }
        hostWatch = source
        source.resume()
        // Gone before the watch started: the source would never fire.
        if kill(pid, 0) != 0, errno == ESRCH { apply(.hostExited) }
    }

    /// DOCK-19 (ISS-6): `didTerminateApplication` covers quit, crash and force
    /// quit. A shim bound to that host (or waiting after seeing it) exits.
    @objc private func hostTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let hostURL,
              app.bundleURL?.standardizedFileURL == hostURL.standardizedFileURL else { return }
        apply(.hostExited)
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
              seconds > 0, seconds <= 10, !rows.isEmpty else { return }
        let menu = buildMenu()
        // The tracking loop owns this thread until the timer cancels it, so the
        // timer goes in before the menu is up. Event tracking is where a menu's
        // own loop runs: the cap must fire there, not only in common modes.
        let close = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { menu.cancelTracking() }
        }
        RunLoop.main.add(close, forMode: .common)
        RunLoop.main.add(close, forMode: .eventTracking)
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
        hostSeen = true
        apply(.opened)
    }

    @objc private func closed(_ notification: Notification) {
        guard isMine(notification) else { return }
        apply(.closed)
    }
}

let delegate = ShimDelegate()
NSApplication.shared.delegate = delegate
// A background-mode (e2e) shim is built as an agent and stays one.
if Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool != true {
    NSApp.setActivationPolicy(.regular)
}
NSApp.run()
