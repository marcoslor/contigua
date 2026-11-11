// WIN-44…WIN-49 on the Mac: a task the app started itself enters the same
// New-item rule as ⌘N, opens one more window with one `window.adopt`, and a
// refusal or a move to the phone closes that window quietly.

import XCTest
@testable import Contigua

@MainActor
final class AdoptedWindowTests: XCTestCase {
    private var fixture: MultiWindowFixture!

    override func setUp() {
        super.setUp()
        fixture = MultiWindowFixture()
    }

    override func tearDown() {
        fixture.closeAll()
        fixture = nil
        super.tearDown()
    }

    private var chrome: AppInfo { MultiWindowFixture.chrome }
    private var settings: AppInfo { MultiWindowFixture.settings }

    @discardableResult
    private func adopt(taskId: Int = 42, label: String? = "New tab", stream: UInt32? = nil) -> AppWindowController? {
        let source = stream ?? fixture.manager.appWindows(pkg: chrome.pkg).first?.stream ?? 0
        return fixture.manager.noteTaskArrival(stream: source, taskId: taskId, pkg: chrome.pkg, label: label)
    }

    func testAReportedTaskOpensOneMoreWindowAndSendsOneAdopt() {
        let first = fixture.open(taskLabel: "Docs")
        fixture.session.clearSent()
        let adopted = adopt()

        XCTAssertNotNil(adopted)
        XCTAssertEqual(fixture.manager.appWindows(pkg: chrome.pkg).count, 2)
        let adopts = fixture.session.sent("window.adopt")
        XCTAssertEqual(adopts.count, 1)
        XCTAssertEqual(adopts.first?["taskId"] as? Int, 42)
        XCTAssertEqual(adopts.first?["pkg"] as? String, chrome.pkg)
        XCTAssertEqual(adopts.first?["stream"] as? Int, adopted.map { Int($0.stream) })
        XCTAssertTrue(fixture.session.sent("window.open").isEmpty, "an adopt is not a window.open")
        XCTAssertEqual(adopted?.window?.title, "Chrome — New tab (Pixel 9)")
        XCTAssertTrue(first.window?.isVisible == true, "the source window stays open")
    }

    func testAnAppThatOpensOneWindowSendsNothing() {
        fixture.open(settings)
        let adopted = fixture.manager.noteTaskArrival(stream: 1, taskId: 42,
                                                     pkg: settings.pkg, label: "Settings")
        XCTAssertNil(adopted)
        XCTAssertTrue(fixture.session.sent("window.adopt").isEmpty)
        XCTAssertEqual(fixture.manager.appWindows(pkg: settings.pkg).count, 1)
    }

    func testAtTheMacsCapNoWindowOpensAndTheDeckSaysWhy() {
        fixture.manager.setMaxWindows(1)
        fixture.open(taskLabel: "Docs")
        var notice: String?
        fixture.manager.onTooManyWindows = { notice = $0 }

        let adopted = adopt()

        XCTAssertNil(adopted)
        XCTAssertTrue(fixture.session.sent("window.adopt").isEmpty)
        XCTAssertEqual(fixture.manager.appWindows(pkg: chrome.pkg).count, 1)
        XCTAssertEqual(notice, "Close a Chrome window to open another.")
    }

    func testAWindowStillOpeningBlocksTheAdoptWithoutANotice() {
        fixture.open(taskLabel: "Docs", firstFrame: false)
        var notice: String?
        fixture.manager.onTooManyWindows = { notice = $0 }

        let adopted = adopt()

        XCTAssertNil(adopted)
        XCTAssertTrue(fixture.session.sent("window.adopt").isEmpty)
        XCTAssertNil(notice)
    }

    func testADownLinkBlocksTheAdopt() {
        fixture.open(taskLabel: "Docs")
        fixture.manager.linkLost()
        XCTAssertNil(adopt())
        XCTAssertTrue(fixture.session.sent("window.adopt").isEmpty)
    }

    func testCannotAdoptClosesThatWindowQuietly() {
        fixture.open(taskLabel: "Docs")
        let adopted = adopt()
        var notice: String?
        fixture.manager.onTooManyWindows = { notice = $0 }

        fixture.manager.handle(.phoneError(code: "cannot_adopt", message: nil,
                                           stream: adopted!.stream))

        XCTAssertEqual(fixture.manager.appWindows(pkg: chrome.pkg).count, 1)
        XCTAssertTrue(fixture.session.sent("window.close").isEmpty,
                      "a refused adopt closes without a window.close")
        XCTAssertNil(notice)
    }

    func testMovedToPhoneClosesThatWindowQuietly() {
        let first = fixture.open(taskLabel: "Docs")
        let adopted = adopt()
        XCTAssertNotNil(adopted)

        fixture.manager.handle(.windowClosed(stream: first.stream, reason: "moved_to_phone"))

        XCTAssertEqual(fixture.manager.appWindows(pkg: chrome.pkg).count, 1)
        XCTAssertEqual(fixture.manager.appWindows(pkg: chrome.pkg).first?.stream, adopted?.stream)
        XCTAssertTrue(fixture.session.sent("window.close").isEmpty)
    }

    func testClosingTheAdoptedWindowClosesOnlyItsOwnStream() {
        let first = fixture.open(taskLabel: "Docs")
        let adopted = adopt()

        adopted?.window?.close()

        let closes = fixture.session.sent("window.close")
        XCTAssertEqual(closes.count, 1)
        XCTAssertEqual(closes.first?["stream"] as? Int, adopted.map { Int($0.stream) })
        XCTAssertEqual(fixture.manager.appWindows(pkg: chrome.pkg).first?.stream, first.stream,
                       "the first window and its task are untouched")
    }
}
