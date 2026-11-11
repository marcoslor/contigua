import XCTest
@testable import Contigua

final class BackgroundPlacementTests: XCTestCase {
    private let main = CGRect(x: 0, y: 0, width: 1680, height: 1050)

    func testTheDisplayTouchesTheMainDisplayOnlyAtItsBottomRightCorner() {
        let origin = BackgroundPlacement.cornerOrigin(touching: main)
        XCTAssertEqual(origin, CGPoint(x: 1680, y: 1050))
        let display = CGRect(origin: origin, size: main.size)
        XCTAssertEqual(display.intersection(main).width, 0)
        XCTAssertEqual(display.intersection(main).height, 0)
        XCTAssertFalse(display.insetBy(dx: 0.5, dy: 0.5).intersects(main))
    }

    func testCocoaFrameFlipsAgainstThePrimaryDisplay() {
        let cocoa = BackgroundPlacement.cocoaFrame(ofDisplay: CGRect(x: 1680, y: 1050, width: 1680, height: 1050),
                                                   primaryHeight: 1050)
        XCTAssertEqual(cocoa, CGRect(x: 1680, y: -1050, width: 1680, height: 1050))
    }

    func testAWindowKeepsItsOffsetFromTheScreenItWasLaidOutOn() {
        let target = CGRect(x: 1680, y: -1050, width: 1680, height: 1050)
        let placed = BackgroundPlacement.place(CGRect(x: 100, y: 200, width: 900, height: 628),
                                               sources: [main], onto: target)
        XCTAssertEqual(placed, CGRect(x: 1780, y: -850, width: 900, height: 628))
    }

    func testASecondScreenIsTheSourceOfItsWindows() {
        let left = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let target = CGRect(x: 1680, y: -1050, width: 1680, height: 1050)
        let placed = BackgroundPlacement.place(CGRect(x: -1400, y: 10, width: 300, height: 200),
                                               sources: [main, left], onto: target)
        XCTAssertEqual(placed.origin, CGPoint(x: 1720, y: -1040))
    }

    func testAWindowOffEveryScreenOrTooBigIsPushedInsideTopLeftFirst() {
        let target = CGRect(x: 1680, y: -1050, width: 1680, height: 1050)
        let far = BackgroundPlacement.place(CGRect(x: 5000, y: 3000, width: 400, height: 300),
                                            sources: [main], onto: target)
        XCTAssertTrue(target.contains(far))
        let big = BackgroundPlacement.place(CGRect(x: 0, y: 0, width: 2000, height: 1200),
                                            sources: [main], onto: target)
        XCTAssertEqual(big.minX, target.minX)
        XCTAssertEqual(big.maxY, target.maxY)
    }

    func testAWindowHalfOnTheDisplayIsOnlyPushedInside() {
        let target = CGRect(x: 1680, y: -1050, width: 1680, height: 1050)
        let placed = BackgroundPlacement.place(CGRect(x: 3200, y: -500, width: 400, height: 300),
                                               sources: [main], onto: target)
        XCTAssertEqual(placed, CGRect(x: 2960, y: -500, width: 400, height: 300))
    }
}
