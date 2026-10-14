import AppKit
import XCTest
@testable import PocketDeck

final class OpenLinkTests: XCTestCase {
    func testAllowsTheViewSchemes() {
        for url in ["https://example.com", "http://example.com:8080/x?y#z", "HTTPS://Example.com",
                    "https://maps.google.com/?q=Lisbon", "https://www.youtube.com/watch?v=abc",
                    "geo:38.72,-9.14?q=Lisbon", "tel:+351210000000", "mailto:a@example.com?subject=hi",
                    "https://user@example.com/"] {
            XCTAssertEqual(LinkPolicy.validate(url), url, url)
        }
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(LinkPolicy.validate("  https://example.com\n"), "https://example.com")
    }

    func testRejectsEverythingElse() {
        let rejected: [String?] = [
            nil, "", "   ", "intent://scan/#Intent;scheme=zxing;end", "INTENT:#Intent;end",
            "file:///etc/hosts", "content://com.android.contacts/contacts", "javascript:alert(1)",
            "android-app://com.x/https/example.com", "market://details?id=x", "example.com",
            "https:example.com", "https://", "https:///path", "https://exa mple.com", "https://a.com/\u{0}",
            "tel:", ":https://x", "1http://x", "https://a.com/" + String(repeating: "a", count: LinkPolicy.maxBytes),
        ]
        for url in rejected { XCTAssertNil(LinkPolicy.validate(url), "accepted \(url ?? "nil")") }
    }

    func testLimitIsInUtf8Bytes() {
        let base = "https://a.com/"
        let fits = base + String(repeating: "a", count: LinkPolicy.maxBytes - base.utf8.count)
        XCTAssertEqual(LinkPolicy.validate(fits), fits)
        let tooLong = base + String(repeating: "é", count: (LinkPolicy.maxBytes - base.utf8.count) / 2 + 1)
        XCTAssertNil(LinkPolicy.validate(tooLong))
    }

    // MARK: Scheme mapping

    func testParsesTheOpenScheme() throws {
        let url = try XCTUnwrap(URL(string: "pocketdeck://open?url=https%3A%2F%2Fexample.com%2Fa%3Fb%3D1%26c%3D2"))
        XCTAssertEqual(OpenLinkRequest.parse(schemeURL: url), OpenLinkRequest(url: "https://example.com/a?b=1&c=2"))
        let plain = try XCTUnwrap(URL(string: "pocketdeck://open?url=https://example.com"))
        XCTAssertEqual(OpenLinkRequest.parse(schemeURL: plain)?.url, "https://example.com")
    }

    func testParsesTheTargetPhone() throws {
        let url = try XCTUnwrap(URL(string: "pocketdeck://open?url=geo:0,0%3Fq%3DLisbon&phone=abcd"))
        XCTAssertEqual(OpenLinkRequest.parse(schemeURL: url), OpenLinkRequest(url: "geo:0,0?q=Lisbon", deviceId: "abcd"))
    }

    func testRejectsOtherHostsAndBadLinks() throws {
        for raw in ["pocketdeck://launch?url=https://example.com", "pocketdeck://open", "pocketdeck://open?url=",
                    "pocketdeck://open?url=intent%3A%2F%2Fx", "pocketdeck://open?url=file:///etc/hosts",
                    "https://open?url=https://example.com"] {
            XCTAssertNil(OpenLinkRequest.parse(schemeURL: try XCTUnwrap(URL(string: raw))), raw)
        }
    }

    func testSchemeURLRoundTrips() throws {
        let link = "https://example.com/a?b=1&c=2#frag"
        let url = try XCTUnwrap(OpenLinkRequest.schemeURL(for: link, deviceId: "dev1"))
        XCTAssertEqual(OpenLinkRequest.parse(schemeURL: url), OpenLinkRequest(url: link, deviceId: "dev1"))
    }

    func testReadsLinksFromAPasteboard() {
        let board = NSPasteboard(name: NSPasteboard.Name("dev.pocketdeck.tests.links"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.writeObjects([URL(string: "https://example.com/x")! as NSURL])
        XCTAssertEqual(OpenLinkRequest.from(pasteboard: board)?.url, "https://example.com/x")
        board.clearContents()
        board.setString("  tel:+351210000000 ", forType: .string)
        XCTAssertEqual(OpenLinkRequest.from(pasteboard: board)?.url, "tel:+351210000000")
        board.clearContents()
        board.setString("file:///etc/hosts", forType: .string)
        XCTAssertNil(OpenLinkRequest.from(pasteboard: board))
    }

    func testReadsAWeblocFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("a.webloc")
        try PropertyListSerialization.data(fromPropertyList: ["URL": "https://example.com"], format: .xml, options: 0).write(to: good)
        XCTAssertEqual(OpenLinkRequest.webloc(at: good), "https://example.com")
        let bad = dir.appendingPathComponent("b.webloc")
        try PropertyListSerialization.data(fromPropertyList: ["URL": "file:///etc/hosts"], format: .xml, options: 0).write(to: bad)
        XCTAssertNil(OpenLinkRequest.webloc(at: bad))
    }

    func testWindowTitle() {
        XCTAssertEqual(LinkWindowController.title(for: "https://www.example.com/a"), "www.example.com")
        XCTAssertEqual(LinkWindowController.title(for: "tel:+351210000000"), "tel:+351210000000")
    }

    // MARK: Routing

    func testRoutesToTheNamedPhone() {
        XCTAssertEqual(LinkRoute.route(requested: "b", remembered: ["a", "b"], online: "a"), .open(deviceId: "b"))
    }

    func testOnePhoneNeedsNoPicker() {
        XCTAssertEqual(LinkRoute.route(requested: nil, remembered: ["a"], online: nil), .open(deviceId: "a"))
        XCTAssertEqual(LinkRoute.route(requested: "gone", remembered: ["a"], online: "a"), .open(deviceId: "a"))
    }

    func testSeveralPhonesAskWithTheConnectedOneFirst() {
        XCTAssertEqual(LinkRoute.route(requested: nil, remembered: ["a", "b", "c"], online: "b"), .pick(["b", "a", "c"]))
        XCTAssertEqual(LinkRoute.route(requested: nil, remembered: ["a", "b"], online: nil), .pick(["a", "b"]))
    }

    func testNoPhoneWaits() {
        XCTAssertEqual(LinkRoute.route(requested: nil, remembered: [], online: nil), .wait)
        XCTAssertEqual(LinkRoute.route(requested: "x", remembered: [], online: nil), .wait)
    }
}
