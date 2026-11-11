import AppKit
import XCTest
@testable import Contigua

final class SettingsPlacementTests: XCTestCase {
    /// A 1280×800 screen's visible frame (menu bar and Dock taken).
    private let main = CGRect(x: 0, y: 25, width: 1280, height: 740)
    /// A second screen to the left, same size.
    private let left = CGRect(x: -1280, y: 25, width: 1280, height: 740)
    private let size = CGSize(width: SettingsLayout.width, height: 560)

    private func centre(of screen: CGRect, size: CGSize) -> CGPoint {
        CGPoint(x: (screen.midX - size.width / 2).rounded(), y: (screen.midY - size.height / 2).rounded())
    }

    func testAFreshProfileOpensCentredOnTheScreen() {
        let origin = SettingsPlacement.origin(saved: nil, screens: [main], size: size)
        XCTAssertEqual(origin, centre(of: main, size: size))
        XCTAssertEqual(origin.x + size.width / 2, main.midX)
        XCTAssertEqual(origin.y + size.height / 2, main.midY)
    }

    func testTheScreenToCentreOnIsTheFirstOne() {
        let origin = SettingsPlacement.origin(saved: nil, screens: [left, main], size: size)
        XCTAssertEqual(origin, centre(of: left, size: size))
    }

    func testASavedOriginOnAScreenIsKept() {
        let saved = CGPoint(x: 100, y: 200)
        XCTAssertEqual(SettingsPlacement.origin(saved: saved, screens: [main], size: size), saved)
    }

    func testASavedOriginOnAnotherScreenIsKeptThere() {
        let saved = CGPoint(x: -1200, y: 100)
        XCTAssertEqual(SettingsPlacement.origin(saved: saved, screens: [main, left], size: size), saved)
    }

    func testAnOriginOffEveryScreenIsCentred() {
        let origin = SettingsPlacement.origin(saved: CGPoint(x: 5000, y: 3000), screens: [main, left], size: size)
        XCTAssertEqual(origin, centre(of: main, size: size))
    }

    func testAnOriginPartlyOffIsPushedInside() {
        // Over the right and bottom edges: pushed inside, not re-centred.
        let pushed = SettingsPlacement.origin(saved: CGPoint(x: 1200, y: 700), screens: [main], size: size)
        XCTAssertEqual(pushed, CGPoint(x: main.maxX - size.width, y: main.maxY - size.height))
        // Over the left and top edges.
        let pulled = SettingsPlacement.origin(saved: CGPoint(x: -40, y: -30), screens: [main], size: size)
        XCTAssertEqual(pulled, CGPoint(x: main.minX, y: main.minY))
    }

    func testASavedOriginIsStoredPerProfileAndASillyValueIsNoOrigin() {
        let suite = UserDefaults(suiteName: "app.contigua.mac.settings-placement-tests")!
        suite.removePersistentDomain(forName: "app.contigua.mac.settings-placement-tests")
        XCTAssertNil(SettingsPlacement.saved(in: suite))
        SettingsPlacement.save(CGPoint(x: 123.5, y: -44), in: suite)
        XCTAssertEqual(SettingsPlacement.saved(in: suite), CGPoint(x: 123.5, y: -44))
        suite.set("not a point", forKey: SettingsPlacement.originKey)
        XCTAssertNil(SettingsPlacement.saved(in: suite))
        suite.set("", forKey: SettingsPlacement.originKey)
        XCTAssertNil(SettingsPlacement.saved(in: suite))
        suite.removePersistentDomain(forName: "app.contigua.mac.settings-placement-tests")
    }
}
