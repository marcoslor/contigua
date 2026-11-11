// The View menu's rules (MenuModel.swift, docs/design/mac-redesign.md §3.8):
// the style pair, Hide Controls, and the Density submenu the commands build.

import XCTest
@testable import Contigua

final class MenuModelTests: XCTestCase {
    func testTheStylePairHasExactlyOneChecked() {
        XCTAssertEqual(MenuModel.styles, [.immersive, .framed])
        for key in WindowStyle.allCases {
            let checked = MenuModel.styles.filter { MenuModel.styleChecked($0, key: key) }
            XCTAssertEqual(checked, [key], "exactly one of the pair is checked for \(key)")
        }
    }

    func testHideControlsNeedsAKeyStreamWindow() {
        XCTAssertTrue(MenuModel.hideControlsEnabled(hasStream: true))
        XCTAssertFalse(MenuModel.hideControlsEnabled(hasStream: false))
        XCTAssertEqual(MenuModel.hideControls.map(\.title),
                       ["Instantly", "Short", "Long", "", "Always Visible"])
    }

    /// "Default (N%) · the other percentages, never repeating the default's
    /// value": the item naming the default's percentage is not repeated.
    func testTheDensityItemsNeverRepeatTheDefaultsValue() {
        XCTAssertEqual(MenuModel.densityDefaultTitle(settings: 1.0), "Default (100%)")
        XCTAssertEqual(MenuModel.densityDefaultTitle(settings: 1.25), "Default (125%)")

        XCTAssertEqual(labels(settings: 1.0), ["75%", "125%", "150%"])
        XCTAssertEqual(labels(settings: 1.25), ["75%", "100%", "150%"])
        XCTAssertEqual(labels(settings: 0.75), ["100%", "125%", "150%"])
        XCTAssertEqual(labels(settings: 1.5), ["75%", "100%", "125%"])
        for settings in WindowDensity.options.map(\.value) {
            let options = labels(settings: settings)
            XCTAssertEqual(options.count, WindowDensity.options.count - 1)
            XCTAssertFalse(options.contains(DensityRules.percentLabel(settings)),
                           "the default's value is named once, by Default (N%)")
        }
    }

    private func labels(settings: Double) -> [String] {
        MenuModel.densityOptions(settings: settings).map { $0.label }
    }
}
