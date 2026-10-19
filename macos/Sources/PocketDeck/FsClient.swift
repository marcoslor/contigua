// Client side of the read-only phone files protocol (docs/PROTOCOL.md "Phone
// files", docs/design/files.md §3): list, stat, ranged reads and cancel on the
// one session. A read streams FS_DATA into an output file, hashes as it goes
// and only hands back a file whose size and SHA-256 match fs.read.end.
//
// The phone is stateless; this type keeps the pending request per id, and
// frames for an id it does not know (cancelled, or a phone that ran ahead) are
// dropped, like every other stream.

import CryptoKit
import Foundation

/// One item of `fs.items` / `fs.item`.
struct FsItem: Equatable {
    var name: String
    var dir: Bool
    var size: Int
    var mtime: Int
    var ino: Int
    var etag: String

    init?(json: [String: Any]) {
        guard let name = json["name"] as? String,
              let dir = json["dir"] as? Bool,
              let etag = json["etag"] as? String else { return nil }
        self.name = name
        self.dir = dir
        self.size = (json["size"] as? NSNumber)?.intValue ?? 0
        self.mtime = (json["mtime"] as? NSNumber)?.intValue ?? 0
        self.ino = (json["ino"] as? NSNumber)?.intValue ?? 0
        self.etag = etag
    }
}

/// One page of a listing; `next` is the phone's cursor for the next page.
struct FsPage: Equatable {
    var items: [FsItem]
    var next: String?
}

/// A completed read: the range's length and the SHA-256 the phone announced.
struct FsReadResult: Equatable {
    var bytes: Int
    var sha256: String
}

/// The phone's `fs_*` refusal.
struct FsError: Error, Equatable, CustomStringConvertible {
    var code: String
    var message: String?

    init(code: String, message: String? = nil) {
        self.code = code
        self.message = message
    }

    var description: String { message.map { "\(code): \($0)" } ?? code }
}

/// What the client needs from the session — the wire is a detail here.
protocol FsChannel: AnyObject {
    func fsList(id: UInt32, path: String, page: String?)
    func fsStat(id: UInt32, path: String)
    func fsRead(id: UInt32, path: String, offset: Int, length: Int, etag: String?)
    func fsCancel(id: UInt32)
}

extension Session: FsChannel {}

@MainActor
final class FsClient {
    private enum Pending {
        case list((Result<FsPage, FsError>) -> Void)
        case stat((Result<FsItem, FsError>) -> Void)
        case read(Read)
    }

    private final class Read {
        let path: String
        let url: URL
        let expected: Int
        let handle: FileHandle
        var received = 0
        var hasher = SHA256()
        var cancelTimer: DispatchWorkItem?
        var completion: ((Result<FsReadResult, FsError>) -> Void)?

        init(path: String, url: URL, expected: Int, handle: FileHandle,
             completion: @escaping (Result<FsReadResult, FsError>) -> Void) {
            self.path = path
            self.url = url
            self.expected = expected
            self.handle = handle
            self.completion = completion
        }
    }

    private weak var channel: (any FsChannel)?
    private var pending: [UInt32: Pending] = [:]
    private var loggedUnknown = Set<UInt32>()

    init(channel: any FsChannel) {
        self.channel = channel
    }

    var busy: Bool { !pending.isEmpty }

    // MARK: Requests

    func list(path: String, page: String?, completion: @escaping (Result<FsPage, FsError>) -> Void) {
        guard let id = freshID() else { return completion(.failure(FsError(code: "busy"))) }
        pending[id] = .list(completion)
        channel?.fsList(id: id, path: path, page: page)
    }

    func stat(path: String, completion: @escaping (Result<FsItem, FsError>) -> Void) {
        guard let id = freshID() else { return completion(.failure(FsError(code: "busy"))) }
        pending[id] = .stat(completion)
        channel?.fsStat(id: id, path: path)
    }

    /// Reads `length` bytes from `offset` into `url`. With `offset == nil` the
    /// whole file is read: a stat first learns its size.
    func read(path: String, offset: Int?, length: Int?, etag: String?, to url: URL,
              cancelAfterMs: Int? = nil,
              completion: @escaping (Result<FsReadResult, FsError>) -> Void) {
        guard let offset, let length else {
            stat(path: path) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let item):
                    guard !item.dir else { return completion(.failure(FsError(code: "fs_not_a_dir"))) }
                    self.read(path: path, offset: 0, length: item.size, etag: etag,
                              to: url, cancelAfterMs: cancelAfterMs, completion: completion)
                case .failure(let error):
                    completion(.failure(error))
                }
            }
            return
        }
        guard offset >= 0, length >= 0 else {
            return completion(.failure(FsError(code: "fs_denied", message: "bad range")))
        }
        guard let id = freshID() else { return completion(.failure(FsError(code: "busy"))) }
        let handle: FileHandle
        do {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
        } catch {
            return completion(.failure(FsError(code: "io", message: error.localizedDescription)))
        }
        let job = Read(path: path, url: url, expected: length, handle: handle, completion: completion)
        pending[id] = .read(job)
        if let cancelAfterMs {
            let timer = DispatchWorkItem { [weak self] in self?.cancel(id: id) }
            job.cancelTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(cancelAfterMs), execute: timer)
        }
        channel?.fsRead(id: id, path: path, offset: offset, length: length, etag: etag)
    }

    /// Abandons request `id`: no frames for it are accepted afterwards. A read
    /// removes its partial file and answers `cancelled`.
    func cancel(id: UInt32) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        channel?.fsCancel(id: id)
        guard case .read(let job) = entry else { return }
        job.cancelTimer?.cancel()
        job.handle.closeFile()
        try? FileManager.default.removeItem(at: job.url)
        finish(job, .failure(FsError(code: "cancelled")))
    }

    func cancelAll() {
        for id in Array(pending.keys) { cancel(id: id) }
    }

    // MARK: Responses

    func items(id: UInt32, page: String?, items: [[String: Any]]) {
        guard case .list(let completion)? = pending.removeValue(forKey: id) else {
            return unknown(id)
        }
        let parsed = items.compactMap(FsItem.init(json:))
        completion(.success(FsPage(items: parsed, next: page)))
    }

    func item(id: UInt32, item: [String: Any]) {
        guard case .stat(let completion)? = pending.removeValue(forKey: id) else {
            return unknown(id)
        }
        guard let parsed = FsItem(json: item) else {
            return completion(.failure(FsError(code: "protocol", message: "bad item")))
        }
        completion(.success(parsed))
    }

    func data(id: UInt32, bytes: [UInt8]) {
        guard case .read(let job)? = pending[id] else { return unknown(id) }
        guard !bytes.isEmpty else { return }
        job.received += bytes.count
        if job.received > job.expected {
            // More than the range announced: the file cannot be trusted.
            pending.removeValue(forKey: id)
            channel?.fsCancel(id: id)
            job.cancelTimer?.cancel()
            job.handle.closeFile()
            try? FileManager.default.removeItem(at: job.url)
            finish(job, .failure(FsError(code: "checksum", message: "more bytes than announced")))
            return
        }
        job.hasher.update(data: Data(bytes))
        do {
            try job.handle.write(contentsOf: Data(bytes))
        } catch {
            pending.removeValue(forKey: id)
            channel?.fsCancel(id: id)
            job.cancelTimer?.cancel()
            job.handle.closeFile()
            try? FileManager.default.removeItem(at: job.url)
            finish(job, .failure(FsError(code: "io", message: error.localizedDescription)))
        }
    }

    func readEnd(id: UInt32, size: Int, sha256: String) {
        guard case .read(let job)? = pending.removeValue(forKey: id) else {
            return unknown(id)
        }
        job.cancelTimer?.cancel()
        job.handle.closeFile()
        let digest = job.hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard size == job.received, size == job.expected else {
            try? FileManager.default.removeItem(at: job.url)
            return finish(job, .failure(FsError(code: "checksum", message: "size differs")))
        }
        guard digest == sha256.lowercased() else {
            try? FileManager.default.removeItem(at: job.url)
            return finish(job, .failure(FsError(code: "checksum", message: "sha256 differs")))
        }
        finish(job, .success(FsReadResult(bytes: job.received, sha256: digest)))
    }

    /// The phone refused request `id` (`fs_not_found`, `fs_stale`, …).
    func failure(id: UInt32, code: String, message: String?) {
        guard let entry = pending.removeValue(forKey: id) else { return unknown(id) }
        let error = FsError(code: code, message: message)
        switch entry {
        case .list(let completion): completion(.failure(error))
        case .stat(let completion): completion(.failure(error))
        case .read(let job):
            job.cancelTimer?.cancel()
            job.handle.closeFile()
            try? FileManager.default.removeItem(at: job.url)
            finish(job, .failure(error))
        }
    }

    /// The session went away: every request fails and partial files go.
    func connectionLost() {
        let open = pending
        pending.removeAll()
        for (_, entry) in open {
            let error = FsError(code: "closed", message: "the session ended")
            switch entry {
            case .list(let completion): completion(.failure(error))
            case .stat(let completion): completion(.failure(error))
            case .read(let job):
                job.cancelTimer?.cancel()
                job.handle.closeFile()
                try? FileManager.default.removeItem(at: job.url)
                finish(job, .failure(error))
            }
        }
    }

    // MARK: Internals

    private func finish(_ job: Read, _ result: Result<FsReadResult, FsError>) {
        let completion = job.completion
        job.completion = nil
        completion?(result)
    }

    private func unknown(_ id: UInt32) {
        if loggedUnknown.insert(id).inserted {
            Log.session.notice("fs: dropping frames for unknown id \(id, privacy: .public)")
        }
    }

    private func freshID() -> UInt32? {
        for _ in 0..<8 {
            let id = UInt32.random(in: 1...UInt32.max)
            if pending[id] == nil { return id }
        }
        return nil
    }
}
