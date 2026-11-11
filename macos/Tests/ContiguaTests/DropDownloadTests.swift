// D3's download rules (SHARE-18): an ephemeral session, http(s) only, the
// 8 MiB/10 s stop, and an answer that must be an image by both its header and
// its first bytes.

import Foundation
import XCTest
@testable import Contigua

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest, StubURLProtocol) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}

    func answer(_ body: Data, mime: String = "image/png", status: Int = 200,
                delay: TimeInterval = 0) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime])!
        let send = {
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: send)
        } else {
            send()
        }
    }

    func redirect(to url: URL) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 302,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": url.absoluteString])!
        var next = URLRequest(url: url)
        next.httpMethod = request.httpMethod
        client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
    }
}

final class DropDownloadTests: XCTestCase {
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func configuration() -> URLSessionConfiguration {
        let config = DropDownloader.ephemeral()
        config.protocolClasses = [StubURLProtocol.self]
        return config
    }

    private func downloader(timeout: TimeInterval = 2, cap: Int = DropDownloadPolicy.maxBytes)
        -> DropDownloader {
        DropDownloader(timeout: timeout, cap: cap, configuration: configuration())
    }

    private func run(_ url: String = "https://example.com/image.png",
                     with downloader: DropDownloader) -> Result<DropDownload, DropResolveFailure> {
        let done = expectation(description: "download")
        var answer: Result<DropDownload, DropResolveFailure> = .failure(.failed)
        downloader.download(URL(string: url)!) {
            answer = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return answer
    }

    func testTheSessionIsEphemeral() {
        let config = DropDownloader.ephemeral()
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertNil(config.urlCache)
        XCTAssertNil(config.urlCredentialStorage)
    }

    func testOnlyHTTPAndHTTPSAreAllowed() {
        XCTAssertTrue(DropDownloadPolicy.allows(URL(string: "http://example.com/a.png")!))
        XCTAssertTrue(DropDownloadPolicy.allows(URL(string: "HTTPS://example.com/a.png")!))
        XCTAssertFalse(DropDownloadPolicy.allows(URL(string: "file:///tmp/a.png")!))
        XCTAssertFalse(DropDownloadPolicy.allows(URL(string: "data:image/png;base64,AA")!))
    }

    func testTheSniffAcceptsTheFiveFormatsAndNothingElse() {
        XCTAssertEqual("image/png", DropImageSniff.kind(Self.png)?.mime)
        XCTAssertEqual("image/jpeg", DropImageSniff.kind(Data([0xFF, 0xD8, 0xFF, 0xE0]))?.mime)
        XCTAssertEqual("image/gif", DropImageSniff.kind(Data("GIF89a".utf8))?.mime)
        XCTAssertEqual("image/webp",
                       DropImageSniff.kind(Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WEBP".utf8))?.mime)
        XCTAssertEqual("image/heic",
                       DropImageSniff.kind(Data([0, 0, 0, 24]) + Data("ftypheic".utf8))?.mime)
        XCTAssertNil(DropImageSniff.kind(Data("<html>".utf8)))
    }

    func testAnImageAnswerLands() {
        StubURLProtocol.handler = { _, stub in stub.answer(Self.png) }
        guard case .success(let download) = run(with: downloader()) else {
            return XCTFail("the image answer was refused")
        }
        XCTAssertEqual(Self.png, download.data)
        XCTAssertEqual("image/png", download.mime)
        XCTAssertEqual("png", download.ext)
    }

    func testANonImageAnswerIsRefusedEvenWhenItIsHTML() {
        StubURLProtocol.handler = { _, stub in
            stub.answer(Data("<html></html>".utf8), mime: "text/html")
        }
        XCTAssertEqual(.failure(.notImage), run(with: downloader()))
    }

    func testAnImageHeaderWithoutImageBytesIsRefused() {
        StubURLProtocol.handler = { _, stub in stub.answer(Data("not an image".utf8)) }
        XCTAssertEqual(.failure(.notImage), run(with: downloader()))
    }

    func testTheCapStopsTheDownload() {
        StubURLProtocol.handler = { _, stub in
            stub.answer(Self.png + Data(count: 256))
        }
        XCTAssertEqual(.failure(.tooLarge), run(with: downloader(cap: 64)))
    }

    func testASilentServerTimesOut() {
        StubURLProtocol.handler = { _, _ in }
        XCTAssertEqual(.failure(.timedOut), run(with: downloader(timeout: 0.15)))
    }

    func testARedirectToANonHTTPSchemeIsRefused() {
        StubURLProtocol.handler = { _, stub in
            stub.redirect(to: URL(string: "file:///tmp/secret")!)
        }
        guard case .failure = run(with: downloader()) else {
            return XCTFail("a file: redirect was accepted")
        }
    }
}
