// SHARE-18 on the Deck (docs/design/dragdrop.md): image data, promises and an
// http(s) link all find the Deck's existing routes — one file in the batch,
// installed app, opened link or a download that falls back to the link.

import XCTest
@testable import PocketDeck

@MainActor
final class DeckDropTests: XCTestCase {
    private final class FakePromise: DropPromiseSource {
        func receive(into directory: URL, completion: @escaping (Result<[URL], Error>) -> Void) {}
    }

    func testImageDataAndAPromiseAreFilesInTheBatch() {
        XCTAssertTrue(DeckDropRouter.actions(
            DropDrag(image: DropImage(data: Data([1]), type: .png))).generated)
        XCTAssertTrue(DeckDropRouter.actions(
            DropDrag(promises: [FakePromise()])).generated)
    }

    func testAnHTTPLinkBecomesADownload() {
        let url = URL(string: "https://example.com/photo.png")!
        XCTAssertEqual(url, DeckDropRouter.actions(DropDrag(remote: url)).download)
    }

    func testFilesKeepTodaysRoutes() {
        let apk = URL(fileURLWithPath: "/tmp/app.apk")
        let deckFile = URL(fileURLWithPath: "/tmp/report.pdf")
        let actions = DeckDropRouter.actions(DropDrag(files: [apk, deckFile]))
        XCTAssertEqual(apk, actions.install)
        XCTAssertEqual([deckFile], actions.files)
        XCTAssertFalse(actions.generated)
        XCTAssertNil(actions.download)
    }
}
