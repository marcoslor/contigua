// The Deck's find key on the search field (DECK-9, CONV-MAC-06): ⌘F is
// deliberately not a menu item (a menu item would eat it in every stream
// window), so the field's help tag and AX help are the only place a person can
// find the shortcut. The tag is put on the field SwiftUI built.

import AppKit
import XCTest
@testable import Contigua

@MainActor
final class DeckSearchTests: XCTestCase {
    /// A window whose content is one search field: `DeckSearch.field(in:)` falls
    /// back to the content, the path a non-toolbar placement would take.
    private func windowWithField() -> (NSWindow, NSSearchField) {
        let field = NSSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        // ARC owns the test's window: AppKit must not free it on close.
        window.isReleasedWhenClosed = false
        window.contentView = field
        return (window, field)
    }

    func testTheFindHelpTagNamesCommandF() {
        let (window, field) = windowWithField()
        XCTAssertTrue(DeckSearch.applyFindHelp(in: window))
        XCTAssertEqual(field.toolTip, "Find (⌘F)")
        XCTAssertEqual(field.accessibilityHelp(), "Find (⌘F)")
        XCTAssertEqual(DeckSearch.findHelp, "Find (⌘F)")
        window.close()
    }

    /// A second pass is idempotent: the help survives the mode changes that
    /// rebuild SwiftUI's toolbar.
    func testTheHelpIsPutOnAgainWithoutChanging() {
        let (window, field) = windowWithField()
        DeckSearch.applyFindHelp(in: window)
        DeckSearch.applyFindHelp(in: window)
        XCTAssertEqual(field.toolTip, "Find (⌘F)")
        XCTAssertEqual(field.accessibilityHelp(), "Find (⌘F)")
        window.close()
    }

    /// No field, no crash and no claim: the apply says whether it landed.
    func testAWindowWithoutASearchFieldReportsNoHelp() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = NSView()
        XCTAssertFalse(DeckSearch.applyFindHelp(in: window))
        window.close()
    }
}
