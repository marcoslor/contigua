// The File Provider domain (docs/design/files.md §1, §3): the test-only
// `--files-domain` actions and the shape of the one domain this profile owns.
//
// Adding a domain puts a location in the person's Finder, so every action here
// refuses to run outside the e2e VM (PD_E2E_IN_VM=1). The real entry point is
// Settings › "Show phone files in Finder" (FilesDomainController.swift).

import AppKit
@preconcurrency import FileProvider
import Foundation

/// A one-shot `--files-domain` action. `add` also starts the bridge and leaves
/// the app running (the extension needs it); the others print and exit.
enum FilesDomainAction: String {
    case add, remove, list, disconnect, reconnect
}

func filesPrint(_ line: String) {
    print(line)
    fflush(stdout)
}

func filesErrorLine(_ prefix: String, _ error: Error?) -> String {
    guard let error = error as NSError? else { return "\(prefix): ok" }
    return "\(prefix): error domain=\(error.domain) code=\(error.code)"
}

/// Waits for an NSFileProviderManager completion handler while the main run
/// loop keeps turning, so a completion delivered on the main queue works too.
func filesWait(_ timeout: TimeInterval, _ start: (@escaping (Error?) -> Void) -> Void) -> Error? {
    var finished = false
    var result: Error?
    start { error in
        result = error
        finished = true
    }
    let deadline = Date().addingTimeInterval(timeout)
    while !finished && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
    return result
}

/// The one domain this profile owns. The identifier is the profile name (one
/// domain per profile, as the socket name is); the display name is the phone's
/// nickname when the profile knows one, else "PocketDeck" (design §3).
enum FilesDomain {
    static func identifier(profile: Profile) -> String { profile.name }

    static func displayName(profile: Profile) -> String {
        let remembered = RememberedPhones(profile: profile)
        guard let phone = remembered.active else { return "PocketDeck" }
        let nickname = PhoneNicknames.read(from: profile.defaults, deviceId: phone.id)
        return nickname.isEmpty ? "PocketDeck" : nickname
    }

    static func domain(profile: Profile) -> NSFileProviderDomain {
        NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(identifier(profile: profile)),
            displayName: displayName(profile: profile))
    }

    /// The socket path in this bundle's App Group container, or nil when the
    /// bundle carries no group (bundle.sh writes `PDFilesGroup`).
    static func socketPath(profile: Profile) -> String? {
        FilesSocket.groupPath(profile: profile)
    }
}

@MainActor
enum FilesDomainHooks {
    static func run(_ action: FilesDomainAction) {
        let profile = Profile.active
        switch action {
        case .add:
            add(profile)
        case .remove:
            remove(profile)
        case .list:
            list(profile)
        case .disconnect:
            disconnect(profile)
        case .reconnect:
            reconnect(profile)
        }
        if action == .add { startBridge(profile) }
    }

    // MARK: Actions

    private static func add(_ profile: Profile) {
        let error = filesWait(30) {
            NSFileProviderManager.add(FilesDomain.domain(profile: profile), completionHandler: $0)
        }
        filesPrint(filesErrorLine("files-domain add", error))
    }

    private static func startBridge(_ profile: Profile) {
        guard let path = FilesDomain.socketPath(profile: profile) else {
            filesPrint("files-domain bridge group: no app group")
            return
        }
        filesPrint("files-domain bridge group: \(FilesBridge.shared.start(path: path))")
    }

    private static func remove(_ profile: Profile) {
        guard let domain = domain(profile) else {
            filesPrint("files-domain remove: not found")
            return
        }
        let error = filesWait(30) { completion in
            NSFileProviderManager.remove(domain, mode: .removeAll) { _, removeError in
                completion(removeError)
            }
        }
        filesPrint(filesErrorLine("files-domain remove", error))
    }

    private static func disconnect(_ profile: Profile) {
        guard let manager = manager(profile) else { return }
        let error = filesWait(15) {
            manager.disconnect(reason: "Phone not connected",
                               options: [.temporary], completionHandler: $0)
        }
        filesPrint(filesErrorLine("files-domain disconnect", error))
    }

    private static func reconnect(_ profile: Profile) {
        guard let manager = manager(profile) else { return }
        let error = filesWait(15) { manager.reconnect(completionHandler: $0) }
        filesPrint(filesErrorLine("files-domain reconnect", error))
    }

    private static func list(_ profile: Profile) {
        let domains = allDomains()
        filesPrint("files-domain list: count=\(domains.count)")
        for domain in domains {
            filesPrint("files-domain list: id=\(domain.identifier.rawValue) display=\(domain.displayName) disconnected=\(domain.isDisconnected) replicated=\(domain.isReplicated) enabled=\(domain.userEnabled)")
        }
        // The user-visible URL, which is the CloudStorage path when the domain
        // is mounted; printed for the check to `ls`.
        for domain in domains where domain.identifier.rawValue == FilesDomain.identifier(profile: profile) {
            guard let manager = NSFileProviderManager(for: domain) else { continue }
            var url: URL?
            _ = filesWait(10) { completion in
                manager.getUserVisibleURL(for: .rootContainer) { visible, _ in
                    url = visible
                    completion(nil)
                }
            }
            filesPrint("files-domain list: path id=\(domain.identifier.rawValue) \(url?.path ?? "nil")")
        }
    }

    // MARK: Helpers

    private static func allDomains() -> [NSFileProviderDomain] {
        var domains: [NSFileProviderDomain]?
        _ = filesWait(20) { completion in
            NSFileProviderManager.getDomainsWithCompletionHandler { list, _ in
                domains = list
                completion(nil)
            }
        }
        return domains ?? []
    }

    private static func domain(_ profile: Profile) -> NSFileProviderDomain? {
        allDomains().first { $0.identifier.rawValue == FilesDomain.identifier(profile: profile) }
    }

    /// The manager for this profile's domain, from getDomains (the `for: nil`
    /// manager is the app's default domain, not necessarily this one).
    private static func manager(_ profile: Profile) -> NSFileProviderManager? {
        guard let domain = domain(profile) else {
            filesPrint("files-domain: domain \(FilesDomain.identifier(profile: profile)) not found")
            return nil
        }
        return NSFileProviderManager(for: domain)
    }
}
