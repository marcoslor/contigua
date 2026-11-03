// File drops off a Finder drag (docs/design/dragdrop.md): one file at a time
// streams to the phone's Downloads/PocketDeck as `drop.start` + DROP_DATA
// chunks. The flow waits for the phone's opening `drop.progress` before data
// goes out (it carries the resume offset the phone verified), paces chunks on
// their completion like the APK installer, and stops when the person asks.

import AppKit
import CryptoKit
import Foundation

/// What one dropped URL becomes on the wire: name, mime, size and hash.
struct PreparedDrop: Sendable {
    var url: URL
    var name: String
    var mime: String
    var size: Int
    var sha256: String
}

/// The phone's own rules for `name` (docs/design/dragdrop.md "Names"), applied
/// before the announcement so the Mac and the phone agree on what arrives.
enum DropName {
    static let maxLength = 100

    struct Name: Sendable, Equatable {
        var stem: String
        var ext: String
        var file: String { ext.isEmpty ? stem : "\(stem).\(ext)" }
    }

    /// `[A-Za-z0-9 ._-]`, no leading dot, ≤ 100 chars, extension from the mime
    /// when the name has none — the share-in receiver's rules, Mac side.
    static func sanitize(_ raw: String, mime: String) -> Name {
        func clean(_ part: String) -> String {
            let kept = part.filter {
                $0.isASCII && ($0.isLetter || $0.isNumber) || " ._-".contains($0)
            }.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return kept
        }
        let last = raw.split { $0 == "/" || $0 == "\\" }.last.map(String.init) ?? "file"
        var stem = clean(last)
        var ext = ""
        if let dot = last.lastIndex(of: "."), last.distance(from: dot, to: last.endIndex) <= 7 {
            stem = clean(String(last[..<dot]))
            ext = clean(String(last[last.index(after: dot)...])).lowercased()
        }
        if ext.isEmpty, let fromMime = mimeAndExtension[mime.lowercased()] { ext = fromMime }
        if stem.isEmpty { stem = "file" }
        let room = maxLength - (ext.isEmpty ? 0 : ext.count + 1)
        stem = String(stem.prefix(room)).trimmingCharacters(in: .whitespaces)
        if stem.isEmpty { stem = "file" }
        return Name(stem: stem, ext: ext)
    }

    private static let mimeAndExtension: [String: String] = [
        "application/pdf": "pdf", "text/plain": "txt", "application/zip": "zip",
        "image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/webp": "webp",
        "video/mp4": "mp4", "audio/mpeg": "mp3",
        "application/vnd.android.package-archive": "apk",
    ]
}

/// Counts and hashes a queue of dropped URLs off the main thread.
enum DropPreparation {
    static func prepare(_ urls: [URL]) throws -> [PreparedDrop] {
        try urls.map { url in
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            defer { try? handle.close() }
            let size = Int(try handle.seekToEnd())
            let mime = mimeGuess(fromURL: url)
            var hash = SHA256()
            try handle.seek(toOffset: 0)
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
            let name = DropName.sanitize(url.lastPathComponent, mime: mime).file
            return PreparedDrop(url: url, name: name, mime: mime, size: size,
                                sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
        }
    }

    /// A content-type guess from the extension (mimes are for the SEND chooser).
    private static func mimeGuess(fromURL url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "mp4": return "video/mp4"
        case "mp3": return "audio/mpeg"
        case "zip": return "application/zip"
        case "txt", "md", "log": return "text/plain"
        case "apk": return "application/vnd.android.package-archive"
        default: return "application/octet-stream"
        }
    }
}

/// The wire's caps (docs/PROTOCOL.md "Drop Mac → phone").
enum DropLimits {
    static let maxBytes = 200 * 1024 * 1024
    static var maxMegabytes: Int { maxBytes / (1024 * 1024) }
    /// Tests shorten the cap instead of writing a 200 MB file.
    static var testCap: Int?
    /// The cap checks read this, so a test's small file can be "too large".
    static var current: Int { testCap ?? maxBytes }
}

/// What the sender needs from a session — the wire is a detail here.
protocol DropChannel: AnyObject {
    func dropStart(id: UInt32, name: String, mime: String, size: Int, sha256: String,
                   resume: Int, target: String?, index: Int, count: Int)
    func cancelDrop(id: UInt32)
    func sendDropData(id: UInt32, bytes: [UInt8], sent: @escaping @Sendable (Bool) -> Void)
}

extension Session: DropChannel {}

/// One drop at a time; the stream windows show its phase as a pill.
@MainActor
@Observable
final class FileDropSender {
    enum Phase: Equatable {
        case idle
        /// The file in flight; `fraction` is the phone's confirmed bytes.
        case sending(String, fraction: Double)
        case finished(String, ok: Bool)
    }

    /// Why a drop ended, for the log: a closed set of ours, or the phone's own
    /// error code (a protocol identifier). Never a file name, so the line stays
    /// public (CONV-PD-05).
    enum Outcome: Equatable {
        case saved
        case busy
        case checksum
        case cancelled
        case tooLarge
        case overCap
        case nothing
        case offline
        case unreadable
        case inFlight
        /// The phone's `drop.result` code, a closed protocol value.
        case phone(String)

        var kind: String {
            switch self {
            case .saved: return "saved"
            case .busy: return "busy"
            case .checksum: return "checksum"
            case .cancelled: return "cancelled"
            case .tooLarge: return "too_large"
            case .overCap: return "over_cap"
            case .nothing: return "nothing"
            case .offline: return "offline"
            case .unreadable: return "unreadable"
            case .inFlight: return "in_flight"
            case .phone(let code): return code
            }
        }
    }

    private(set) var phase: Phase = .idle
    var isBusy: Bool { if case .sending = phase { true } else { false } }

    /// Every phase change, the outcome's timeout included: the pill's owner is
    /// this sender, so nothing else schedules a hide.
    @ObservationIgnored var onPhase: ((Phase) -> Void)?
    /// The gesture is over (saved, refused, cancelled or lost): a source's temp
    /// folder can go. Not called while a batch moves to its next file.
    @ObservationIgnored var onSettled: (() -> Void)?

    /// How long an outcome stays up, and the sleep it waits on (a test's own).
    private let finishedHold: Duration
    private let sleep: @Sendable (Duration) async -> Void

    init(finishedHold: Duration = .seconds(5),
         sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.finishedHold = finishedHold
        self.sleep = sleep
    }

    private func setPhase(_ next: Phase) {
        phase = next
        onPhase?(next)
    }

    /// Frames are ≤ 1 MiB on the wire; smaller chunks keep input responsive.
    static let chunkSize = 256 * 1024
    private static let inFlightLimit = 4

    private weak var session: (any DropChannel)?
    private var queue: [PreparedDrop] = []
    private var current: PreparedDrop?
    private var id: UInt32 = 0
    private var reader: FileHandle?
    /// What the phone has confirmed so far (its opening progress may resume).
    private var offset = 0
    /// The next byte to read. Only the phone's opening progress may move it (a
    /// resume); after that it follows the reads, so a late progress can never
    /// send a byte twice.
    private var cursor = 0
    /// Between `drop.start` and the phone's opening progress no chunk is sent.
    private var awaitingOffset = false
    private var inFlight = 0
    private var cancelled = false
    private var clearTask: Task<Void, Never>?
    /// A transfer that died with the connection: the phone kept a temp, so a
    /// re-drag of a file with this sha resumes at (bytes) for this long.
    private var resumeHints: [String: (bytes: Int, until: Date)] = [:]
    /// The app window the batch is for; nil for the Deck and a phone window.
    private var target: String?
    /// How many files this gesture carries, for the batch fields.
    private var batchCount = 0

    /// A second drop while one runs: keep the running pill and its transfer.
    func busy() {
        finish("The phone is still taking a file.", ok: false, outcome: .inFlight, keepState: true)
    }

    /// A source that never became files (SHARE-18): the same pill, the same
    /// five-second hide, and a closed outcome token for the log.
    func refuse(_ text: String, outcome: Outcome = .nothing) {
        finish(text, ok: false, outcome: outcome)
    }

    func send(_ urls: [URL], session: any DropChannel, target: String? = nil) {
        guard !isBusy else { return busy() }
        clearTask?.cancel()
        self.session = session
        self.target = target
        cancelled = false
        setPhase(.sending("", fraction: 0))
        Task.detached(priority: .userInitiated) { [weak self] in
            let prepared = Result { try DropPreparation.prepare(urls) }
            await MainActor.run { self?.begin(prepared) }
        }
    }

    private func begin(_ prepared: Result<[PreparedDrop], Error>) {
        switch prepared {
        case .failure(let error):
            finish("Couldn't read those files: \(error.localizedDescription)", ok: false, outcome: .unreadable)
        case .success(let drops):
            guard !drops.isEmpty, let session else {
                return finish("Nothing to send.", ok: false, outcome: .nothing)
            }
            if let big = drops.first(where: { $0.size <= 0 || $0.size > DropLimits.current }) {
                let why = big.size <= 0 ? "is empty" : "is bigger than the phone's \(DropLimits.maxMegabytes) MB cap"
                return finish("\(big.name) \(why), nothing was sent.", ok: false, outcome: .overCap)
            }
            queue = drops
            batchCount = drops.count
            next()
        }
    }

    /// Streams the next queued file.
    private func next() {
        guard let next = queue.first else { return }
        guard let session else { return fail("Lost the connection to the phone.") }
        current = next
        queue.removeFirst()
        id = UInt32.random(in: 1...UInt32.max)
        offset = 0
        cursor = 0
        let resume = self.resume(sha256: next.sha256)
        // The size is the fact a person can check; the name is theirs and stays
        // out of the log (CONV-PD-05, R-PRIV-1).
        Log.app.notice("drop: sending \(next.size, privacy: .public) bytes\(resume > 0 ? ", resuming" : "")")
        setPhase(.sending(next.name, fraction: resume > 0 ? Double(resume) / Double(next.size) : 0))
        awaitingOffset = true
        session.dropStart(id: id, name: next.name, mime: next.mime, size: next.size,
                          sha256: next.sha256, resume: resume, target: target,
                          index: batchCount - queue.count, count: batchCount)
    }

    private func resume(sha256: String) -> Int {
        guard let hint = resumeHints[sha256], hint.until > Date() else { return 0 }
        resumeHints.removeValue(forKey: sha256)
        return hint.bytes
    }

    /// Keeps at most [inFlightLimit] chunks queued on the connection.
    private func pump() {
        guard case .sending = phase, !cancelled, !awaitingOffset,
              let session, let current else { return }
        while inFlight < Self.inFlightLimit && cursor < current.size {
            if reader == nil {
                reader = try? FileHandle(forReadingFrom: current.url)
                try? reader?.seek(toOffset: UInt64(cursor))
            }
            let chunk = (try? reader?.read(upToCount: Self.chunkSize)) ?? nil
            guard let chunk, !chunk.isEmpty else {
                try? reader?.close()
                reader = nil
                break
            }
            cursor += chunk.count
            inFlight += 1
            let id = self.id
            session.sendDropData(id: id, bytes: [UInt8](chunk)) { [weak self] ok in
                Task { @MainActor in
                    guard let self, id == self.id else { return }
                    self.inFlight -= 1
                    if ok { self.pump() } else { self.failNow("Lost the connection to the phone.") }
                }
            }
        }
    }

    func cancel() {
        guard isBusy else { return }
        cancelled = true
        if id != 0 { session?.cancelDrop(id: id) }
        finish("Transfer cancelled.", ok: false, outcome: .cancelled)
    }

    /// The phone's confirmed byte count: the fraction the pill shows. The
    /// opening progress is the only one that can seek (the phone's resume
    /// offset); later ones are behind the wire and must not re-read anything.
    func progress(id: UInt32, bytes: Int) {
        guard id == self.id, let current, current.size > 0 else { return }
        let confirmed = min(max(bytes, 0), current.size)
        if awaitingOffset {
            awaitingOffset = false
            cursor = confirmed
            offset = confirmed
            try? reader?.close()
            reader = nil
        } else {
            offset = max(offset, confirmed)
        }
        if case .sending = phase { setPhase(.sending(current.name, fraction: Double(offset) / Double(current.size))) }
        pump()
    }

    /// The phone's one answer per drop.
    func result(_ result: DropResult) {
        guard result.id == id else { return }
        id = 0
        try? reader?.close()
        reader = nil
        current = nil
        if result.ok, let path = result.path {
            let name = path.split(separator: "/").last.map(String.init) ?? ""
            if queue.isEmpty {
                // One gesture is one pill: a batch says how many files landed,
                // not the name of its last file (>5 are saved, never shared).
                let text = batchCount > 1 ? "Saved \(batchCount) files on the phone."
                                          : "Saved on the phone: \(name)"
                finish(text, ok: true, outcome: .saved)
            } else {
                finish("Saved \(name), sending the next file…", ok: true, outcome: .saved, keepState: true)
                next()
            }
        } else {
            switch result.code {
            case "busy": finish("The phone is busy with another file.", ok: false, outcome: .busy)
            case "checksum": finish("The phone could not verify that file.", ok: false, outcome: .checksum)
            case "cancelled": finish("Cancelled.", ok: false, outcome: .cancelled)
            case "too_large":
                finish("The phone refused it: \(result.message ?? "too large").", ok: false, outcome: .tooLarge)
            default:
                finish("The phone refused it: \(result.message ?? result.code ?? "failed").", ok: false,
                       outcome: .phone(result.code ?? "refused"))
            }
        }
    }

    /// The connection went away mid-transfer; the phone keeps its temp for a resume.
    func connectionLost() {
        guard isBusy, let current else { return }
        if offset > 0 {
            resumeHints[current.sha256] = (offset, Date().addingTimeInterval(Self.resumeLifetime))
        }
        fail("Lost the connection; drop that file again to resume.", keepTemp: true)
    }

    private static let resumeLifetime: TimeInterval = 600

    private func fail(_ text: String, outcome: Outcome = .offline, keepTemp: Bool = false) {
        if id != 0, !cancelled, !keepTemp { session?.cancelDrop(id: id) }
        cancelled = true
        finish(text, ok: false, outcome: outcome)
    }

    private func failNow(_ text: String) {
        if id != 0 { session?.cancelDrop(id: id) }
        cancelled = true
        finish(text, ok: false, outcome: .offline)
    }

    private func finish(_ text: String, ok: Bool, outcome: Outcome, keepState: Bool = false) {
        // The sentence names a file and stays private; the outcome is a closed
        // token and is what the e2e reads (the privacy pass must not hide it).
        Log.app.notice("drop: \(ok ? "ok" : "failed", privacy: .public): \(outcome.kind, privacy: .public)")
        if keepState { return }
        queue = []
        current = nil
        target = nil
        batchCount = 0
        try? reader?.close()
        reader = nil
        id = 0
        inFlight = 0
        offset = 0
        cursor = 0
        // A previous outcome's five seconds must not hide this one (a source
        // refusal can land as the last transfer's timer fires).
        clearTask?.cancel()
        setPhase(.finished(text, ok: ok))
        onSettled?()
        clearTask = Task { [weak self] in
            guard let self else { return }
            await self.sleep(self.finishedHold)
            guard !Task.isCancelled else { return }
            self.setPhase(.idle)
        }
    }
}
