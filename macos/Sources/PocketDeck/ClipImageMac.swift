// The phone's clipboard images on the Mac (docs/design/dragdrop.md): the
// `clip.image.start` / `clip.image.*` assembly on this side — a hard-capped
// in-memory buffer of 8 MiB, a SHA-256 check, and a pasteboard writer that is
// the ClipboardSync's (so the echo rule applies there, not here).

import AppKit
import CryptoKit
import Foundation

enum ClipImagePolicy {
    static let maxBytes = 8 * 1024 * 1024
    static let chunkSize = 256 * 1024

    /// PNG and JPEG go through unchanged; the phone may offer both.
    static func valid(mime: String) -> Bool {
        mime == "image/png" || mime == "image/jpeg"
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Assembles one image at a time from `clip.image.*` messages.
final class ClipImageBuffer {
    private var mime = ""
    private var expected = 0
    private var data = Data()
    private var hasher = SHA256()

    /// False when the announcement is junk or over the cap: the transfer is not started.
    @discardableResult
    func begin(id: UInt32, mime: String, size: Int) -> Bool {
        guard id != 0, size > 0, size <= ClipImagePolicy.maxBytes, ClipImagePolicy.valid(mime: mime) else {
            Log.app.info("clip.image.start ignored (id \(id), mime \(mime, privacy: .public), size \(size))")
            discard()
            return false
        }
        self.mime = mime
        expected = size
        data = Data(capacity: size)
        hasher = SHA256()
        return true
    }

    @discardableResult
    func data(id: UInt32, bytes: [UInt8]) -> Bool {
        guard data.count + bytes.count <= expected else {
            Log.app.info("clip.image.data: more bytes than announced")
            discard()
            return false
        }
        hasher.update(data: bytes)
        data.append(contentsOf: bytes)
        return true
    }

    /// The finished image, or nil on a mismatch.
    func end(id: UInt32, size: Int, sha256: String) -> (data: Data, mime: String)? {
        let image = data
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let mime = self.mime
        discard()
        guard image.count == size, digest == sha256.lowercased() else {
            Log.app.info("clip.image.end: checksum failed (\(image.count)/\(size))")
            return nil
        }
        return (image, mime)
    }

    func discard() {
        data = Data()
        expected = 0
        mime = ""
    }
}

/// Mac → phone clipboard images: one start, chunked `clip.image`_DATA, one end.
/// The bytes never sit in the send queue (limits: 8 MiB, NW buffers take them).
enum ClipImageSend {
    static func run(_ data: Data, mime: String, session: Session) {
        guard ClipImagePolicy.valid(mime: mime), data.count <= ClipImagePolicy.maxBytes, !data.isEmpty else {
            Log.app.info("clip.image: not sending \(data.count) bytes (\(mime, privacy: .public))")
            return
        }
        let id = Self.nextId()
        session.clipImageStart(id: id, mime: mime, size: data.count)
        let sha = ClipImagePolicy.sha256(data)
        let bytes = [UInt8](data)
        // Frames are already ordered by NWConnection; the phone's bulk cap is
        // theirs to report, the sizes here are the point.
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + ClipImagePolicy.chunkSize, bytes.count)
            session.sendClipData(id: id, bytes: Array(bytes[offset..<end])) { _ in }
            offset = end
        }
        session.clipImageEnd(id: id, size: bytes.count, sha256: sha)
        Log.app.notice("clip.image: sent \(bytes.count) bytes (\(mime, privacy: .public))")
    }

    private static func nextId() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return counter
    }

    private static let lock = NSLock()
    private static var counter: UInt32 = 0
}
