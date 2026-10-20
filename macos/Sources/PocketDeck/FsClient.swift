// Client side of the phone files protocol (docs/PROTOCOL.md "Phone files",
// docs/design/files.md §3): list, stat, ranged reads, writes, move, delete,
// mkdir, setAttrs and cancel on the one session. A read streams FS_DATA into an
// output file or a consumer and only reports success when size and SHA-256
// match `fs.read.end`. A write goes the other way: the announced size and hash,
// then 256 KiB FS_DATA chunks paced like a drop (at most four in flight), and
// the phone answers `fs.result` once its temp is verified and renamed.
//
// The phone is stateless; this type keeps the pending request per id, and
// frames for an id it does not know (cancelled, or a phone that ran ahead) are
// dropped, like every other stream.

import CryptoKit
import Foundation

/// What the client needs from the session — the wire is a detail here.
protocol FsChannel: AnyObject {
    func fsList(id: UInt32, path: String, page: String?)
    func fsStat(id: UInt32, path: String)
    func fsRead(id: UInt32, path: String, offset: Int, length: Int, etag: String?)
    func fsWrite(id: UInt32, path: String, size: Int, sha256: String, etag: String?,
                 exclusive: Bool)
    func fsWriteData(id: UInt32, bytes: [UInt8], sent: @escaping @Sendable (Bool) -> Void)
    func fsMove(id: UInt32, from: String, to: String, etag: String?)
    func fsDelete(id: UInt32, path: String, recursive: Bool, etag: String?)
    func fsMkdir(id: UInt32, path: String)
    func fsSetAttrs(id: UInt32, path: String, mtime: Int)
    /// `fs.watch` / `fs.unwatch` (docs/PROTOCOL.md "Watching").
    func fsWatch(id: UInt32, paths: [String], on: Bool)
    func fsCancel(id: UInt32)
}

extension Session: FsChannel {}

/// One `fs.write` in flight. The bridge feeds it the extension's chunks; it
/// paces them onto the session, so the socket never holds more than 1 MiB and
/// at most four frames are in flight (the drop rule).
@MainActor
final class FsWrite: FilesWriteSink {
    /// The drop pacing (docs/design/files.md §3).
    static let chunkSize = 256 * 1024
    static let inFlightLimit = 4

    private let id: UInt32
    private let size: Int
    private weak var channel: (any FsChannel)?
    private var queue: [UInt8] = []
    private var queueOffset = 0
    private var inFlight = 0
    private var finished = false
    private var cancelled = false
    private var accepted = 0
    private let onProgress: (Int) -> Void
    private var completion: ((Result<FsItem, FsError>) -> Void)?

    init(id: UInt32, size: Int, channel: any FsChannel,
         onProgress: @escaping (Int) -> Void,
         completion: @escaping (Result<FsItem, FsError>) -> Void) {
        self.id = id
        self.size = size
        self.channel = channel
        self.onProgress = onProgress
        self.completion = completion
    }

    /// A chunk of the extension's bytes. False when the write is over (the
    /// bridge then stops reading the client's socket).
    func append(_ bytes: [UInt8]) -> Bool {
        guard !cancelled, !finished else { return false }
        guard accepted + bytes.count <= size else { return false }
        accepted += bytes.count
        queue.append(contentsOf: bytes)
        pump()
        return true
    }

    /// No more bytes will come; the phone's `fs.result` ends it.
    func finish() {
        finished = true
        // A zero-byte file has nothing to send and the phone already answered.
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        queue.removeAll()
        channel?.fsCancel(id: id)
        finish(.failure(FsError(code: "cancelled")))
    }

    /// The phone's confirmed bytes (fs.progress).
    func progress(_ bytes: Int) {
        onProgress(bytes)
    }

    /// The phone's answer (or a session end).
    func result(_ result: Result<FsItem, FsError>) {
        finish(result)
    }

    private func finish(_ result: Result<FsItem, FsError>) {
        queue.removeAll()
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }

    private func pump() {
        guard !cancelled else { return }
        while inFlight < Self.inFlightLimit, queueOffset < queue.count {
            let take = min(Self.chunkSize, queue.count - queueOffset)
            let chunk = Array(queue[queueOffset..<(queueOffset + take)])
            queueOffset += take
            if queueOffset > 4 * Self.chunkSize {
                queue.removeFirst(queueOffset)
                queueOffset = 0
            }
            inFlight += 1
            channel?.fsWriteData(id: id, bytes: chunk) { [weak self] ok in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.sent(count: take, ok: ok) }
                } else {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.sent(count: take, ok: ok) }
                    }
                }
            }
        }
    }

    private func sent(count: Int, ok: Bool) {
        inFlight -= 1
        guard ok else {
            // The session went away; FsClient's connectionLost answers too, but
            // this is the frame that noticed.
            cancelled = true
            finish(.failure(FsError(code: "closed", message: "the session ended")))
            return
        }
        pump()
    }
}

@MainActor
final class FsClient {
    private enum Pending {
        case list((Result<FsPage, FsError>) -> Void)
        case stat((Result<FsItem, FsError>) -> Void)
        case read(Read)
        case write(FsWrite)
        case mutation((Result<FsItem?, FsError>) -> Void)
    }

    /// A read's destination: a temporary file (FsDebug and the e2e checks) or a
    /// consumer that forwards each chunk (the bridge, which streams to the
    /// extension). The consumer returns false when it can no longer take bytes.
    private enum ReadSink {
        case file(FileHandle, URL)
        case stream(([UInt8]) -> Bool)
    }

    private final class Read {
        let path: String
        let expected: Int
        let sink: ReadSink
        var received = 0
        var hasher = SHA256()
        var cancelTimer: DispatchWorkItem?
        var completion: ((Result<FsReadResult, FsError>) -> Void)?

        init(path: String, expected: Int, sink: ReadSink,
             completion: @escaping (Result<FsReadResult, FsError>) -> Void) {
            self.path = path
            self.expected = expected
            self.sink = sink
            self.completion = completion
        }

        /// Removes a partial file; a stream has nothing to remove.
        func discard() {
            if case .file(let handle, let url) = sink {
                handle.closeFile()
                try? FileManager.default.removeItem(at: url)
            }
        }

        /// Writes one chunk; an error means the destination is gone.
        func write(_ bytes: [UInt8]) -> FsError? {
            switch sink {
            case .file(let handle, _):
                do {
                    try handle.write(contentsOf: Data(bytes))
                    return nil
                } catch {
                    return FsError(code: "io", message: error.localizedDescription)
                }
            case .stream(let consume):
                return consume(bytes) ? nil
                    : FsError(code: "cancelled", message: "the destination went away")
            }
        }
    }

    private weak var channel: (any FsChannel)?
    private var pending: [UInt32: Pending] = [:]
    /// A watched folder moved on the phone: the app re-lists and diffs it
    /// (docs/design/files.md §5). Set by the connection once the bridge serves.
    var onChanges: (([String]) -> Void)?
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
        let job = Read(path: path, expected: length, sink: .file(handle, url), completion: completion)
        pending[id] = .read(job)
        if let cancelAfterMs {
            let timer = DispatchWorkItem { [weak self] in self?.cancel(id: id) }
            job.cancelTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(cancelAfterMs), execute: timer)
        }
        channel?.fsRead(id: id, path: path, offset: offset, length: length, etag: etag)
    }

    /// Reads into a consumer instead of a file: every FS_DATA chunk is handed
    /// to `chunk` as it arrives, so the bridge can stream it to the extension
    /// while the phone is still sending. `onStart` carries the phone-level id,
    /// which is what `cancel(fsID:)` takes. A chunk that returns false stops the
    /// read (fs.cancel goes out, the partial data is gone).
    func streamRead(path: String, offset: Int, length: Int, etag: String?,
                    onStart: @escaping (UInt32) -> Void,
                    chunk: @escaping ([UInt8]) -> Bool,
                    completion: @escaping (Result<FsReadResult, FsError>) -> Void) {
        guard offset >= 0, length >= 0 else {
            return completion(.failure(FsError(code: "fs_denied", message: "bad range")))
        }
        guard let id = freshID() else { return completion(.failure(FsError(code: "busy"))) }
        let job = Read(path: path, expected: length, sink: .stream(chunk), completion: completion)
        pending[id] = .read(job)
        onStart(id)
        channel?.fsRead(id: id, path: path, offset: offset, length: length, etag: etag)
    }

    /// Starts `fs.write` and returns the handle the bridge feeds. The phone
    /// answers `fs.result` (or an `error`) through [result]/[failure].
    /// `exclusive` is a create: the phone refuses a name that is already there
    /// instead of replacing it.
    func beginWrite(path: String, size: Int, sha256: String, etag: String?,
                    exclusive: Bool = false,
                    progress: @escaping (Int) -> Void = { _ in },
                    completion: @escaping (Result<FsItem, FsError>) -> Void) -> FilesWriteSink? {
        guard let channel else {
            completion(.failure(FsError(code: "offline")))
            return nil
        }
        guard let id = freshID() else {
            completion(.failure(FsError(code: "busy")))
            return nil
        }
        let job = FsWrite(id: id, size: size, channel: channel, onProgress: progress,
                          completion: completion)
        pending[id] = .write(job)
        channel.fsWrite(id: id, path: path, size: size, sha256: sha256, etag: etag,
                        exclusive: exclusive)
        return job
    }

    func move(from: String, to: String, etag: String?,
              completion: @escaping (Result<FsItem?, FsError>) -> Void) {
        mutate(completion) { channel, id in
            channel.fsMove(id: id, from: from, to: to, etag: etag)
        }
    }

    func delete(path: String, recursive: Bool, etag: String?,
                completion: @escaping (Result<FsItem?, FsError>) -> Void) {
        mutate(completion) { channel, id in
            channel.fsDelete(id: id, path: path, recursive: recursive, etag: etag)
        }
    }

    func mkdir(path: String, completion: @escaping (Result<FsItem?, FsError>) -> Void) {
        mutate(completion) { channel, id in channel.fsMkdir(id: id, path: path) }
    }

    /// Adds or removes folders the Mac has open. The phone answers `fs.result`
    /// like any other mutation.
    func watch(paths: [String], on: Bool,
               completion: @escaping (Result<Void, FsError>) -> Void) {
        guard let id = freshID() else { return completion(.failure(FsError(code: "busy"))) }
        pending[id] = .mutation { result in
            completion(result.map { _ in () })
        }
        channel?.fsWatch(id: id, paths: paths, on: on)
    }

    /// The phone's `fs.changes`.
    func changes(paths: [String]) {
        onChanges?(paths)
    }

    func setAttrs(path: String, mtime: Int,
                  completion: @escaping (Result<FsItem?, FsError>) -> Void) {
        mutate(completion) { channel, id in
            channel.fsSetAttrs(id: id, path: path, mtime: mtime)
        }
    }

    /// A mutation answers `fs.result` with the item (or no item for a delete).
    private func mutate(_ completion: @escaping (Result<FsItem?, FsError>) -> Void,
                        _ send: (any FsChannel, UInt32) -> Void) {
        guard let channel else { return completion(.failure(FsError(code: "offline"))) }
        guard let id = freshID() else { return completion(.failure(FsError(code: "busy"))) }
        pending[id] = .mutation(completion)
        send(channel, id)
    }

    /// Abandons request `id`: no frames for it are accepted afterwards. A read
    /// removes its partial file and answers `cancelled`.
    func cancel(id: UInt32) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        channel?.fsCancel(id: id)
        switch entry {
        case .read(let job):
            job.cancelTimer?.cancel()
            job.discard()
            finish(job, .failure(FsError(code: "cancelled")))
        case .write(let job):
            job.cancel()
        case .list(let completion): completion(.failure(FsError(code: "cancelled")))
        case .stat(let completion): completion(.failure(FsError(code: "cancelled")))
        case .mutation(let completion): completion(.failure(FsError(code: "cancelled")))
        }
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
            job.discard()
            finish(job, .failure(FsError(code: "checksum", message: "more bytes than announced")))
            return
        }
        job.hasher.update(data: Data(bytes))
        if let error = job.write(bytes) {
            pending.removeValue(forKey: id)
            channel?.fsCancel(id: id)
            job.cancelTimer?.cancel()
            job.discard()
            finish(job, .failure(error))
        }
    }

    func readEnd(id: UInt32, size: Int, sha256: String) {
        guard case .read(let job)? = pending.removeValue(forKey: id) else {
            return unknown(id)
        }
        job.cancelTimer?.cancel()
        let digest = job.hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard size == job.received, size == job.expected else {
            job.discard()
            return finish(job, .failure(FsError(code: "checksum", message: "size differs")))
        }
        guard digest == sha256.lowercased() else {
            job.discard()
            return finish(job, .failure(FsError(code: "checksum", message: "sha256 differs")))
        }
        // A file read is complete here; a stream still holds no resource.
        if case .file(let handle, _) = job.sink { handle.closeFile() }
        finish(job, .success(FsReadResult(bytes: job.received, sha256: digest)))
    }

    /// `fs.progress`: the phone's confirmed bytes, at most four a second.
    func progress(id: UInt32, bytes: Int) {
        guard case .write(let job)? = pending[id] else { return }
        job.progress(bytes)
    }

    /// `fs.result`: the write or mutation is done.
    func result(id: UInt32, ok: Bool, item: [String: Any]?, code: String?, message: String?) {
        guard let entry = pending.removeValue(forKey: id) else { return unknown(id) }
        let error = FsError(code: code ?? "protocol", message: message)
        switch entry {
        case .write(let job):
            guard ok else { return job.result(.failure(error)) }
            guard let item, let parsed = FsItem(json: item) else {
                return job.result(.failure(FsError(code: "protocol", message: "bad item")))
            }
            job.result(.success(parsed))
        case .mutation(let completion):
            guard ok else { return completion(.failure(error)) }
            completion(.success(item.flatMap(FsItem.init(json:))))
        case .list(let completion): completion(.failure(error))
        case .stat(let completion): completion(.failure(error))
        case .read(let job):
            job.discard()
            finish(job, .failure(error))
        }
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
            job.discard()
            finish(job, .failure(error))
        case .write(let job): job.result(.failure(error))
        case .mutation(let completion): completion(.failure(error))
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
                job.discard()
                finish(job, .failure(error))
            case .write(let job): job.result(.failure(error))
            case .mutation(let completion): completion(.failure(error))
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
