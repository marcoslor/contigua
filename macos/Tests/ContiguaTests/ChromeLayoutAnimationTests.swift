// WIN-58: a chrome layout drops the frame animations a resize step would
// otherwise trail by ~0.25 s, and only those: a fade in flight (the covers
// controls, a touch dot, the cover) or the edge hint's group must survive a
// layout that lands during it.

import AppKit
import QuartzCore
import XCTest
@testable import Contigua

@MainActor
final class ChromeLayoutAnimationTests: XCTestCase {
    private func makeChrome() -> (NSWindow, StreamChromeView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 628),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let video = VideoLayerView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        video.setVideoSizeForTesting(CGSize(width: 900, height: 600))
        let chrome = StreamChromeView(video: video, style: .compact)
        chrome.frame = NSRect(x: 0, y: 0, width: 900, height: 628)
        window.contentView = chrome
        chrome.layoutChrome()
        return (window, chrome)
    }

    func testALayoutRemovesFrameAnimationsButKeepsFades() throws {
        let (window, chrome) = makeChrome()
        defer { window.close() }
        let host = try XCTUnwrap(chrome.layer)
        let probe = CALayer()
        host.addSublayer(probe)

        let move = CABasicAnimation(keyPath: "position")
        move.duration = 5
        probe.add(move, forKey: "position")
        let grow = CABasicAnimation(keyPath: "bounds")
        grow.duration = 5
        probe.add(grow, forKey: "bounds")
        let scale = CABasicAnimation(keyPath: "sublayerTransform")
        scale.duration = 5
        probe.add(scale, forKey: "sublayerTransform")
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.duration = 5
        probe.add(sweep, forKey: "sweep")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.duration = 5
        probe.add(fade, forKey: "fadeOut")
        let group = CAAnimationGroup()
        group.animations = [CABasicAnimation(keyPath: "position"), CAKeyframeAnimation(keyPath: "opacity")]
        group.duration = 5
        probe.add(group, forKey: "edgeSwipeHint")

        chrome.layoutChrome()

        let left = Set(probe.animationKeys() ?? [])
        XCTAssertFalse(left.contains("position"), "a frame animation would trail the dragged edge")
        XCTAssertFalse(left.contains("bounds"), "a frame animation would trail the dragged edge")
        XCTAssertFalse(left.contains("sublayerTransform"),
                       "the video container's scale would trail the dragged edge")
        XCTAssertTrue(left.contains("fadeOut"), "a fade in flight is deliberate: \(left)")
        XCTAssertTrue(left.contains("sweep"), "the cover's sweep is deliberate: \(left)")
        XCTAssertTrue(left.contains("edgeSwipeHint"), "the edge hint's group is deliberate: \(left)")
    }
}
