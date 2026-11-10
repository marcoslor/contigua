// The Dock icon's own menu (applicationDockMenu): the two commands a person
// starts from the Dock, built from the same shared actions and the same
// enablement mapping as View ▸ Find Apps and Phone ▸ Phone Mirror, so the Dock
// cannot offer a command the menus would refuse.

import AppKit
import XCTest
@testable import PocketDeck

@MainActor
final class DockMenuTests: XCTestCase {
    func testTheDockMenuOffersFindAppsAndPhoneMirror() {
        let menu = DockMenu.make(entries: DockMenuModel.entries(mirrorEnabled: true),
                                 findApps: {}, phoneMirror: {})
        XCTAssertEqual(menu.items.map(\.title), ["Find Apps", "Phone Mirror"])
        XCTAssertTrue(menu.items.allSatisfy(\.isEnabled))
    }

    /// The same rule the Phone menu and the panel use: the mirror needs an
    /// online phone, Find Apps works always (a menu item that cannot act is
    /// disabled, never removed).
    func testPhoneMirrorIsDisabledWithTheMenusRule() {
        var offline = PhoneControlsState()
        offline.connection = .offline
        XCTAssertFalse(PhonePanelItem.phoneScreen.isEnabled(in: offline))
        let entries = DockMenuModel.entries(mirrorEnabled: PhonePanelItem.phoneScreen.isEnabled(in: offline))
        XCTAssertEqual(entries.map(\.title), ["Find Apps", "Phone Mirror"])
        XCTAssertTrue(entries[0].enabled, "Find Apps opens the Deck whatever the link")
        XCTAssertFalse(entries[1].enabled, "Phone Mirror is disabled while the phone is away")

        var online = PhoneControlsState()
        online.connection = .online
        XCTAssertTrue(DockMenuModel.entries(mirrorEnabled: PhonePanelItem.phoneScreen.isEnabled(in: online))[1].enabled)
    }

    /// A pick runs the shared action, exactly as the menu item does.
    func testEachPickRunsItsSharedAction() throws {
        var findApps = 0
        var mirror = 0
        let menu = DockMenu.make(entries: DockMenuModel.entries(mirrorEnabled: true),
                                 findApps: { findApps += 1 }, phoneMirror: { mirror += 1 })
        let find = try XCTUnwrap(menu.items.first)
        let mirrorItem = try XCTUnwrap(menu.items.last)
        let target = try XCTUnwrap(find.target as? DockMenuTarget)
        XCTAssertTrue(mirrorItem.target as AnyObject? === target, "one target owns both picks")
        target.findAppsClicked(find)
        XCTAssertEqual(findApps, 1)
        XCTAssertEqual(mirror, 0)
        target.phoneMirrorClicked(mirrorItem)
        XCTAssertEqual(findApps, 1)
        XCTAssertEqual(mirror, 1)
    }
}
