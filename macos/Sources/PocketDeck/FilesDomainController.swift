// "Show phone files in Finder": the one File Provider domain this profile owns
// (docs/design/files.md §1, §5). The setting is off by default; turning it on
// adds the domain and starts the bridge, turning it off removes the domain.
// While the phone session is up the domain is reconnected, while it is away it
// is disconnected so Finder says the items may be out of date and cached files
// still open.
//
// A new domain starts user-disabled: the system keeps `userEnabled` false until
// the person flips PocketDeck's File Provider switch in System Settings ›
// General › Login Items & Extensions. There is no API for that switch, so the
// controller reports `needsSwitch` and offers the pane's deep link.

import AppKit
@preconcurrency import FileProvider
import Foundation
import Observation

enum FilesDomainSetting {
    static let key = "files.showInFinder"
    /// Which identifier format the extension's ids use (design §3, S4). S3's ids
    /// carried a path; the first run of the new format re-adds the domain so the
    /// system drops them.
    static let idsFormatKey = "files.idsFormat"

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
        /// Added, but the person has not turned PocketDeck on in System Settings.
        case needsSwitch
        /// The system refused an operation; the row says so.
        case failed
    }

    let profile: Profile
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
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    var identifier: String { FilesDomain.identifier(profile: profile) }

    init(profile: Profile,
         manager: (any FilesDomainManaging)? = nil,
         socketPath: String? = nil,
         startBridge: ((String) -> String)? = nil,
         stopBridge: (() -> Void)? = nil,
         openSettings: (() -> Void)? = nil) {
        self.profile = profile
        enabled = FilesDomainSetting.isEnabled(in: profile.defaults)
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
        guard enabled else {
            state = .off
            return
        }
        ensureDomain()
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
            Log.files.notice("domain reconnect")
        } else {
            manager.disconnect(identifier: identifier, reason: "Phone not connected") { _ in }
            Log.files.notice("domain disconnect")
        }
    }

    func openSystemSettings() {
        openSettings()
    }

    /// The phone says a watched folder moved (design "S5 round 3"). The only
    /// signal a replicated extension may act on is the working set, and it also
    /// starts an extension when none is running.
    func signalWorkingSet() {
        guard enabled else { return }
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
        // S3's identifiers carried a path; the app-owned map (format 2) cannot
        // resolve them. Replace the domain once, then never again.
        let storedFormat = profile.defaults.integer(forKey: FilesDomainSetting.idsFormatKey)
        if storedFormat != FilesIdMap.formatVersion,
           manager.domain(identifier: identifier) != nil {
            profile.defaults.set(FilesIdMap.formatVersion,
                                 forKey: FilesDomainSetting.idsFormatKey)
            Log.files.notice("domain: id format changed; replacing the domain")
            manager.remove(identifier: identifier) { [weak self] _ in
                self?.addedLocally = false
                self?.ensureDomain()
            }
            return
        }
        profile.defaults.set(FilesIdMap.formatVersion,
                             forKey: FilesDomainSetting.idsFormatKey)
        if let info = manager.domain(identifier: identifier) {
            addedLocally = true
            state = info.userEnabled ? .on : .needsSwitch
            if info.userEnabled && sessionUp {
                manager.reconnect(identifier: identifier) { _ in }
                manager.signalWorkingSet(identifier: identifier) { _ in }
            }
            return
        }
        guard let path = fixedSocketPath ?? FilesSocket.groupPath(profile: profile) else {
            state = .failed
            Log.files.notice("domain: this bundle has no app group")
            return
        }
        guard startBridge(path) == "ok" else {
            state = .failed
            Log.files.notice("domain: the bridge socket did not come up")
            return
        }
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
