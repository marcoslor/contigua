// A Dock app's executable (docs/design/dock.md): a windowless regular app whose
// only job is to be one phone app's Dock/⌘-Tab identity. It asks PocketDeck to
// open the window and exits when the window closes. The lifecycle itself is
// DockShimMachine (DockMessages.swift), which is also unit-tested by K2: this
// file only reads the bundle, drives the machine and performs its actions.

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

    override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        deviceId = info[DockMessage.plistDeviceId] as? String ?? ""
        pkg = info[DockMessage.plistPackage] as? String ?? ""
        profile = info[DockMessage.plistProfile] as? String ?? "default"
        token = info[DockMessage.plistToken] as? String ?? ""
        hostURL = (info[DockMessage.plistHostPath] as? String).map { URL(fileURLWithPath: $0) }
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
