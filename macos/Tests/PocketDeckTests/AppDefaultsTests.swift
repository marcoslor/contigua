// The defaults the app registers before AppKit builds the bar.

import XCTest
@testable import PocketDeck

final class AppDefaultsTests: XCTestCase {
    /// AppKit's own Enter Full Screen, last in View, is the design (MENU-4).
    /// Registering NSFullScreenMenuItemEverywhere false removes it from every
    /// View menu and leaves the bar with no full-screen item at all.
    func testAppKitPlacesItsOwnFullScreenItem() {
        XCTAssertNil(AppDefaults.registered["NSFullScreenMenuItemEverywhere"],
                     "forcing AppKit's full-screen item off empties View's last item (MENU-4)")
        XCTAssertEqual(AppDefaults.registered["ApplePersistenceIgnoreState"] as? Bool, true)
        XCTAssertEqual(AppDefaults.registered["NSQuitAlwaysKeepsWindows"] as? Bool, false)
    }
}
