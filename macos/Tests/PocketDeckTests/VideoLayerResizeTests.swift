// The picture must follow a window resize exactly: no implicit CALayer
// animation on the display layer, or a fast drag leaves black bands while the
// layer catches up (the person's 2026-10-20 recording).

import AppKit
import XCTest
@testable import PocketDeck

@MainActor
final class VideoLayerResizeTests: XCTestCase {
    func testTheDisplayLayerFollowsTheViewWithoutAnAnimation() {
        let view = VideoLayerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.layoutSubtreeIfNeeded()
        let layer = view.displayLayerForTesting
        XCTAssertEqual(layer.frame, view.bounds)

        view.setFrameSize(NSSize(width: 500, height: 360))
        XCTAssertEqual(layer.frame, view.bounds, "the layer is the view's size at once")
        XCTAssertTrue(layer.animationKeys()?.isEmpty ?? true,
                      "an implicit animation is what makes the picture trail the edge")
        // The WindowServer may not hand out a presentation layer in a test
        // process; when it does, it must already be the new bounds.
        if let presented = layer.presentation() {
            XCTAssertEqual(presented.frame, view.bounds)
        }

        view.setFrameSize(NSSize(width: 320, height: 240))
        XCTAssertEqual(layer.frame, view.bounds)
        XCTAssertTrue(layer.animationKeys()?.isEmpty ?? true)
    }
}
