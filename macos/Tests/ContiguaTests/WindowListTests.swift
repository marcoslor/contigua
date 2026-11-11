// The Window menu's list (WindowList.swift, MENU-7, WIN-29): SwiftUI's windows
// are excluded from it by default, which left the list empty and its separator
// an empty row; the app's own windows are let in. With several windows of one
// app, AppKit lists them by their titles, so the titles are checked too.

import AppKit
import XCTest
@testable import Contigua

@MainActor
final class WindowListTests: XCTestCase {
    private func window(identifier: String?) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.identifier = identifier.map { NSUserInterfaceItemIdentifier($0) }
        return window
    }

    func testTheDecksAndSettingsWindowsAreTheAppsOwn() {
        XCTAssertTrue(WindowListMenu.isOwn(window(identifier: DeckWindow.id)))
        XCTAssertTrue(WindowListMenu.isOwn(window(identifier: "settings")))
        XCTAssertTrue(WindowListMenu.isOwn(window(identifier: "com_apple_SwiftUI_Settings_window")))
        XCTAssertFalse(WindowListMenu.isOwn(window(identifier: "stream-1")))
        XCTAssertFalse(WindowListMenu.isOwn(window(identifier: nil)))
    }

    /// Clearing the flag is what makes AppKit list the window; a stream window
    /// AppKit already lists is left alone.
    func testIncludingClearsTheExclusionOnlyForTheAppsOwnWindows() {
        let deck = window(identifier: DeckWindow.id)
        deck.isExcludedFromWindowsMenu = true
        XCTAssertTrue(WindowListMenu.include(deck))
        XCTAssertFalse(deck.isExcludedFromWindowsMenu)
        XCTAssertFalse(WindowListMenu.include(deck), "nothing left to do the second time")

        let stream = window(identifier: nil)
        XCTAssertFalse(WindowListMenu.include(stream))
    }

    // MARK: Several windows of one app (WIN-29)

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

    func testTheListIsFrontToBackAndNamesEveryWindowsTask() {
        _ = fixture.open(taskLabel: "Docs")
        let b = fixture.add(taskLabel: "Mail")!
        let c = fixture.add(taskLabel: "Chat")!
        let listed = fixture.manager.appWindows(pkg: MultiWindowFixture.chrome.pkg)
        XCTAssertEqual(listed.map(\.stream), [c.stream, b.stream, listed[2].stream])
        XCTAssertEqual(listed.compactMap(\.window?.title),
                       ["Chrome — Chat (Pixel 9)", "Chrome — Mail (Pixel 9)", "Chrome — Docs (Pixel 9)"])
    }

    /// Raising a window moves it to the front of the list (AppKit orders its
    /// list by the windows' own order).
    func testARaisedWindowComesFirstInTheList() {
        let a = fixture.open(taskLabel: "Docs")
        let b = fixture.add(taskLabel: "Mail")!
        fixture.manager.pickWindowMenuRow(
            AppWindowMenuRow(title: "Chrome — Docs", action: .raise(stream: a.stream)),
            pkg: MultiWindowFixture.chrome.pkg)
        XCTAssertEqual(fixture.manager.appWindows(pkg: MultiWindowFixture.chrome.pkg).first?.stream, a.stream)
        XCTAssertEqual(fixture.manager.appWindows(pkg: MultiWindowFixture.chrome.pkg).last?.stream, b.stream)
    }

    /// On the phone the order is the Mac's, and closing the front window makes
    /// the next one key without a second window.open (WIN-31).
    func testClosingTheFrontWindowLeavesTheOthers() {
        let a = fixture.open(taskLabel: "Docs")
        let b = fixture.add(taskLabel: "Mail")!
        b.window?.close()
        XCTAssertEqual(fixture.manager.appWindows(pkg: MultiWindowFixture.chrome.pkg).map(\.stream), [a.stream])
        XCTAssertEqual(fixture.closeRequests.count, 1, "one window.close, for the window that closed")
        XCTAssertEqual(fixture.closeRequests.first?["stream"] as? Int, Int(b.stream))
    }
}
