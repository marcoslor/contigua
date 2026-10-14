// APK install from the Mac (docs/design/apk.md): prepares a dropped file's parts,
// streams them to the phone in APK_DATA frames and turns the reply into a sentence.

import AppKit
import CryptoKit
import Foundation

/// A part ready to stream: a plain name, the file holding it, its size and SHA-256.
struct PreparedApkPart: Sendable {
    var name: String
    var file: URL
    var size: Int
    var sha256: String
}

enum ApkPreparation {
    /// Parts of `url` in a fresh 0700 folder (only zip entries are copied there; a plain
    /// .apk streams from where it is). The caller deletes `folder` when done.
    static func prepare(_ url: URL) throws -> (parts: [PreparedApkPart], folder: URL) {
        let (bundle, archive) = try ApkBundle.open(url)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pocketdeck-apk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            let parts = try bundle.parts.map { part -> PreparedApkPart in
                guard let name = part.entry, let entry = archive.entries.first(where: { $0.name == name }) else {
                    return PreparedApkPart(name: part.name, file: url, size: part.size, sha256: try sha256(of: url))
                }
                let file = folder.appendingPathComponent(part.name)
                let sha = try archive.extract(entry, to: file)
                return PreparedApkPart(name: part.name, file: file, size: entry.size, sha256: sha)
            }
            return (parts, folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    static func sha256(of file: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw ApkBundleError.unreadable }
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// One install at a time; the Deck shows its phase.
@MainActor
@Observable
final class ApkInstaller {
    enum Phase: Equatable {
        case idle
        case preparing(String)
        /// Sending: `fraction` is what the phone has written into its install session.
        case sending(String, fraction: Double)
        case installing(String)
        case finished(String, ok: Bool)
    }

    private(set) var phase: Phase = .idle
    var isBusy: Bool {
        switch phase {
        case .preparing, .sending, .installing: true
        case .idle, .finished: false
        }
    }

    /// Frames are ≤ 1 MiB on the wire; smaller chunks keep input and video responsive.
    static let chunkSize = 256 * 1024
    private static let inFlightLimit = 4

    private weak var session: Session?
    private var id: UInt32 = 0
    private var displayName = ""
    private var parts: [PreparedApkPart] = []
    private var folder: URL?
    private var total = 0
    private var partIndex = 0
    private var reader: FileHandle?
    private var inFlight = 0
    private var cancelled = false
    private var clearTask: Task<Void, Never>?
    /// Called after a successful install (the app list is refreshed so the icon shows).
    var onInstalled: (() -> Void)?

    func install(_ url: URL, session: Session) {
        guard !isBusy else {
            finish("Wait for the current install to finish.", ok: false, keepState: true)
            return
        }
        clearTask?.cancel()
        displayName = url.deletingPathExtension().lastPathComponent
        phase = .preparing(displayName)
        Log.app.notice("apk: preparing \(url.lastPathComponent, privacy: .public)")
        self.session = session
        Task.detached(priority: .userInitiated) {
            let result = Result { try ApkPreparation.prepare(url) }
            await MainActor.run { self.start(result) }
        }
    }

    private func start(_ result: Result<(parts: [PreparedApkPart], folder: URL), Error>) {
        switch result {
        case .failure(let error):
            finish((error as? ApkBundleError)?.message ?? ApkBundleError.unreadable.message, ok: false)
        case .success(let prepared):
            guard let session else { return finish("Lost the connection to the phone.", ok: false) }
            parts = prepared.parts
            folder = prepared.folder
            total = parts.reduce(0) { $0 + $1.size }
            id = UInt32.random(in: 1...UInt32.max)
            partIndex = 0
            cancelled = false
            phase = .sending(displayName, fraction: 0)
            Log.app.notice("apk: sending \(self.parts.count, privacy: .public) part(s), \(self.total, privacy: .public) bytes")
            session.installApk(id: id, files: parts.map { ["name": $0.name, "size": $0.size, "sha256": $0.sha256] })
            pump()
        }
    }

    /// Keeps up to `inFlightLimit` chunks queued on the connection.
    private func pump() {
        guard case .sending = phase, !cancelled, let session else { return }
        while inFlight < Self.inFlightLimit {
            if reader == nil {
                guard partIndex < parts.count else { return }
                reader = try? FileHandle(forReadingFrom: parts[partIndex].file)
                if reader == nil { return fail("Couldn't read that file.") }
            }
            let chunk = (try? reader?.read(upToCount: Self.chunkSize)) ?? nil
            guard let chunk, !chunk.isEmpty else {
                try? reader?.close()
                reader = nil
                partIndex += 1
                continue
            }
            inFlight += 1
            let id = self.id
            session.sendApkData(id: id, bytes: [UInt8](chunk)) { ok in
                Task { @MainActor in self.sent(id: id, ok: ok) }
            }
        }
    }

    private func sent(id: UInt32, ok: Bool) {
        guard id == self.id else { return }
        inFlight -= 1
        if !ok { return fail("Lost the connection to the phone.") }
        pump()
    }

    func cancel() {
        guard isBusy else { return }
        cancelled = true
        if id != 0 { session?.cancelApk(id: id) }
        if case .preparing = phase { finish("Install cancelled.", ok: false) }
    }

    func progress(id: UInt32, bytes: Int) {
        guard id == self.id, total > 0 else { return }
        if bytes >= total {
            phase = .installing(displayName)
            Log.app.notice("apk: phone received all \(bytes, privacy: .public) bytes, installing")
        } else if case .sending = phase {
            phase = .sending(displayName, fraction: Double(bytes) / Double(total))
            Log.app.notice("apk: progress \(bytes, privacy: .public)/\(self.total, privacy: .public)")
        }
    }

    func result(_ result: ApkResult) {
        guard result.id == id else { return }
        if result.ok {
            finish(ApkInstallMessage.success(label: result.label, version: result.version), ok: true)
            onInstalled?()
        } else {
            finish(ApkInstallMessage.failure(code: result.code ?? "failed", detail: result.message), ok: false)
        }
    }

    /// The session went away mid-install.
    func connectionLost() {
        if isBusy { fail("Lost the connection to the phone.") }
    }

    /// A Mac-side failure: tell the phone to abandon, then report.
    private func fail(_ text: String) {
        if id != 0, !cancelled { session?.cancelApk(id: id) }
        cancelled = true
        finish(text, ok: false)
    }

    private func finish(_ text: String, ok: Bool, keepState: Bool = false) {
        Log.app.notice("apk: result \(ok ? "ok" : "failed", privacy: .public): \(text, privacy: .public)")
        if keepState { return }
        try? reader?.close()
        reader = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
        parts = []
        id = 0
        inFlight = 0
        phase = .finished(text, ok: ok)
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.phase = .idle
        }
    }

    func dismiss() {
        clearTask?.cancel()
        if !isBusy { phase = .idle }
    }
}
