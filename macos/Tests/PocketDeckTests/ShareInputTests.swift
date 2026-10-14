import AppKit
import XCTest
@testable import PocketDeck

final class ShareInputTests: XCTestCase {
    func testTakesAWebURLItem() {
        XCTAssertEqual(ShareInput.link(from: [URL(string: "https://example.com/a?b=1")!]), "https://example.com/a?b=1")
        XCTAssertEqual(ShareInput.link(from: [NSURL(string: "https://example.com")!]), "https://example.com")
    }

    func testTakesTextThatIsOrContainsOneLink() {
        XCTAssertEqual(ShareInput.link(from: ["  geo:38.72,-9.14?q=Lisbon\n"]), "geo:38.72,-9.14?q=Lisbon")
        XCTAssertEqual(ShareInput.link(from: ["Look at https://example.com/x today"]), "https://example.com/x")
        XCTAssertEqual(ShareInput.link(from: [NSAttributedString(string: "https://example.com")]), "https://example.com")
        XCTAssertEqual(ShareInput.link(from: [Data("https://example.com".utf8)]), "https://example.com")
    }

    func testRejectsTextWithoutALink() {
        XCTAssertNil(ShareInput.link(from: ["just some words"]))
        XCTAssertNil(ShareInput.link(from: [""]))
        XCTAssertNil(ShareInput.link(from: []))
    }

    func testRejectsTextWithSeveralLinks() {
        XCTAssertNil(ShareInput.link(from: ["https://a.example.com and https://b.example.com"]))
    }

    func testRejectsFileAndOtherSchemes() {
        XCTAssertNil(ShareInput.link(from: [URL(fileURLWithPath: "/etc/hosts")]))
        XCTAssertNil(ShareInput.link(from: ["file:///etc/hosts"]))
        XCTAssertNil(ShareInput.link(from: ["intent://x#Intent;end"]))
        XCTAssertNil(ShareInput.link(from: [URL(string: "javascript:alert(1)")!]))
    }

    func testPrefersTheURLItemOverText() {
        XCTAssertEqual(ShareInput.link(from: ["Page title", URL(string: "https://example.com/page")!]), "https://example.com/page")
    }

    func testFallsBackToTextWhenTheURLItemIsAFile() {
        XCTAssertEqual(ShareInput.link(from: [URL(fileURLWithPath: "/tmp/a"), "https://example.com"]), "https://example.com")
    }

    func testHandoffURLAndContainingApp() throws {
        let url = try XCTUnwrap(ShareHandoff.schemeURL(for: "https://example.com/a?b=1&c=2"))
        XCTAssertEqual(OpenLinkRequest.parse(schemeURL: url), OpenLinkRequest(url: "https://example.com/a?b=1&c=2"))
        let appex = URL(fileURLWithPath: "/Applications/PocketDeck.app/Contents/PlugIns/Share.appex")
        XCTAssertEqual(ShareHandoff.containingApp(ofExtension: appex).path, "/Applications/PocketDeck.app")
    }
}
