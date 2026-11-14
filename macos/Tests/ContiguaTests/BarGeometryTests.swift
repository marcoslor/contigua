// The 28 pt row's numbers: the traffic lights equally inset left/top/bottom,
// the Live Text button the same distance in from the right, centred on the
// lights' line. The Immersive pill wears this row (WindowChromeTests checks
// its view tree); Compact's title bar is AppKit's own.

import AppKit
import XCTest
@testable import Contigua

final class BarGeometryTests: XCTestCase {
    /// The numbers, without a window.
    func testTheBarIsTheLightsPlusEqualInsets() {
        XCTAssertEqual(BarGeometry.barHeight, 28)
        XCTAssertEqual(BarGeometry.lightSide, 14)
        XCTAssertEqual(BarGeometry.lightInset, 7)
        XCTAssertEqual(BarGeometry.lightSpacing, 23)
        XCTAssertEqual(BarGeometry.liveTextSide, 28)
        XCTAssertEqual(BarGeometry.rightInset, BarGeometry.lightInset,
                       "the Live Text button mirrors the lights' left inset")
        XCTAssertEqual(BarGeometry.barHeight,
                       BarGeometry.lightInset * 2 + BarGeometry.lightSide,
                       "the bar is the lights plus the equal top/bottom insets")
    }
}
