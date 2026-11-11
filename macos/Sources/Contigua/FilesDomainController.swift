// "Show phone files in Finder": the one File Provider domain this profile owns
// (docs/design/files.md §1, §5). The setting is off by default; turning it on
// adds the domain and starts the bridge, turning it off removes the domain.
// While the phone session is up the domain is reconnected, while it is away it
// is disconnected so Finder says the items may be out of date and cached files
// still open.
//
// A new domain starts user-disabled: the system keeps `userEnabled` false until
// the person flips Contigua's File Provider switch in System Settings ›
// General › Login Items & Extensions. There is no API for that switch, so the
// controller reports `needsSwitch` and offers the pane's deep link.

import AppKit
@preconcurrency import FileProvider
import Foundation
import Observation

enum FilesDomainSetting {
    static let key = "files.showInFinder"

    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: key)
    }

    static func write(_ on: Bool, in defaults: UserDefaults) {
        defaults.set(on, forKey: key)
    }

    static var systemSettingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension?Extensions")
    }
}

/// One domain as the controller needs it, without the system type (so the
/// controller is testable with no NSFileProviderManager anywhere).
struct FilesDomainInfo: Equatable {
    var identifier: String
    var displayName: String
    var isDisconnected: Bool
    var userEnabled: Bool
}

/// Whether this app bundle can serve Finder files: the App Group and the
/// extension bundle that `bundle.sh --with-files` adds. The check itself is a
/// pure function (FilesCore.swift), so a fake Info dictionary and path test it.
enum FilesBundleSupportCheck {
    static func isSupported(bundle: Bundle = .main,
                            fileManager: FileManager = .default) -> Bool {
        let appex = bundle.bundleURL.appendingPathComponent(FilesBundleSupport.extensionPath)
        return FilesBundleSupport.supports(info: bundle.infoDictionary,
                                           extensionExists: fileManager.fileExists(atPath: appex.path))
    }
}

@MainActor
protocol FilesDomainManaging: AnyObject {
    func domain(identifier: String) -> FilesDomainInfo?
    func add(identifier: String, displayName: String, completion: @escaping (Error?) -> Void)
    func remove(identifier: String, completion: @escaping (Error?) -> Void)
    func reconnect(identifier: String, completion: @escaping (Error?) -> Void)
    func disconnect(identifier: String, reason: String, completion: @escaping (Error?) -> Void)
    /// Re-enumerates the working set: the only container a replicated extension
    /// may signal (NSFileProviderManager.h, design "S5 round 3").
    func signalWorkingSet(identifier: String, completion: @escaping (Error?) -> Void)
}

/// A manager that reports this profile's domain as already added (`--files-domain-seen`,
/// host e2e): the real one needs File Provider, and a check on the person's Mac
/// must not touch it. Every change is a no-op that succeeds.
@MainActor
final class FilesDomainSeenManager: FilesDomainManaging {
    private let seen: String

    init(identifier: String) {
        seen = identifier
    }

    func domain(identifier: String) -> FilesDomainInfo? {
        guard identifier == seen else { return nil }
        return FilesDomainInfo(identifier: identifier, displayName: "Contigua",
                               isDisconnected: false, userEnabled: true)
    }

    func add(identifier: String, displayName: String, completion: @escaping (Error?) -> Void) {
        completion(nil)
    }

    func remove(identifier: String, completion: @escaping (Error?) -> Void) {
        completion(nil)
    }

    func reconnect(identifier: String, completion: @escaping (Error?) -> Void) {
        completion(nil)
    }

    func disconnect(identifier: String, reason: String, completion: @escaping (Error?) -> Void) {
        completion(nil)
    }

    func signalWorkingSet(identifier: String, completion: @escaping (Error?) -> Void) {
        completion(nil)
    }
}

@MainActor
@Observable
final class FilesDomainController {
    enum State: Equatable {
        /// The setting is off (or the domain was removed).
        case off
        /// The add is in flight.
        case adding
        /// Added and enabled: Finder shows the phone.
        case on
        /// Added, but the person has not turned Contigua on in System Settings.
        case needsSwitch
        /// The system refused an operation; the row says so.
        case failed
    }

    let profile: Profile
    /// Whether this bundle carries the Files extension at all. A build without
    /// it says so and never adds a domain: "restart and try again" could not
    /// help, and a half-added domain is worse than an honest switch.
    let supported: Bool
    private(set) var state: State = .off
    private(set) var enabled: Bool

    var needsSwitch: Bool { state == .needsSwitch }

    private let manager: any FilesDomainManaging
    private let fixedSocketPath: String?
    private let startBridge: (String) -> String
    private let stopBridge: () -> Void
    private let openSettings: () -> Void
    private var sessionUp = false
    private var addedLocally = false
    private var loggedUnsupported = false
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    var identifier: String { FilesDomain.identifier(profile: profile) }

    init(profile: Profile,
         manager: (any FilesDomainManaging)? = nil,
         socketPath: String? = nil,
         startBridge: ((String) -> String)? = nil,
         stopBridge: (() -> Void)? = nil,
         openSettings: (() -> Void)? = nil,
         supported: Bool? = nil) {
        self.profile = profile
        self.supported = supported ?? FilesBundleSupportCheck.isSupported()
        enabled = self.supported && FilesDomainSetting.isEnabled(in: profile.defaults)
        self.manager = manager ?? SystemFilesDomainManager()
        fixedSocketPath = socketPath
        self.startBridge = startBridge ?? { FilesBridge.shared.start(path: $0) }
        self.stopBridge = stopBridge ?? { FilesBridge.shared.stop() }
        self.openSettings = openSettings ?? {
            if let url = FilesDomainSetting.systemSettingsURL { NSWorkspace.shared.open(url) }
        }
    }

    /// Called once at launch (and from the e2e hook's add): brings the domain in
    /// line with the stored setting.
    func start() {
        guard supported else {
            state = .off
            logUnsupported()
            return
        }
        guard enabled else {
            state = .off
            return
        }
        ensureDomain()
        refreshDisplayName()
        observeActivation()
    }

    /// Re-reads the switch state, e.g. when the person comes back from System
    /// Settings. Never adds or removes anything.
    func refresh() {
        guard enabled, let info = manager.domain(identifier: identifier) else { return }
        let next: State = info.userEnabled ? .on : .needsSwitch
        if next != state {
            state = next
            Log.files.notice("domain state=\(next == .on ? "on" : "switched-off", privacy: .public)")
        }
    }

    func setEnabled(_ on: Bool) {
        guard supported else {
            state = .off
            logUnsupported()
            return
        }
        guard on != enabled else { return }
        enabled = on
        FilesDomainSetting.write(on, in: profile.defaults)
        if on {
            ensureDomain()
            observeActivation()
        } else {
            removeDomain()
        }
    }

    /// The session's transitions drive reconnect/disconnect (design §5). A
    /// repeat of the same state does nothing.
    func sessionReady(_ up: Bool) {
        guard up != sessionUp else { return }
        sessionUp = up
        guard addedLocally || manager.domain(identifier: identifier) != nil else { return }
        if up {
            manager.reconnect(identifier: identifier) { _ in }
            manager.signalWorkingSet(identifier: identifier) { _ in }
            // The phone's name is only known now: the domain may have been
            // added before the session remembered it (a first launch).
            refreshDisplayName()
            Log.files.notice("domain reconnect")
        } else {
            manager.disconnect(identifier: identifier, reason: "Phone not connected") { _ in }
            Log.files.notice("domain disconnect")
        }
    }

    /// The Finder location names the phone: "Contigua (<name>)". A nickname
    /// change or the phone's own name arriving after the domain was added is
    /// applied by re-adding the same identifier with the new display name,
    /// which macOS updates in place (the folder and its cached files stay).
    func refreshDisplayName() {
        guard supported, let info = manager.domain(identifier: identifier) else { return }
        let name = FilesDomain.displayName(profile: profile)
        guard info.displayName != name else { return }
        manager.add(identifier: identifier, displayName: name) { error in
            if error == nil {
                Log.files.notice("domain: display name updated")
            } else {
                Log.files.notice("domain: display name update failed")
            }
        }
    }

    private func logUnsupported() {
        guard !loggedUnsupported else { return }
        loggedUnsupported = true
        Log.files.notice("domain: this bundle has no Files extension")
    }

    func openSystemSettings() {
        openSettings()
    }

    /// The phone says a watched folder moved (design "S5 round 3"). The only
    /// signal a replicated extension may act on is the working set, and it also
    /// starts an extension when none is running.
    func signalWorkingSet() {
        // The VM hook and a domain added outside Settings follow the session
        // without the stored setting; a guard on `enabled` alone would drop
        // every signal there (round 3's first VM run did exactly that).
        guard enabled || addedLocally else { return }
        manager.signalWorkingSet(identifier: identifier) { error in
            guard let error = error as NSError? else {
                Log.files.notice("domain: signal working set")
                return
            }
            Log.files.notice("domain: signal working set failed domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public)")
        }
    }

    /// The VM hook adds the domain itself (so `--files-domain add` can report
    /// the exact error); from then on this controller manages its session
    /// transitions like a domain added from Settings.
    func adopt() {
        addedLocally = true
    }

    // MARK: Internals

    private func ensureDomain() {
        if let info = manager.domain(identifier: identifier) {
            addedLocally = true
            state = info.userEnabled ? .on : .needsSwitch
            // The bridge is this process's socket in the App Group container,
            // and it dies with the process. A relaunch finds the domain still
            // added, so this branch is the only place that brings it back; the
            // extension had nothing to reach without it.
            guard startBridgeIfNeeded() else { return }
            if info.userEnabled && sessionUp {
                manager.reconnect(identifier: identifier) { _ in }
                manager.signalWorkingSet(identifier: identifier) { _ in }
            }
            return
        }
        guard startBridgeIfNeeded() else { return }
        state = .adding
        manager.add(identifier: identifier,
                    displayName: FilesDomain.displayName(profile: profile)) { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.state = .failed
                Log.files.notice("domain add failed")
                return
            }
            self.addedLocally = true
            // A fresh domain is user-disabled until the person flips the switch.
            self.state = .needsSwitch
            Log.files.notice("domain added; waiting for the System Settings switch")
            if self.sessionUp {
                self.manager.reconnect(identifier: self.identifier) { _ in }
                self.manager.signalWorkingSet(identifier: self.identifier) { _ in }
            }
        }
    }

    /// Starts the extension's bridge if this process has not already. The
    /// socket lives in the App Group container and dies with the process, so
    /// every launch needs it even when the domain already exists; the bridge
    /// itself is idempotent.
    @discardableResult
    private func startBridgeIfNeeded() -> Bool {
        guard let path = fixedSocketPath ?? FilesSocket.groupPath(profile: profile) else {
            state = .failed
            Log.files.notice("domain: this bundle has no app group")
            return false
        }
        guard startBridge(path) == "ok" else {
            state = .failed
            Log.files.notice("domain: the bridge socket did not come up")
            return false
        }
        return true
    }

    private func removeDomain() {
        stopBridge()
        guard manager.domain(identifier: identifier) != nil else {
            state = .off
            addedLocally = false
            return
        }
        state = .off
        addedLocally = false
        manager.remove(identifier: identifier) { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.state = .failed
                Log.files.notice("domain remove failed")
            } else {
                Log.files.notice("domain removed")
            }
        }
    }

    /// Coming back from System Settings is the moment the switch may have moved.
    private func observeActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
}

/// The real manager: NSFileProviderManager, no File Provider extension involved
/// (adding a domain is the app's half of the contract).
@MainActor
final class SystemFilesDomainManager: FilesDomainManaging {
    func domain(identifier: String) -> FilesDomainInfo? {
        var found: FilesDomainInfo?
        _ = filesWait(20) { completion in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in
                if let domain = domains.first(where: { $0.identifier.rawValue == identifier }) {
                    found = FilesDomainInfo(identifier: domain.identifier.rawValue,
                                            displayName: domain.displayName,
                                            isDisconnected: domain.isDisconnected,
                                            userEnabled: domain.userEnabled)
                }
                completion(nil)
            }
        }
        return found
    }

    func add(identifier: String, displayName: String,
             completion: @escaping (Error?) -> Void) {
        cachedManagers.removeValue(forKey: identifier)
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(identifier), displayName: displayName)
        NSFileProviderManager.add(domain, completionHandler: completion)
    }

    func remove(identifier: String, completion: @escaping (Error?) -> Void) {
        cachedManagers.removeValue(forKey: identifier)
        guard let domain = domainObject(identifier) else { return completion(nil) }
        NSFileProviderManager.remove(domain, mode: .removeAll) { _, error in completion(error) }
    }

    func reconnect(identifier: String, completion: @escaping (Error?) -> Void) {
        guard let manager = manager(identifier) else { return completion(nil) }
        manager.reconnect(completionHandler: completion)
    }

    func disconnect(identifier: String, reason: String,
                    completion: @escaping (Error?) -> Void) {
        guard let manager = manager(identifier) else { return completion(nil) }
        manager.disconnect(reason: reason, options: [.temporary], completionHandler: completion)
    }

    /// The working set, never a folder: NSFileProviderManager.h says the other
    /// container identifiers are ignored for a replicated extension.
    func signalWorkingSet(identifier: String, completion: @escaping (Error?) -> Void) {
        guard let manager = manager(identifier) else { return completion(nil) }
        manager.signalEnumerator(for: .workingSet, completionHandler: completion)
    }

    private func domainObject(_ identifier: String) -> NSFileProviderDomain? {
        var found: NSFileProviderDomain?
        _ = filesWait(20) { done in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in
                found = domains.first { $0.identifier.rawValue == identifier }
                done(nil)
            }
        }
        return found
    }

    private func manager(_ identifier: String) -> NSFileProviderManager? {
        // The domain lookup is a round trip to fileproviderd and this now runs
        // on every phone-side change: one lookup per domain, not per change.
        if let cached = cachedManagers[identifier] { return cached }
        guard let domain = domainObject(identifier) else { return nil }
        let manager = NSFileProviderManager(for: domain)
        cachedManagers[identifier] = manager
        return manager
    }

    /// Manager per domain, dropped whenever the domain set changes.
    private var cachedManagers: [String: NSFileProviderManager] = [:]
}
