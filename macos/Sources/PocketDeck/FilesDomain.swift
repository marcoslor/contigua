// File Provider experiment (docs/design/files.md §1, E1–E4). The app side of
// the experiment, and nothing a shipped build uses: `--files-domain` is a test
// hook, refused unless the run is inside the e2e VM (PD_E2E_IN_VM=1), because
// adding the domain puts a location in the person's Finder.
//
// The bridge is the other half of E2: the sandboxed extension must not dial the
// phone (one session, owned by the app), so it asks the app over a UNIX socket.
// The app listens on the App Group container and, as the fallback the design
// names, on the profile's Application Support folder.

import AppKit
import FileProvider
import Foundation

enum FilesExperiment {
    static let groupID = "group.dev.pocketdeck.mac.files.filesexp"
    static let domainID = "dev.pocketdeck.mac.filesexp"
    static let displayName = "PocketDeck Files"
    /// The fallback the design's §1 names: the extension's temporary sandbox
    /// exception covers this folder, for the profile the experiment runs.
    static let profileFolder = "PocketDeck-filesexp"
}

/// A one-shot `--files-domain` action. `add` also starts the bridge and leaves
/// the app running (the extension needs it); the others print and exit.
enum FilesDomainAction: String {
    case add, remove, list, disconnect, reconnect, bridge
}

func filesPrint(_ line: String) {
    print(line)
    fflush(stdout)
}

func filesErrorLine(_ prefix: String, _ error: Error?) -> String {
    guard let error = error as NSError? else { return "\(prefix): ok" }
    return "\(prefix): error domain=\(error.domain) code=\(error.code) \(error.localizedDescription)"
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

enum FilesDomainHooks {
    static func run(_ action: FilesDomainAction) {
        switch action {
        case .add:
            let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(FilesExperiment.domainID),
                                              displayName: FilesExperiment.displayName)
            let error = filesWait(30) { NSFileProviderManager.add(domain, completionHandler: $0) }
            filesPrint(filesErrorLine("files-domain add", error))
            if error == nil {
                FilesBridge.shared.start()
            }
        case .remove:
            removeDomain()
        case .list:
            listDomains()
        case .disconnect:
            guard let manager = managerForDomain() else { return }
            let error = filesWait(15) {
                manager.disconnect(reason: "PocketDeck files experiment: phone away",
                                   options: [.temporary], completionHandler: $0)
            }
            filesPrint(filesErrorLine("files-domain disconnect", error))
        case .reconnect:
            guard let manager = managerForDomain() else { return }
            let error = filesWait(15) { manager.reconnect(completionHandler: $0) }
            filesPrint(filesErrorLine("files-domain reconnect", error))
        case .bridge:
            FilesBridge.shared.start()
        }
    }

    /// The manager for the experiment's domain, from getDomains (the `for: nil`
    /// manager is the app's default domain, not necessarily this one).
    private static func managerForDomain() -> NSFileProviderManager? {
        var domains: [NSFileProviderDomain]?
        _ = filesWait(20) { completion in
            NSFileProviderManager.getDomainsWithCompletionHandler { list, _ in
                domains = list
                completion(nil)
            }
        }
        guard let domain = domains?.first(where: { $0.identifier.rawValue == FilesExperiment.domainID }) else {
            filesPrint("files-domain: domain \(FilesExperiment.domainID) not found")
            return nil
        }
        return NSFileProviderManager(for: domain)
    }

    private static func listDomains() {
        var domains: [NSFileProviderDomain]?
        _ = filesWait(20) { completion in
            NSFileProviderManager.getDomainsWithCompletionHandler { list, _ in
                domains = list
                completion(nil)
            }
        }
        let list = domains ?? []
        filesPrint("files-domain list: count=\(list.count)")
        for domain in list {
            filesPrint("files-domain list: id=\(domain.identifier.rawValue) display=\(domain.displayName) disconnected=\(domain.isDisconnected) replicated=\(domain.isReplicated)")
        }
        listDomainsVisiblePaths(list)
    }

    /// The user-visible URL, which is the CloudStorage path when the domain is
    /// mounted; printed for the check to `ls`.
    private static func listDomainsVisiblePaths(_ domains: [NSFileProviderDomain]) {
        for domain in domains {
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

    private static func removeDomain() {
        var domains: [NSFileProviderDomain]?
        _ = filesWait(20) { completion in
            NSFileProviderManager.getDomainsWithCompletionHandler { list, _ in
                domains = list
                completion(nil)
            }
        }
        guard let domain = domains?.first(where: { $0.identifier.rawValue == FilesExperiment.domainID }) else {
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
}

// MARK: - Bridge

/// Listens on `<group container>/files.sock` and, if the group is unavailable,
/// on the profile's Application Support folder. Answers `pong` and logs every
/// connection, which is E2's evidence.
final class FilesBridge {
    static let shared = FilesBridge()
    private var listenFDs: [Int32] = []
    private let queue = DispatchQueue(label: "dev.pocketdeck.mac.files-bridge")
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        var candidates: [(String, String)] = []
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: FilesExperiment.groupID) {
            candidates.append(("group", group.appendingPathComponent("files.sock").path))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(FilesExperiment.profileFolder, isDirectory: true)
        candidates.append(("app-support", support.appendingPathComponent("files.sock").path))

        for (label, path) in candidates {
            let result = listen(label: label, path: path)
            filesPrint("files-domain bridge \(label): \(result)")
            appendLog("bridge \(label): \(result)", directory: URL(fileURLWithPath: path).deletingLastPathComponent())
        }
        queue.async { [weak self] in
            while let self, !self.listenFDs.isEmpty {
                for fd in self.listenFDs {
                    let client = accept(fd, nil, nil)
                    guard client >= 0 else { continue }
                    self.answer(client)
                }
                usleep(20_000)
            }
        }
    }

    private func listen(label: String, path: String) -> String {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        unlink(path)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return "path too long" }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: bytes) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return "socket errno \(errno)" }
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { let e = errno; close(fd); return "bind errno \(e)" }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 8) == 0 else { let e = errno; close(fd); return "listen errno \(e)" }
        listenFDs.append(fd)
        return path
    }

    private func answer(_ fd: Int32) {
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = read(fd, &buffer, buffer.count)
        let request = count > 0 ? String(decoding: buffer[0..<count], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let reply = Array("pong\n".utf8)
        _ = write(fd, reply, reply.count)
        let line = "connection request=\(request) reply=pong"
        filesPrint("files-domain bridge: \(line)")
        appendLog(line, directory: nil)
    }

    private func appendLog(_ line: String, directory: URL?) {
        guard let data = ("\(ISO8601DateFormatter().string(from: Date())) \(line)\n").data(using: .utf8) else { return }
        var dirs: [URL] = []
        if let directory { dirs.append(directory) }
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: FilesExperiment.groupID) {
            dirs.append(group)
        }
        dirs.append(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(FilesExperiment.profileFolder, isDirectory: true))
        for dir in Set(dirs) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("files-bridge.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
