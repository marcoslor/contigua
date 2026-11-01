// A Dock app's executable (docs/design/dock.md): a windowless regular app whose
// only job is to be one phone app's Dock/⌘-Tab identity. It asks PocketDeck to
// open the window and exits when the window closes.

import AppKit

final class ShimDelegate: NSObject, NSApplicationDelegate {
    private let center = DistributedNotificationCenter.default()
    private let pid = Int(ProcessInfo.processInfo.processIdentifier)
    private let deviceId: String
    private let pkg: String
    private let profile: String
    private let token: String
    private let hostURL: URL?
    private var acknowledged = false
    private var startedAt = Date()
    private var launchedHost = false
    private var retry: Timer?
    /// An automatic launch does not ask for a window (`--no-open`).
    private var asksForWindow = true

    override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        deviceId = info[DockMessage.plistDeviceId] as? String ?? ""
        pkg = info[DockMessage.plistPackage] as? String ?? ""
        profile = info[DockMessage.plistProfile] as? String ?? "default"
        token = info[DockMessage.plistToken] as? String ?? ""
        hostURL = (info[DockMessage.plistHostPath] as? String).map { URL(fileURLWithPath: $0) }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !deviceId.isEmpty, !pkg.isEmpty else { NSApp.terminate(nil); return }
        // e2e: a slow launch registers its observers late, after the host has
        // already bound the pid and posted its one `opened` (the lost-answer
        // race). Only a bundle built with --dock-debug-listen-delay has the key.
        let delay = (Bundle.main.infoDictionary?[DockMessage.plistListenDelay] as? Double) ?? 0
        if delay > 0 {
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.startListening() }
            }
        } else {
            startListening()
        }
    }

    private func startListening() {
        center.addObserver(self, selector: #selector(opened(_:)), name: DockMessage.opened,
                           object: profile, suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(closed(_:)), name: DockMessage.closed,
                           object: profile, suspensionBehavior: .deliverImmediately)
        // An automatic launch stands for a window that is already open: the host
        // binds it and answers `opened`, so asking for a window would only open a
        // second one (or bring a closed one back). It still quits if nobody
        // answers, so a lost host never leaves a Dock tile behind.
        if CommandLine.arguments.contains("--no-open") {
            asksForWindow = false
            startedAt = Date()
            startRetry()
        } else {
            requestOpen()
        }
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

    private func requestOpen() {
        acknowledged = false
        startedAt = Date()
        post(DockMessage.open)
        startRetry()
    }

    private func startRetry() {
        retry?.invalidate()
        retry = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryOpen() }
        }
    }

    private func retryOpen() {
        guard !acknowledged else { retry?.invalidate(); return }
        let waited = Date().timeIntervalSince(startedAt)
        if waited > 30 { NSApp.terminate(nil); return }
        guard asksForWindow else { return }
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
