// View ▸ Immersive's model and the Always Visible chrome rule
// (docs/design/mac-redesign.md §3.8), plus the force click's decision
// (docs/design/livetext.md "Force click").

import AppKit
import XCTest
@testable import PocketDeck

final class ImmersiveMenuTests: XCTestCase {
    func testTheSubmenuIsTheDelaysThenAlwaysVisible() {
        XCTAssertEqual(ImmersiveMenuModel.items.map(\.title),
                       ["Instantly", "Short", "Long", "", "Always Visible"])
        XCTAssertEqual(ImmersiveMenuModel.items[3], .separator)
    }

    func testTheCheckFollowsTheStoredChoice() {
        for delay in [RevealDelay.instantly, .short, .long, .alwaysVisible] {
            let checked = ImmersiveMenuModel.items.filter { ImmersiveMenuModel.isChecked($0, reveal: delay) }
            XCTAssertEqual(checked.count, 1, "exactly one item is checked for \(delay)")
            if delay == .alwaysVisible {
                XCTAssertEqual(checked.first, .alwaysVisible)
            } else {
                XCTAssertEqual(checked.first, .delay(delay))
            }
        }
        XCTAssertFalse(ImmersiveMenuModel.isChecked(.separator, reveal: .short))
    }

    func testAPickStoresTheChoiceAndSwitchesToImmersive() {
        for item in ImmersiveMenuModel.items where item != .separator {
            guard let pick = ImmersiveMenuModel.pick(item) else {
                XCTFail("no pick for \(item)")
                continue
            }
            XCTAssertEqual(pick.style, .immersive)
        }
        XCTAssertEqual(ImmersiveMenuModel.pick(.delay(.long))?.reveal, .long)
        XCTAssertEqual(ImmersiveMenuModel.pick(.alwaysVisible)?.reveal, .alwaysVisible)
        XCTAssertNil(ImmersiveMenuModel.pick(.separator))
    }

    func testTheParentIsCheckedOnlyWhenImmersive() {
        XCTAssertTrue(ImmersiveMenuModel.parentChecked(style: .immersive))
        XCTAssertFalse(ImmersiveMenuModel.parentChecked(style: .framed))
    }

    func testAlwaysVisibleMeansNoDwellAndTheChromeStaysUp() {
        XCTAssertTrue(ImmersiveChrome.alwaysVisible(.alwaysVisible))
        XCTAssertFalse(ImmersiveChrome.usesDwell(alwaysVisible: true))
        XCTAssertTrue(ImmersiveChrome.showsPill(alwaysVisible: true, dwellShown: false))
        for delay in [RevealDelay.instantly, .short, .long] {
            XCTAssertFalse(ImmersiveChrome.alwaysVisible(delay))
            XCTAssertTrue(ImmersiveChrome.usesDwell(alwaysVisible: false))
            XCTAssertEqual(ImmersiveChrome.showsPill(alwaysVisible: false, dwellShown: false), false)
            XCTAssertEqual(ImmersiveChrome.showsPill(alwaysVisible: false, dwellShown: true), true)
        }
    }

    func testTheStoredValueRoundTripsIncludingAlwaysVisible() {
        let name = "dev.pocketdeck.tests.reveal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        XCTAssertEqual(RevealDelay.stored(in: defaults), .short)
        defaults.set(RevealDelay.alwaysVisible.rawValue, forKey: RevealDelay.key)
        XCTAssertEqual(RevealDelay.stored(in: defaults), .alwaysVisible)
        XCTAssertEqual(RevealDelay.alwaysVisible.seconds, 0)
        XCTAssertTrue(RevealDelay.alwaysVisible.keepsChromeVisible)
        XCTAssertFalse(RevealDelay.short.keepsChromeVisible)
    }
}
