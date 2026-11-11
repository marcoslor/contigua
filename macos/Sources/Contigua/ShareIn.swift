// Share phone → Mac (docs/design/sharein.md): `share.text` opens a web link or
// lands on the clipboard; `share.file` + SHARE_DATA + `share.end` saves an image to
// ~/Downloads/Contigua and puts it on the clipboard. The phone is not trusted:
// only http/https links are ever opened, everything else becomes text.

import AppKit
import CryptoKit
import Foundation
import UserNotifications

/// What a shared text turned out to be.
enum SharedText: Equatable {
    case link(URL)
    case text(String)
}

enum ShareInPolicy {
    static let maxTextBytes = 1_048_576
    static let maxFileBytes = 52_428_800

    /// A link when the trimmed text is one http(s) URL or holds exactly one among other
    /// words; any other scheme (file:, javascript:, intent:, custom) stays text.
    /// nil for empty or oversized text.
    static func classify(_ raw: String) -> SharedText? {
        let bytes = raw.utf8.count
        guard bytes > 0, bytes <= maxTextBytes else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidates = trimmed.split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "()<>[]\"'.,;:!?")) }
            .filter { $0.lowercased().hasPrefix("http://") || $0.lowercased().hasPrefix("https://") }
        if candidates.count == 1, let url = webURL(candidates[0]) { return .link(url) }
        return .text(raw)
    }

    /// An http/https URL with a host that `LinkPolicy` accepts, else nil.
    static func webURL(_ raw: String) -> URL? {
        guard let valid = LinkPolicy.validate(raw),
              let url = URL(string: valid),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

/// File names for received images.
enum ShareFileName {
    static let maxLength = 100

    private static let extensions: [String: String] = [
        "image/jpeg": "jpg", "image/jpg": "jpg", "image/png": "png", "image/gif": "gif",
        "image/webp": "webp", "image/heic": "heic", "image/heif": "heif", "image/bmp": "bmp",
        "image/tiff": "tiff",
    ]

    /// The phone's name reduced to `[A-Za-z0-9 ._-]`, no leading dot, at most 100
    /// characters, with an extension from the MIME type when it has none.
    static func sanitize(_ name: String, mime: String) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        func clean(_ part: String) -> String {
            let allowed = part.unicodeScalars.filter {
                ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || " ._-".unicodeScalars.contains($0)
            }
            return String(String.UnicodeScalarView(allowed)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        }
        var stem = clean(last)
        var ext = ""
        // The extension is split off before cleaning, so a name of only foreign letters
        // ("写真.jpg") keeps "jpg" as its extension, not as its name.
        if let dot = last.lastIndex(of: "."), last.distance(from: dot, to: last.endIndex) <= 6 {
            stem = clean(String(last[..<dot]))
            ext = clean(String(last[last.index(after: dot)...]))
        }
        if ext.isEmpty, let fromMime = extensions[mime.lowercased()] { ext = fromMime }
        if stem.isEmpty { stem = "Image" }
        let room = maxLength - (ext.isEmpty ? 0 : ext.count + 1)
        stem = String(stem.prefix(room)).trimmingCharacters(in: .whitespaces)
        if stem.isEmpty { stem = "Image" }
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    /// `name` in `directory`, or "stem 2.ext", "stem 3.ext"… when taken.
    static func unique(_ name: String, in directory: URL,
                       exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let first = directory.appendingPathComponent(name)
        guard exists(first) else { return first }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = directory.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            if !exists(candidate) { return candidate }
            n += 1
        }
    }
}

/// Receives one shared file at a time into a hidden temp file in `directory`,
/// counting bytes against the cap and hashing as it goes.
final class ShareFileReceiver {
    enum Outcome: Equatable {
        case saved(URL)
        case failed(String)
    }

    private struct Transfer {
        var id: UInt32
        var name: String
        var mime: String
        var temp: URL?
        var handle: FileHandle?
        var hasher = SHA256()
        var bytes = 0
        var error: String?
    }

    let directory: URL
    private let maxBytes: Int
    private var current: Transfer?

    init(directory: URL, maxBytes: Int = ShareInPolicy.maxFileBytes) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    /// Starts a transfer; an unfinished one is abandoned.
    func begin(id: UInt32, name: String, mime: String) {
        discard()
        var transfer = Transfer(id: id, name: ShareFileName.sanitize(name, mime: mime), mime: mime)
        if !mime.lowercased().hasPrefix("image/") {
            transfer.error = "not an image (\(mime))"
        } else {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let temp = directory.appendingPathComponent(".contigua-\(UUID().uuidString).part")
                guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                transfer.temp = temp
                transfer.handle = try FileHandle(forWritingTo: temp)
            } catch {
                transfer.error = "cannot write to \(directory.path)"
            }
        }
        current = transfer
    }

    func data(id: UInt32, bytes: [UInt8]) {
        guard var transfer = current, transfer.id == id, transfer.error == nil else { return }
        transfer.bytes += bytes.count
        if transfer.bytes > maxBytes {
            transfer.error = "larger than \(maxBytes / 1_048_576) MB"
            closeAndRemove(&transfer)
        } else {
            transfer.hasher.update(data: bytes)
            do {
                try transfer.handle?.write(contentsOf: bytes)
            } catch {
                transfer.error = "write failed"
                closeAndRemove(&transfer)
            }
        }
        current = transfer
    }

    /// The finished file, or why it was refused; nil for an unknown id.
    func end(id: UInt32, size: Int, sha256: String) -> Outcome? {
        guard var transfer = current, transfer.id == id else { return nil }
        current = nil
        if let error = transfer.error {
            closeAndRemove(&transfer)
            return .failed(error)
        }
        let digest = transfer.hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard transfer.bytes == size, digest == sha256.lowercased() else {
            closeAndRemove(&transfer)
            return .failed("checksum mismatch")
        }
        try? transfer.handle?.close()
        guard let temp = transfer.temp else { return .failed("no file") }
        let target = ShareFileName.unique(transfer.name, in: directory)
        do {
            try FileManager.default.moveItem(at: temp, to: target)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return .failed("cannot save \(target.lastPathComponent)")
        }
        return .saved(target)
    }

    func abort(id: UInt32) {
        guard current?.id == id else { return }
        discard()
    }

    /// Drops an unfinished transfer (abandoned, or the session ended).
    func discard() {
        guard var transfer = current else { return }
        closeAndRemove(&transfer)
        current = nil
    }

    private func closeAndRemove(_ transfer: inout Transfer) {
        try? transfer.handle?.close()
        transfer.handle = nil
        if let temp = transfer.temp { try? FileManager.default.removeItem(at: temp) }
        transfer.temp = nil
    }
}

/// What a share does on the Mac; `SystemShareActions` is the real one.
protocol ShareInActions: AnyObject {
    func open(_ url: URL)
    func copy(text: String)
    func copy(imageFile: URL)
    func notify(title: String, body: String, file: URL?)
    /// A link the rate limit held back (sec H-2): a notification whose click
    /// opens it. The default keeps test doubles simple.
    func notifyLink(title: String, body: String, url: URL)
}

extension ShareInActions {
    func notifyLink(title: String, body: String, url: URL) {
        notify(title: title, body: body, file: nil)
    }
}

/// At most one automatic browser open per phone per window (sec H-2): a phone
/// that shares links in a loop cannot take the Mac's screen (or fill the
/// browser with tabs) one link at a time. The clock is injected (a monotonic
/// one in production) so the rule is testable.
struct ShareOpenLimiter {
    static let window: TimeInterval = 3
    private var lastOpen: [String: TimeInterval] = [:]

    mutating func allow(phone: String, now: TimeInterval) -> Bool {
        if let last = lastOpen[phone] {
            let elapsed = now - last
            // A clock that went backwards is not a new window (fail closed).
            if elapsed < Self.window { return false }
        }
        lastOpen[phone] = now
        return true
    }
}

/// Routes shares from the connected phone to the actions.
@MainActor
final class ShareInbox {
    private let receiver: ShareFileReceiver
    private let actions: ShareInActions
    var phoneName = "your phone"
    /// The connected phone's id: the open rate limit is per phone.
    var phoneId = ""
    /// Monotonic in production; tests inject a value.
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private var openLimiter = ShareOpenLimiter()

    init(directory: URL, actions: ShareInActions) {
        receiver = ShareFileReceiver(directory: directory)
        self.actions = actions
    }

    private var phoneKey: String { phoneId.isEmpty ? phoneName : phoneId }

    func text(_ raw: String) {
        switch ShareInPolicy.classify(raw) {
        case .link(let url):
            guard openLimiter.allow(phone: phoneKey, now: clock()) else {
                // Inside the window: no second browser open. The notification
                // carries the host only, never the path/query, and its click
                // opens the link.
                Log.app.notice("share: link from phone held by the open-rate limit")
                actions.notifyLink(title: "Link from \(phoneName)", body: url.host ?? "", url: url)
                return
            }
            Log.app.notice("share: link from phone")
            actions.open(url)
        case .text(let text):
            let bytes = text.utf8.count
            Log.app.notice("share: text from phone (\(bytes, privacy: .public) bytes)")
            actions.copy(text: text)
            actions.notify(title: "Copied from \(phoneName)", body: String(text.prefix(120)), file: nil)
        case nil:
            Log.app.notice("share: ignored empty or oversized text")
        }
    }

    func fileBegin(id: UInt32, name: String, mime: String) { receiver.begin(id: id, name: name, mime: mime) }
    func fileData(id: UInt32, bytes: [UInt8]) { receiver.data(id: id, bytes: bytes) }
    func fileAbort(id: UInt32) { receiver.abort(id: id) }
    func connectionLost() { receiver.discard() }

    func fileEnd(id: UInt32, size: Int, sha256: String) {
        switch receiver.end(id: id, size: size, sha256: sha256) {
        case .saved(let url):
            Log.app.notice("share: saved \(url.path, privacy: .private)")
            actions.copy(imageFile: url)
            actions.notify(title: "Image from \(phoneName)", body: url.lastPathComponent, file: url)
        case .failed(let why):
            Log.app.notice("share: image refused: \(why, privacy: .public)")
            actions.notify(title: "Couldn't save the image from \(phoneName)", body: why, file: nil)
        case nil:
            break
        }
    }

    /// `~/Downloads/Contigua`.
    static var defaultDirectory: URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return downloads.appendingPathComponent("Contigua", isDirectory: true)
    }
}

/// The browser, pasteboard and Notification Center. With a `log` file (`--share-log`,
/// e2e) links and notifications are recorded there instead of shown. The UN
/// delegate lives in NotificationRouter (NotifyCenter.swift), which routes share
/// responses back here.
final class SystemShareActions: NSObject, ShareInActions {
    static let category = "contigua.share.image"
    static let linkCategory = "contigua.share.link"
    static let showAction = "show"

    private let log: URL?
    private let copyText: (String) -> Void
    private var registered = false

    /// `copyText` writes through the clipboard sync so the text is not echoed back.
    init(log: URL?, copyText: @escaping (String) -> Void) {
        self.log = log
        self.copyText = copyText
    }

    func open(_ url: URL) {
        if log != nil { return record("would open \(url.absoluteString)") }
        NSWorkspace.shared.open(url)
    }

    func copy(text: String) { copyText(text) }

    func copy(imageFile: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(imageFile.absoluteString, forType: .fileURL)
        if let tiff = NSImage(contentsOf: imageFile)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pasteboard.writeObjects([item])
    }

    func notify(title: String, body: String, file: URL?) {
        if log != nil { return record("notify \(title): \(body)") }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let file {
            content.categoryIdentifier = Self.category
            content.userInfo = ["file": file.path]
        }
        deliver(content)
    }

    /// A held-back link (sec H-2): the click opens it. Body is the host only.
    func notifyLink(title: String, body: String, url: URL) {
        if log != nil { return record("notify \(title): \(body) (link)") }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.linkCategory
        content.userInfo = ["url": url.absoluteString]
        deliver(content)
    }

    private func deliver(_ content: UNMutableNotificationContent) {
        let center = UNUserNotificationCenter.current()
        if !registered {
            registered = true
            let show = UNNotificationAction(identifier: Self.showAction, title: "Show in Finder")
            center.setNotificationCategories([
                UNNotificationCategory(identifier: Self.category, actions: [show], intentIdentifiers: []),
                UNNotificationCategory(identifier: Self.linkCategory, actions: [], intentIdentifiers: []),
            ])
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.requestAuthorization(options: [.alert]) { granted, _ in
            if granted { center.add(request) }
        }
    }

    /// The share notification's response, routed by NotificationRouter.
    @MainActor
    func handleShareResponse(_ response: UNNotificationResponse) {
        if let raw = response.notification.request.content.userInfo["url"] as? String,
           response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let url = ShareInPolicy.webURL(raw) {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            return
        }
        if let path = response.notification.request.content.userInfo["file"] as? String,
           response.actionIdentifier == Self.showAction || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let url = URL(fileURLWithPath: path)
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    private func record(_ line: String) {
        guard let log else { return }
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: log)
        }
    }
}
