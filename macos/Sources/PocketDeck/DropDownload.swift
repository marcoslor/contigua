// D3: an http(s) image download for a dropped link. Ephemeral session (no
// cookies, cache or credentials), http(s) only, 8 MiB or 10 s, and an answer
// is an image only when its Content-Type is image/* and its first bytes sniff
// as PNG, JPEG, GIF, HEIC or WebP. The URL, host and file name are never logged.

import Foundation

/// A finished image answer: the bytes and the type the sniff proved.
struct DropDownload: Equatable {
    var data: Data
    var mime: String
    var ext: String
}

protocol DropDownloading: AnyObject {
    func download(_ url: URL, completion: @escaping (Result<DropDownload, DropResolveFailure>) -> Void)
    func cancel()
}

enum DropDownloadPolicy {
    static let maxBytes = ClipboardSync.maxImageBytes
    static let timeout: TimeInterval = 10

    static func allows(_ url: URL) -> Bool { false }
}

/// Both the header and the bytes must say image: a text answer served as
/// image/* still refuses, and an image served without an image header does too.
enum DropImageSniff {
    static func kind(_ data: Data) -> (mime: String, ext: String)? { nil }
}

final class DropDownloader: NSObject, DropDownloading {
    init(timeout: TimeInterval = DropDownloadPolicy.timeout,
         cap: Int = DropDownloadPolicy.maxBytes,
         configuration: URLSessionConfiguration = DropDownloader.ephemeral()) {}

    static func ephemeral() -> URLSessionConfiguration {
        URLSessionConfiguration.ephemeral
    }

    func download(_ url: URL,
                  completion: @escaping (Result<DropDownload, DropResolveFailure>) -> Void) {
        completion(.failure(.failed))
    }

    func cancel() {}
}
