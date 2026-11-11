// View ▸ Hide Controls' model and the full-screen reveal's stored choice
// (docs/design/mac-redesign.md §3.8).

import AppKit
import XCTest
@testable import Contigua

final class HideControlsMenuTests: XCTestCase {
    func testTheSubmenuIsTheDelaysThenAlwaysVisible() {
        XCTAssertEqual(FullScreenMenuModel.items.map(\.title),
                       ["Instantly", "Short", "Long", "", "Always Visible"])
        XCTAssertEqual(FullScreenMenuModel.items[3], .separator)
    }

    func testTheCheckFollowsTheStoredChoice() {
        for delay in [RevealDelay.instantly, .short, .long, .alwaysVisible] {
            let checked = FullScreenMenuModel.items.filter { FullScreenMenuModel.isChecked($0, reveal: delay) }
            XCTAssertEqual(checked.count, 1, "exactly one item is checked for \(delay)")
            if delay == .alwaysVisible {
                XCTAssertEqual(checked.first, .alwaysVisible)
            } else {
                XCTAssertEqual(checked.first, .delay(delay))
            }
        }
        XCTAssertFalse(FullScreenMenuModel.isChecked(.separator, reveal: .short))
    }

    /// A pick stores the reveal choice and nothing else: it never carries a
    /// window style (the old submenu did, and that is gone with the pill).
    func testAPickOnlyStoresTheRevealChoice() {
        XCTAssertEqual(FullScreenMenuModel.pick(.delay(.long)), .long)
        XCTAssertEqual(FullScreenMenuModel.pick(.alwaysVisible), .alwaysVisible)
        XCTAssertNil(FullScreenMenuModel.pick(.separator))
    }

    func testTheStoredValueRoundTripsIncludingAlwaysVisible() {
        let name = "app.contigua.tests.reveal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        XCTAssertEqual(RevealDelay.stored(in: defaults), .short)
        defaults.set(RevealDelay.alwaysVisible.rawValue, forKey: RevealDelay.key)
        XCTAssertEqual(RevealDelay.stored(in: defaults), .alwaysVisible)
        XCTAssertEqual(RevealDelay.alwaysVisible.seconds, 0)
        XCTAssertTrue(RevealDelay.alwaysVisible.keepsChromeVisible)
        XCTAssertFalse(RevealDelay.short.keepsChromeVisible)
    }

    /// The View menu is SwiftUI's, and so are its Immersive / Framed / Hide
    /// Controls items: the commands build every one of them, so a SwiftUI
    /// rebuild of the menu cannot drop any (an AppKit item inserted into the
    /// menu was dropped exactly that way, and the person's v104 and v107 menus
    /// lost these). The decisions the commands read are here.
    func testTheStylePairAndHideControlsAreTheModels() {
        XCTAssertEqual(MenuModel.styles, [.immersive, .framed])
        for key in WindowStyle.allCases {
            let checked = MenuModel.styles.filter { MenuModel.styleChecked($0, key: key) }
            XCTAssertEqual(checked, [key], "exactly one of the pair is checked for \(key)")
        }
        XCTAssertFalse(MenuModel.hideControlsEnabled(hasStream: false))
        XCTAssertTrue(MenuModel.hideControlsEnabled(hasStream: true))
        XCTAssertEqual(MenuModel.hideControls.map(\.title),
                       ["Instantly", "Short", "Long", "", "Always Visible"])
    }
}
