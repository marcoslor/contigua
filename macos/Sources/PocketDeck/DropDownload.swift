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

    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

/// Both the header and the bytes must say image: a text answer served as
/// image/* still refuses, and an image served without an image header does too.
enum DropImageSniff {
    static func kind(_ data: Data) -> (mime: String, ext: String)? {
        let bytes = [UInt8](data.prefix(16))
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return ("image/png", "png")
        }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return ("image/jpeg", "jpg")
        }
        if data.starts(with: Array("GIF87a".utf8)) || data.starts(with: Array("GIF89a".utf8)) {
            return ("image/gif", "gif")
        }
        if bytes.count >= 12, String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
           String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" {
            return ("image/webp", "webp")
        }
        if bytes.count >= 12, String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp" {
            let brand = String(bytes: bytes[8..<12], encoding: .ascii) ?? ""
            let heic = ["heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1"]
            if heic.contains(brand) { return ("image/heic", "heic") }
        }
        return nil
    }
}

final class DropDownloader: NSObject, URLSessionDataDelegate, DropDownloading {
    typealias Completion = (Result<DropDownload, DropResolveFailure>) -> Void

    private let timeout: TimeInterval
    private let cap: Int
    private let configuration: URLSessionConfiguration
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var completion: Completion?
    private var data = Data()
    private var responseMime = ""
    private var finished = false
    private var timeoutTask: Task<Void, Never>?

    init(timeout: TimeInterval = DropDownloadPolicy.timeout,
         cap: Int = DropDownloadPolicy.maxBytes,
         configuration: URLSessionConfiguration = DropDownloader.ephemeral()) {
        self.timeout = timeout
        self.cap = cap
        self.configuration = configuration
    }

    /// No cookies, no cache, no credentials: a dropped link is a public GET.
    static func ephemeral() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return config
    }

    func download(_ url: URL, completion: @escaping Completion) {
        guard DropDownloadPolicy.allows(url) else { return completion(.failure(.failed)) }
        self.completion = completion
        finished = false
        data.removeAll(keepingCapacity: true)
        responseMime = ""
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.session = session
        let task = session.dataTask(with: URLRequest(url: url))
        self.task = task
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(.timedOut))
        }
        task.resume()
    }

    func cancel() {
        finish(.failure(.cancelled))
    }

    private func finish(_ result: Result<DropDownload, DropResolveFailure>) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        task?.cancel()
        task = nil
        let session = self.session
        self.session = nil
        let completion = self.completion
        self.completion = nil
        completion?(result)
        // Invalidate after the delegate returns: a session invalidated from
        // inside its own callback can deadlock.
        Task { @MainActor in session?.invalidateAndCancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !finished else { return }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let mime = http.mimeType?.lowercased(), mime.hasPrefix("image/") else {
            completionHandler(.cancel)
            return finish(.failure(.notImage))
        }
        responseMime = mime
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard !finished else { return }
        data.append(chunk)
        if data.count > cap { finish(.failure(.tooLarge)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        if error != nil { return finish(.failure(.failed)) }
        guard !responseMime.isEmpty, let kind = DropImageSniff.kind(data) else {
            return finish(.failure(.notImage))
        }
        finish(.success(DropDownload(data: data, mime: kind.mime, ext: kind.ext)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, DropDownloadPolicy.allows(url) else {
            completionHandler(nil)
            return finish(.failure(.failed))
        }
        completionHandler(request)
    }
}
