// SwipePath (plan T2, MCP-90): `swipe {direction, ref?}` runs through the
// centre of the ref's box, else the window's, over 60 % of its extent along
// the direction, the finger moving the named way.

import XCTest
@testable import Contigua

final class SwipePathTests: XCTestCase {
    private func assertPoint(_ point: [Double], _ x: Double, _ y: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(point.count, 2, file: file, line: line)
        XCTAssertEqual(point.first ?? -1, x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(point.last ?? -1, y, accuracy: 1e-9, file: file, line: line)
    }

    // [MCP-90]
    func testADirectionSwipesSixtyPercentThroughTheCentre() {
        let size = [1000, 2000]
        let up = SwipePath.line(direction: .up, box: nil, size: size)
        assertPoint(up.from, 0.5, 0.8)
        assertPoint(up.to, 0.5, 0.2)

        let left = SwipePath.line(direction: .left, box: [0, 1000, 1000, 1500], size: size)
        assertPoint(left.from, 0.8, 0.625)
        assertPoint(left.to, 0.2, 0.625)

        // The other two ways, over the window: the finger moves that way.
        let down = SwipePath.line(direction: .down, box: nil, size: size)
        assertPoint(down.from, 0.5, 0.2)
        assertPoint(down.to, 0.5, 0.8)
        let right = SwipePath.line(direction: .right, box: nil, size: size)
        assertPoint(right.from, 0.2, 0.5)
        assertPoint(right.to, 0.8, 0.5)
    }
}
