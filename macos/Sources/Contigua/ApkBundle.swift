// APK install (docs/design/apk.md): which files of an .apk / .apks / .xapk go to the
// phone, read with a minimal zip reader, and what the phone's answer means in words.

import Compression
import CryptoKit
import Foundation

enum ApkBundleError: Error, Equatable {
    case notAnApp
    case unsafeEntry(String)
    case tooLarge
    case unreadable

    var message: String {
        switch self {
        case .notAnApp: "That file isn't an Android app."
        case .unsafeEntry: "That file looks damaged or unsafe, so it wasn't sent."
        case .tooLarge: "That app is larger than 1 GB."
        case .unreadable: "Couldn't read that file."
        }
    }
}

/// One central-directory entry of a zip.
struct ZipEntry: Equatable {
    var name: String
    var method: UInt16
    var compressedSize: Int
    var size: Int
    var localHeaderOffset: Int
}

/// Reads the central directory of a zip (no zip64: an app over 4 GB is refused anyway).
struct ZipArchive {
    let data: Data
    let entries: [ZipEntry]

    init(url: URL) throws {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { throw ApkBundleError.unreadable }
        try self.init(data: data)
    }

    init(data: Data) throws {
        self.data = data
        let bytes = [UInt8](data.suffix(65_557))
        guard bytes.count >= 22,
              let eocd = stride(from: bytes.count - 22, through: 0, by: -1).first(where: { Self.u32(bytes, $0) == 0x0605_4b50 })
        else { throw ApkBundleError.notAnApp }
        let count = Int(Self.u16(bytes, eocd + 10))
        let directoryStart = Int(Self.u32(bytes, eocd + 16))
        let directoryEnd = data.count - bytes.count + eocd
        guard directoryStart <= directoryEnd else { throw ApkBundleError.notAnApp }
        // Only the central directory is copied; the entries stay mapped.
        let all = [UInt8](data[directoryStart..<directoryEnd])
        var offset = 0
        var entries: [ZipEntry] = []
        for _ in 0..<count {
            guard offset + 46 <= all.count, Self.u32(all, offset) == 0x0201_4b50 else { throw ApkBundleError.notAnApp }
            let nameLength = Int(Self.u16(all, offset + 28))
            let skip = nameLength + Int(Self.u16(all, offset + 30)) + Int(Self.u16(all, offset + 32))
            guard offset + 46 + nameLength <= all.count else { throw ApkBundleError.notAnApp }
            let compressed = Self.u32(all, offset + 20), size = Self.u32(all, offset + 24), local = Self.u32(all, offset + 42)
            guard compressed != .max, size != .max, local != .max else { throw ApkBundleError.tooLarge }
            guard let name = String(bytes: all[(offset + 46)..<(offset + 46 + nameLength)], encoding: .utf8) else {
                throw ApkBundleError.unsafeEntry("?")
            }
            entries.append(ZipEntry(name: name, method: Self.u16(all, offset + 10), compressedSize: Int(compressed),
                                    size: Int(size), localHeaderOffset: Int(local)))
            offset += 46 + skip
        }
        self.entries = entries
    }

    /// Writes one entry (stored or deflate) to `file` and returns its SHA-256 (hex).
    func extract(_ entry: ZipEntry, to file: URL) throws -> String {
        let start = entry.localHeaderOffset
        let header = [UInt8](data[start..<min(data.count, start + 30)])
        guard header.count == 30, Self.u32(header, 0) == 0x0403_4b50 else { throw ApkBundleError.unreadable }
        let begin = start + 30 + Int(Self.u16(header, 26)) + Int(Self.u16(header, 28))
        guard begin + entry.compressedSize <= data.count else { throw ApkBundleError.unreadable }
        let body = data[begin..<(begin + entry.compressedSize)]
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let out = try? FileHandle(forWritingTo: file) else { throw ApkBundleError.unreadable }
        defer { try? out.close() }
        var hash = SHA256()
        var written = 0
        let sink: (Data) throws -> Void = { chunk in
            hash.update(data: chunk)
            written += chunk.count
            try out.write(contentsOf: chunk)
        }
        switch entry.method {
        case 0: try sink(Data(body))
        case 8: try Self.inflate(Data(body), into: sink)
        default: throw ApkBundleError.unreadable
        }
        guard written == entry.size else { throw ApkBundleError.unreadable }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func inflate(_ input: Data, into sink: (Data) throws -> Void) throws {
        let bufferSize = 1 << 20
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }
        var stream = compression_stream(dst_ptr: destination, dst_size: 0, src_ptr: destination, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ApkBundleError.unreadable
        }
        defer { compression_stream_destroy(&stream) }
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(destination)
            stream.src_size = raw.count
            while true {
                stream.dst_ptr = destination
                stream.dst_size = bufferSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status != COMPRESSION_STATUS_ERROR else { throw ApkBundleError.unreadable }
                let produced = bufferSize - stream.dst_size
                if produced > 0 { try sink(Data(bytes: destination, count: produced)) }
                if status == COMPRESSION_STATUS_END { return }
                if produced == 0 && stream.src_size == 0 { throw ApkBundleError.unreadable }
            }
        }
    }

    static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}

/// What gets installed from a dropped file: the APK parts, base first.
struct ApkBundle: Equatable {
    enum Kind: Equatable { case apk, apks, xapk }

    /// A part as the phone sees it: a plain file name, and the zip entry it comes from
    /// (nil = the dropped .apk itself).
    struct Part: Equatable {
        var name: String
        var entry: String?
        var size: Int
    }

    static let maxTotalBytes = 1 << 30
    static let fileExtensions = ["apk", "apks", "xapk"]

    var kind: Kind
    var parts: [Part]
    var totalBytes: Int { parts.reduce(0) { $0 + $1.size } }

    static func kind(of url: URL) -> Kind? {
        switch url.pathExtension.lowercased() {
        case "apk": .apk
        case "apks": .apks
        case "xapk": .xapk
        default: nil
        }
    }

    /// Entry names that could escape a folder or confuse a path are refused outright.
    static func isSafe(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0") else { return false }
        return !name.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    /// Picks the parts from a zip's entry names (`manifestPackage`: an .xapk's `manifest.json` package).
    static func plan(kind: Kind, entries: [ZipEntry], fileSize: Int, manifestPackage: String? = nil) throws -> ApkBundle {
        if let bad = entries.first(where: { !isSafe($0.name) }) { throw ApkBundleError.unsafeEntry(bad.name) }
        if kind == .apk {
            guard entries.contains(where: { $0.name == "AndroidManifest.xml" }) else { throw ApkBundleError.notAnApp }
            guard fileSize <= maxTotalBytes else { throw ApkBundleError.tooLarge }
            return ApkBundle(kind: .apk, parts: [Part(name: "base.apk", entry: nil, size: fileSize)])
        }
        let apks = entries.filter {
            $0.name.lowercased().hasSuffix(".apk") && !$0.name.hasSuffix("/") && !$0.name.hasPrefix("standalones/")
        }
        guard !apks.isEmpty else { throw ApkBundleError.notAnApp }
        let baseNames = ["base.apk", "base-master.apk"] + (manifestPackage.map { ["\($0).apk"] } ?? [])
        func file(_ e: ZipEntry) -> String { String(e.name.split(separator: "/").last ?? "") }
        let base = apks.first { baseNames.contains(file($0)) }
            ?? { let plain = apks.filter { !file($0).hasPrefix("config.") && !file($0).hasPrefix("split_") && !file($0).contains("-") }
                 return plain.count == 1 ? plain[0] : nil }()
        let ordered = (base.map { [$0] } ?? []) + apks.filter { $0 != base }
        var used = Set<String>()
        let parts = ordered.map { entry -> Part in
            var name = String(file(entry).map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || "._-".contains($0) ? $0 : "_" })
            if name.hasPrefix(".") { name = "_" + name }
            if name.count > 100 { name = String(name.suffix(100)) }
            while used.contains(name) { name = "_" + name }
            used.insert(name)
            return Part(name: name, entry: entry.name, size: entry.size)
        }
        let bundle = ApkBundle(kind: kind, parts: parts)
        guard bundle.totalBytes <= maxTotalBytes else { throw ApkBundleError.tooLarge }
        return bundle
    }

    /// Reads a dropped file and plans its parts.
    static func open(_ url: URL) throws -> (ApkBundle, ZipArchive) {
        guard let kind = kind(of: url) else { throw ApkBundleError.notAnApp }
        let archive = try ZipArchive(url: url)
        var package: String?
        if kind == .xapk, let manifest = archive.entries.first(where: { $0.name == "manifest.json" }), manifest.size < 1 << 20 {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: tmp) }
            if (try? archive.extract(manifest, to: tmp)) != nil,
               let json = try? JSONSerialization.jsonObject(with: Data(contentsOf: tmp)) as? [String: Any] {
                package = json["package_name"] as? String
            }
        }
        return (try plan(kind: kind, entries: archive.entries, fileSize: archive.data.count, manifestPackage: package), archive)
    }
}

/// The phone's `apk.result` failure codes in words (docs/design/apk.md).
enum ApkInstallMessage {
    static func failure(code: String, detail: String? = nil) -> String {
        let lowered = (detail ?? "").lowercased()
        switch code {
        case "INSTALL_FAILED_VERSION_DOWNGRADE":
            return "A newer version of this app is already on the phone."
        case "INSTALL_FAILED_UPDATE_INCOMPATIBLE", "INSTALL_PARSE_FAILED_INCONSISTENT_CERTIFICATES",
             "INSTALL_FAILED_SHARED_USER_INCOMPATIBLE":
            return "This app is already on the phone with a different signature. Uninstall it on the phone first."
        case "INSTALL_FAILED_INSUFFICIENT_STORAGE":
            return "Not enough storage on the phone."
        case "INSTALL_FAILED_NO_MATCHING_ABIS":
            return "This app doesn't support the phone's processor."
        case "INSTALL_FAILED_OLDER_SDK":
            return "This app needs a newer version of Android."
        case "INSTALL_FAILED_TEST_ONLY":
            return "This is a test-only build; the phone refuses to install it."
        case "INSTALL_FAILED_MISSING_SPLIT":
            return "Part of this app is missing from the file."
        case "INSTALL_FAILED_ABORTED", "INSTALL_FAILED_VERIFICATION_FAILURE", "INSTALL_FAILED_USER_RESTRICTED":
            return "The phone blocked the install."
        case "too_large": return ApkBundleError.tooLarge.message
        case "busy": return "The phone is already installing an app."
        case "checksum": return "The app arrived damaged. Try again."
        case "cancelled": return "Install cancelled."
        case "bad_request": return ApkBundleError.notAnApp.message
        default:
            if lowered.contains("signatures do not match") { return failure(code: "INSTALL_FAILED_UPDATE_INCOMPATIBLE") }
            if code.hasPrefix("INSTALL_PARSE_FAILED") { return ApkBundleError.notAnApp.message }
            return code.hasPrefix("INSTALL_") ? "The phone couldn't install it (\(code))." : "The phone couldn't install it."
        }
    }

    static func success(label: String?, version: String?) -> String {
        guard let label, !label.isEmpty else { return "Installed." }
        guard let version, !version.isEmpty else { return "Installed \(label)." }
        return "Installed \(label) \(version)."
    }
}
