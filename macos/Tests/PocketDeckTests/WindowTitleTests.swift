// A window's title (WIN-3, WIN-28): the short form while its app has one
// window, "<App> — <task> (<phone>)" from the second on, back to the short form
// when one is left, and a new label from the phone retitles within 2 s.
//
// The title is what the Window menu and Mission Control inherit, so it is
// asserted on the window itself.

import XCTest
@testable import PocketDeck

@MainActor
final class WindowTitleTests: XCTestCase {
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

    func testOneWindowKeepsTheShortTitle() {
        let window = fixture.open(taskLabel: "Docs")
        XCTAssertEqual(window.window?.title, "Chrome (Pixel 9)")
        // The phone's label does not change a lone window's title (the person's
        // decision, 10-28).
        fixture.manager.setTaskLabel("Something else", stream: window.stream)
        XCTAssertEqual(window.window?.title, "Chrome (Pixel 9)")
    }

    func testFromTheSecondWindowEveryWindowNamesItsTask() {
        let a = fixture.open(taskLabel: "Docs")
        let b = fixture.add(taskLabel: "Mail")!
        XCTAssertEqual(a.window?.title, "Chrome — Docs (Pixel 9)")
        XCTAssertEqual(b.window?.title, "Chrome — Mail (Pixel 9)")
    }

    /// A phone that reports no label leaves the app's own label standing (WIN-28).
    func testATaskWithoutALabelFallsBackToTheAppLabel() {
        _ = fixture.open(taskLabel: "Docs")
        let b = try? XCTUnwrap(fixture.add())
        XCTAssertEqual(b?.window?.title, "Chrome — Chrome (Pixel 9)")
    }

    func testTheSurvivorGoesBackToTheShortTitle() {
        let a = fixture.open(taskLabel: "Docs")
        let b = fixture.add(taskLabel: "Mail")!
        b.window?.close()
        XCTAssertEqual(a.window?.title, "Chrome (Pixel 9)")
    }

    /// `window.title` on an app stream retitles within 2 s — the rule allows
    /// that budget, and the Mac applies it at once.
    func testALabelChangeRetitlesWithinTwoSeconds() {
        let a = fixture.open(taskLabel: "Docs")
        _ = fixture.add(taskLabel: "Mail")
        let start = Date()
        fixture.manager.handle(.windowTitle(stream: a.stream, label: "Inbox", pkg: "com.android.chrome"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "the retitle is immediate")
        XCTAssertEqual(a.window?.title, "Chrome — Inbox (Pixel 9)")
    }

    /// The title is the task's, not the app's: a second connection's app list
    /// arriving late does not overwrite it (WIN-28's precedence).
    func testTheAppListDoesNotOverwriteATaskLabel() {
        let a = fixture.open(taskLabel: "Docs")
        _ = fixture.add(taskLabel: "Mail")
        fixture.manager.appsByPkg[MultiWindowFixture.chrome.pkg] =
            AppInfo(json: ["pkg": "com.android.chrome", "label": "Chrome Beta", "multi": true])!
        fixture.manager.applyLabels()
        // The app's own name is the first half of every title, and a corrected
        // label reaches it; the task stays the window's own (WIN-28).
        XCTAssertEqual(a.window?.title, "Chrome Beta — Docs (Pixel 9)")
    }

    /// A link window names the app that shows the page, not the page (WIN-3,
    /// WIN-28): the phone sends `label` and `title` in one message, and only
    /// an app window takes the task's label.
    func testALinkWindowKeepsTheAppsNameWhileThePageTitleChanges() {
        let link = fixture.manager.openLink("https://example.com")
        fixture.session.onEvent = { [manager = fixture.manager] event in manager.handle(event) }
        fixture.session.receive(JSONMessage(raw: [
            "t": "window.title", "stream": Int(link.stream),
            "label": "Chrome", "pkg": "com.android.chrome", "title": "Some Page"]))
        XCTAssertEqual(link.window?.title, "Chrome (Pixel 9)")
    }

    /// The phone's display name is part of the title, and a rename reaches
    /// every window (WIN-3).
    func testARenamedPhoneNamesEveryWindow() {
        let a = fixture.open(taskLabel: "Docs")
        _ = fixture.add(taskLabel: "Mail")
        fixture.manager.setPhoneName("Nicky")
        XCTAssertEqual(a.window?.title, "Chrome — Docs (Nicky)")
    }
}
