// Scripted phone-file requests for the e2e `files` check (the pattern of
// DebugInput.swift, without NSEvents): a script line asks the session for a
// listing, a stat or a read, and each result goes out as one JSON line on
// stderr — the harness captures it into app.log. Names never appear: a result
// carries a name's SHA-256 prefix, its size, its directory flag and its etag.
//
// Grammar (blank lines and lines starting with # are ignored):
//   list PATH                           one page
//   listall PATH                        every page, following the phone's cursor
//   stat PATH
//   digest PATH                         the folder's fs.digest (one path)
//   read PATH OUT                       the whole file into OUT
//   read PATH OUT OFFSET LENGTH [ETAG [CANCEL_MS]]
//                                       a range; ETAG is '-' (omit), 'stale'
//                                       (32 zeros) or a 32-hex etag, and
//                                       CANCEL_MS cancels the read that long
//                                       after it started
// PATH is relative to the phone's shared storage (no PATH = the root), OUT an
// absolute path on this Mac. Paths with spaces are not supported.
//
// Results: {"op":"list","ok":true,"p":"<hash>","items":[{"n","d","s","e"}],
// "more":bool} / {"op":"stat",...} / {"op":"read","ok":true,"bytes":N,
// "sha256":"..."} / a failure with "code". The last line is {"op":"done"}.

import CryptoKit
import Foundation

enum FsScriptAction: Equatable {
    case list(String)
    case listAll(String)
    case stat(String)
    case digest(String)
    case read(path: String, out: String, offset: Int?, length: Int?, etag: String?, cancelAfterMs: Int?)
}

struct FsScriptError: Error, CustomStringConvertible {
    let line: Int
    let message: String
    var description: String { "line \(line): \(message)" }
}

enum FsDebugScript {
    static func parse(_ text: String) throws -> [FsScriptAction] {
        var actions: [FsScriptAction] = []
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let words = line.split(separator: " ").map(String.init)
            do {
                actions.append(try parseLine(words))
            } catch let error as LineError {
                throw FsScriptError(line: index + 1, message: error.message)
            }
        }
        return actions
    }

    private struct LineError: Error { let message: String }

    private static func parseLine(_ words: [String]) throws -> FsScriptAction {
        switch words.first?.lowercased() {
        case "list", "listall", "stat", "digest":
            guard words.count <= 2 else { throw LineError(message: "\(words[0]) takes at most one PATH") }
            let path = words.count == 2 ? words[1] : ""
            switch words[0].lowercased() {
            case "list": return .list(path)
            case "listall": return .listAll(path)
            case "digest": return .digest(path)
            default: return .stat(path)
            }
        case "read":
            guard words.count == 3 || (5...7).contains(words.count) else {
                throw LineError(message: "read needs PATH OUT [OFFSET LENGTH [ETAG [CANCEL_MS]]]")
            }
            guard words[2].hasPrefix("/") else { throw LineError(message: "OUT must be an absolute path") }
            if words.count == 3 {
                return .read(path: words[1], out: words[2], offset: nil, length: nil,
                             etag: nil, cancelAfterMs: nil)
            }
            guard let offset = Int(words[3]), let length = Int(words[4]), offset >= 0, length >= 0 else {
                throw LineError(message: "OFFSET and LENGTH must be non-negative integers")
            }
            var etag: String?
            if words.count >= 6 {
                let text = words[5]
                if text == "-" {
                    etag = nil
                } else if text == "stale" {
                    etag = String(repeating: "0", count: 32)
                } else if text.count == 32, text.allSatisfy({ $0.isHexDigit }) {
                    etag = text
                } else {
                    throw LineError(message: "ETAG must be '-', 'stale' or 32 hex characters")
                }
            }
            var cancel: Int?
            if words.count == 7 {
                guard let ms = Int(words[6]), ms >= 0 else {
                    throw LineError(message: "CANCEL_MS must be a non-negative integer")
                }
                cancel = ms
            }
            return .read(path: words[1], out: words[2], offset: offset, length: length,
                         etag: etag, cancelAfterMs: cancel)
        default:
            throw LineError(message: "unknown action '\(words.first ?? "")'")
        }
    }
}

/// Runs the parsed script once, in order, on the main thread.
@MainActor
final class FsDebugDriver {
    private let actions: [FsScriptAction]
    private let client: FsClient
    private var index = 0

    init(actions: [FsScriptAction], client: FsClient) {
        self.actions = actions
        self.client = client
    }

    func run() {
        step()
    }

    private func step() {
        guard index < actions.count else {
            emit(["op": "done", "n": actions.count])
            return
        }
        let action = actions[index]
        index += 1
        switch action {
        case .list(let path):
            client.list(path: path, page: nil) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let page):
                    self.emit([
                        "op": "list", "ok": true, "p": self.nameHash(path),
                        "items": page.items.map { item in
                            ["n": self.nameHash(item.name), "d": item.dir ? 1 : 0,
                             "s": item.size, "e": item.etag] as [String: Any]
                        },
                        "more": page.next != nil,
                    ])
                case .failure(let error):
                    self.fail("list", path: path, error)
                }
                self.step()
            }
        case .listAll(let path):
            listAll(path: path, page: nil)
        case .stat(let path):
            client.stat(path: path) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let item):
                    self.emit(["op": "stat", "ok": true, "p": self.nameHash(path),
                               "n": self.nameHash(item.name), "d": item.dir ? 1 : 0,
                               "s": item.size, "e": item.etag])
                case .failure(let error):
                    self.fail("stat", path: path, error)
                }
                self.step()
            }
        case .digest(let path):
            client.digest(paths: [path]) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let values):
                    switch values[path] {
                    case .digest(let digest):
                        self.emit(["op": "digest", "ok": true, "p": self.nameHash(path),
                                   "digest": digest])
                    case .notFound:
                        self.fail("digest", path: path, FsError(code: "fs_not_found"))
                    case nil:
                        self.fail("digest", path: path, FsError(code: "protocol"))
                    }
                case .failure(let error):
                    self.fail("digest", path: path, error)
                }
                self.step()
            }
        case .read(let path, let out, let offset, let length, let etag, let cancel):
            client.read(path: path, offset: offset, length: length, etag: etag,
                        to: URL(fileURLWithPath: out), cancelAfterMs: cancel) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let read):
                    self.emit(["op": "read", "ok": true, "p": self.nameHash(path),
                               "o": self.nameHash(out), "bytes": read.bytes, "sha256": read.sha256])
                case .failure(let error):
                    self.fail("read", path: path, error)
                }
                self.step()
            }
        }
    }

    /// `listall`: the same request with the phone's cursor until it says the
    /// page is the last one. Each page is one result line.
    private func listAll(path: String, page: String?) {
        client.list(path: path, page: page) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let listing):
                self.emit([
                    "op": "list", "ok": true, "p": self.nameHash(path),
                    "items": listing.items.map { item in
                        ["n": self.nameHash(item.name), "d": item.dir ? 1 : 0,
                         "s": item.size, "e": item.etag] as [String: Any]
                    },
                    "more": listing.next != nil,
                ])
                if let next = listing.next {
                    self.listAll(path: path, page: next)
                } else {
                    self.step()
                }
            case .failure(let error):
                self.fail("list", path: path, error)
                self.step()
            }
        }
    }

    private func fail(_ op: String, path: String, _ error: FsError) {
        var line: [String: Any] = ["op": op, "ok": false, "p": nameHash(path)]
        line["code"] = error.code
        emit(line)
    }

    private func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        FileHandle.standardError.write(Data("fsdebug: \(text)\n".utf8))
    }

    /// 16 hex characters of the name's SHA-256: enough to compare a listing
    /// without putting a file name in a log.
    private func nameHash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}
