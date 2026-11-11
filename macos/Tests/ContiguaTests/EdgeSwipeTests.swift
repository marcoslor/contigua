// Edge-swipe classifier: only a clearly horizontal two-finger gesture that
// starts inside the left 24 pt is a back gesture.

import CoreGraphics
import XCTest
@testable import Contigua

final class EdgeSwipeTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 900, height: 600)

    private func begin(_ classifier: inout EdgeSwipeClassifier, x: CGFloat, y: CGFloat = 300) -> Bool {
        classifier.begin(at: CGPoint(x: x, y: y), in: bounds)
    }

    func testGestureInsideTheLeftStripIsTracked() {
        var classifier = EdgeSwipeClassifier()
        XCTAssertTrue(begin(&classifier, x: 0))
        XCTAssertTrue(classifier.isTracking)

        var second = EdgeSwipeClassifier()
        XCTAssertTrue(begin(&second, x: EdgeSwipeClassifier.edgeWidth))
    }

    func testGestureOutsideTheStripIsIgnored() {
        var classifier = EdgeSwipeClassifier()
        XCTAssertFalse(begin(&classifier, x: EdgeSwipeClassifier.edgeWidth + 0.5))
        XCTAssertFalse(classifier.isTracking)
        XCTAssertEqual(classifier.update(horizontal: 200, vertical: 0), .ignore)
    }

    func testPointOutsideTheViewIsIgnored() {
        var classifier = EdgeSwipeClassifier()
        XCTAssertFalse(classifier.begin(at: CGPoint(x: 4, y: -10), in: bounds))
    }

    func testRightwardTravelTriggersOnceAtTheThreshold() {
        var classifier = EdgeSwipeClassifier()
        _ = begin(&classifier, x: 10)
        XCTAssertEqual(classifier.update(horizontal: 20, vertical: 2), .hold)
        XCTAssertEqual(classifier.update(horizontal: 20, vertical: 2), .hold)
        XCTAssertEqual(classifier.update(horizontal: 25, vertical: 1), .trigger)
        XCTAssertTrue(classifier.didTrigger)
        // The rest of the gesture is swallowed, never a second nav.
        XCTAssertEqual(classifier.update(horizontal: 30, vertical: 0), .hold)
    }

    func testVerticalGestureFallsThroughToScrolling() {
        var classifier = EdgeSwipeClassifier()
        _ = begin(&classifier, x: 10)
        XCTAssertEqual(classifier.update(horizontal: 1, vertical: 12), .hold)
        XCTAssertEqual(classifier.update(horizontal: 2, vertical: 25), .passThrough)
        XCTAssertFalse(classifier.isTracking)
        XCTAssertEqual(classifier.update(horizontal: 40, vertical: 0), .ignore)
    }

    func testHorizontalSwipeTriggersEitherDirection() {
        // The delta sign flips with the natural-scrolling setting, so the
        // classifier only cares about the strip and the shape of the gesture.
        var leftward = EdgeSwipeClassifier()
        _ = begin(&leftward, x: 10)
        XCTAssertEqual(leftward.update(horizontal: -70, vertical: 0), .trigger)
    }

    func testASlightlyTiltedHorizontalSwipeStillTriggers() {
        var classifier = EdgeSwipeClassifier()
        _ = begin(&classifier, x: 0)
        XCTAssertEqual(classifier.update(horizontal: 70, vertical: 30), .trigger)
    }

    func testEndResetsForTheNextGesture() {
        var classifier = EdgeSwipeClassifier()
        _ = begin(&classifier, x: 5)
        _ = classifier.update(horizontal: 10, vertical: 0)
        classifier.end()
        XCTAssertFalse(classifier.isTracking)
        XCTAssertFalse(classifier.didTrigger)
        XCTAssertEqual(classifier.update(horizontal: 100, vertical: 0), .ignore)
        // A fresh gesture starts from zero: no accumulated travel.
        _ = begin(&classifier, x: 5)
        XCTAssertEqual(classifier.update(horizontal: 30, vertical: 0), .hold)
    }

    func testUpdateWithoutBeginIsIgnored() {
        var classifier = EdgeSwipeClassifier()
        XCTAssertEqual(classifier.update(horizontal: 100, vertical: 0), .ignore)
    }
}
